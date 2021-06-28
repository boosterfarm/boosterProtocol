// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "../BOOToken.sol";
import "./BooDaoToken.sol";

pragma experimental ABIEncoderV2;

// Have fun reading it. Hopefully it's bug-free. God bless.
contract BooDao is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    struct LockedItem {
        uint256 amount;
        uint256 release;
    }

    // Info of each user.
    struct UserInfo {
        uint256 amount;             // How many tokens the user has provided.
        uint256 lockedAmount;       // How many tokens been locked.
        uint256 gainsDebt;          // gain debt. See explanation below.
        uint256 accGains;           // gain now
        LockedItem[] locked;        // locked orders
    }

    // Info of each pool.
    struct PoolInfo {
        address lpToken;            // Address of LP token contract.
        uint256 rewardPerBlockShare;  // How many allocation tokens assigned to this pool. to distribute per block per share.
        uint256 frozenPeriod;       // lock time      
        uint256 lastRewardBlock;    // Last block number that BOOs distribution occurs.
        uint256 accRewardPerShare;  // Accumulated Token per share, times 1e18
        uint256 totalAmount;        // How many tokens provided in the pool.
    }

    // Info of each top accounts.
    struct TopAccountInfo {
        address accounts;           // top accounts
        uint256 amount;             // How many tokens the user has provided.
        uint256 lastBonusBlock;     // Last block number that BOOs distribution occurs. 
        uint256 accBonusPerBlock;   // Accumulated Token per share, times 1e18
    }

    // The BOO TOKEN!
    BooDaoToken public daoToken;
    BOOToken public rewardToken;
    // Dev address.
    address public devaddr;
    address public optaddr;
    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // The block number when BOO mining starts.
    uint256 public startBlock;
    // the contract in emergency mode
    bool public emergencyEnabled = false;
    // Info of top accounts  
    TopAccountInfo[] public topAccountInfo;
    mapping(address => uint256) public topAccountIndex;
    mapping(address => uint256) public topAccountBonus;
    // accounts sets
    EnumerableSet.AddressSet accountSet;

    // events
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    event AddPool(uint256 indexed _pid, uint256 _rewardPerBlock, uint256 _frozenPeriod, address _lpToken);
    event SetRewardPerBlock(uint256 indexed _pid, uint256 rewardPerBlockShare);
    event SetFrozenPeriod(uint256 indexed _pid, uint256 _frozenPeriod);
    event SetEmergencyStatus(uint256 indexed _pid, bool _emergencyStatus);

    constructor(
        address _daoToken,
        address _rewardToken,
        address _devaddr,
        address _optaddr,
        uint256 _startBlock
    ) public {
        daoToken = BooDaoToken(_daoToken);
        rewardToken = BOOToken(_rewardToken);
        devaddr = _devaddr;
        optaddr = _optaddr;
        startBlock = _startBlock;
        require(startBlock >= block.number);
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function addPool(uint256 _rewardPerBlock, uint256 _frozenPeriod, address _lpToken) public onlyOwner {
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            rewardPerBlockShare: _rewardPerBlock,
            frozenPeriod: _frozenPeriod,
            lastRewardBlock: lastRewardBlock,
            accRewardPerShare: 0,
            totalAmount: 0
        }));
        emit AddPool(poolInfo.length.sub(1), _rewardPerBlock, _frozenPeriod, _lpToken);
    }

    // Update the given pool's BOO allocation point. Can only be called by the owner.
    function setRewardPerBlock(uint256 _pid, uint256 _rewardPerBlock) public onlyOwner {
        updatePool(_pid);
        poolInfo[_pid].rewardPerBlockShare = _rewardPerBlock;
        emit SetRewardPerBlock(_pid, _rewardPerBlock);
    }

    function setFrozenPeriod(uint256 _pid, uint256 _frozenPeriod) public onlyOwner {
        poolInfo[_pid].frozenPeriod = _frozenPeriod;
        emit SetFrozenPeriod(_pid, _frozenPeriod);
    }

    function setEmergencyStatus(uint256 _pid, bool _emergencyStatus) public onlyOwner {
        emergencyEnabled = _emergencyStatus;
        emit SetEmergencyStatus(_pid, _emergencyStatus);
    }

    function setOperAddress(address _optaddr) public onlyOwner {
        optaddr = _optaddr;
    }

    function setTopAccounts(address[] memory _topAccounts) external {
        require(optaddr == msg.sender, 'op?');
        // update bonus
        uint256 popLength = topAccountInfo.length;
        for (uint256 u = 0; u < popLength; ++u) {
            uint256 topIndex = popLength.sub(1).sub(u);
            address topAddress = topAccountInfo[topIndex].accounts;
            topAccountBonus[topAddress] = pendingBonus(topAddress).add(topAccountBonus[topAddress]);
            delete topAccountIndex[topAddress];
            topAccountInfo.pop();
        }

        for (uint256 u = 0; u < _topAccounts.length; ++u) {
            topAccountInfo.push(TopAccountInfo({
                accounts:_topAccounts[u],
                amount:0,
                lastBonusBlock:block.number,
                accBonusPerBlock:0}));
            topAccountIndex[_topAccounts[u]] = topAccountInfo.length.sub(1);
            // update amount lastRewardBlock accBonusPerBlock
            updateTopAccountsAmount(_topAccounts[u]);
        }
    }

    // Update dev address by the previous one
    function setDevAddress(address _devaddr) external {
        require(msg.sender == devaddr, "only dev caller");
        devaddr = _devaddr;
    }

    function updateTopAccountsAmount(address _user) public {
        uint256 topIndex = topAccountIndex[_user];
        if(topIndex >= topAccountInfo.length ||
            topAccountInfo[topIndex].accounts != _user) {
            return;
        }

        topAccountBonus[_user] = pendingBonus(_user).add(topAccountBonus[_user]);
        
        TopAccountInfo storage accInfo = topAccountInfo[topIndex];
        accInfo.amount = 0;
        accInfo.accBonusPerBlock = 0;
        for (uint256 pid = 0; pid < poolInfo.length; ++pid) {
            PoolInfo storage pool = poolInfo[pid];
            UserInfo storage user = userInfo[pid][_user];

            accInfo.amount = accInfo.amount.add(user.amount);
            accInfo.accBonusPerBlock = accInfo.accBonusPerBlock.add(user.amount.mul(pool.rewardPerBlockShare).div(1e18));
        }
        accInfo.lastBonusBlock = block.number;
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }
    
    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock || pool.totalAmount == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }

        uint256 newRewardPerShare = block.number.sub(pool.lastRewardBlock).mul(pool.rewardPerBlockShare);
        uint256 mintReward = newRewardPerShare.mul(pool.totalAmount).div(1e18);
        if (mintReward == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }

        for (uint256 u = 0; u < topAccountInfo.length; ++u) {
            address topUser = topAccountInfo[u].accounts;
            uint256 newBonus = pendingBonus(topUser);
            mintReward = mintReward.add(newBonus);
            topAccountBonus[topUser] = topAccountBonus[topUser].add(newBonus);
            topAccountInfo[u].lastBonusBlock = block.number;
        }

        rewardToken.mint(address(this), mintReward);
        rewardToken.mint(devaddr, mintReward.div(8));
        pool.accRewardPerShare = pool.accRewardPerShare.add(newRewardPerShare);
        pool.lastRewardBlock = block.number;
    }

    // View function to see pending SUSHIs on frontend.
    function pendingRewards(uint256 _pid, address _user)
        public view returns (uint256 accGains, uint256 accBonus) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accRewardPerShare = pool.accRewardPerShare;
        if(block.number > pool.lastRewardBlock) {
            uint256 newRewardPerShare = block.number.sub(pool.lastRewardBlock).mul(pool.rewardPerBlockShare);
            accRewardPerShare = pool.accRewardPerShare.add(newRewardPerShare);
        }
        accGains =  user.amount.mul(accRewardPerShare).div(1e18).add(user.accGains).sub(user.gainsDebt);
        accBonus = pendingBonus(_user).add(topAccountBonus[_user]);
    }

    function pendingBonus(address _user)
        public view returns (uint256 newBonus) {
        uint256 topIndex = topAccountIndex[_user];
        if(topIndex >= topAccountInfo.length ||
            topAccountInfo[topIndex].accounts != _user) {
            return 0;
        }
        TopAccountInfo storage accInfo = topAccountInfo[topIndex];
        newBonus = block.number.sub(accInfo.lastBonusBlock).mul(accInfo.accBonusPerBlock);
    }

    function getAccountSetLength() public view returns (uint256) {
        return accountSet.length();
    }

    function getAccountSet(uint256 _pos) public view returns (address) {
        return accountSet.at(_pos);
    }

    function _deleteLockItem(UserInfo storage user, uint256 _id) internal {
        uint256 lastid = user.locked.length.sub(1);
        if(_id != lastid) {
            user.locked[_id].amount = user.locked[lastid].amount;
            user.locked[_id].release = user.locked[lastid].release;
        }
        user.locked.pop();
    }

    function updateLockItem(uint256 _pid, address _account, uint256 _start, uint256 _checknum) public {
        UserInfo storage user = userInfo[_pid][_account];
        uint256 checkitem = 0;
        for(uint256 u = _start; checkitem < _checknum && u < user.locked.length; u++) {
            checkitem ++;
            if(user.locked[u].release < block.number ) {
                _deleteLockItem(user, u);
                u --;
            }
        }
    }

    function updateLockAmount(uint256 _pid, address _account) public {
        userInfo[_pid][_account].lockedAmount = getLockAmount(_pid, _account);
    }

    function getLockAmount(uint256 _pid, address _account)
        public view returns (uint256 locked) {
        UserInfo storage user = userInfo[_pid][_account];
        for(uint256 u = 0; u < user.locked.length; u ++) {
            if(user.locked[u].release < block.number) continue;
            locked = locked.add(user.locked[u].amount);
        }
    }

    function getUserInfo(uint256 _pid, address _account)
        public view returns (uint256 amount, uint256 locked, uint256 accGains, uint256 accBonus) {
        amount = userInfo[_pid][_account].amount;
        locked = getLockAmount(_pid, _account);
        (accGains, accBonus) = pendingRewards(_pid, _account);
    }

    function getUserLockedLength(uint256 _pid, address _account) public view returns (uint256) {
        return userInfo[_pid][_account].locked.length;
    }

    function getUserLockedInfo(uint256 _pid, address _account, uint256 _index)
        public view returns (uint256 amount, uint256 release) {
        LockedItem storage item = userInfo[_pid][_account].locked[_index];
        amount = item.amount;
        release = item.release;
    }

    // Deposit LP tokens to MasterChef for SUSHI allocation.
    function deposit(uint256 _pid, uint256 _amount) public nonReentrant {
        updatePool(_pid);

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        if (user.amount > 0) {
            (user.accGains,) = pendingRewards(_pid, msg.sender);
        }

        if(_amount > 0) {
            IERC20(pool.lpToken).safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount);
            user.lockedAmount = user.lockedAmount.add(_amount);
        }

        user.gainsDebt = user.amount.mul(pool.accRewardPerShare).div(1e18);
        pool.totalAmount = pool.totalAmount.add(_amount);

        user.locked.push(LockedItem({
                amount:_amount, 
                release:block.number.add(pool.frozenPeriod)}));
        
        daoToken.mint(msg.sender, _amount);

        updateTopAccountsAmount(msg.sender);

        if(_amount > 0 && !accountSet.contains(msg.sender)){
            accountSet.add(msg.sender);
        }

        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount, bool updateLocked) public nonReentrant {
        updatePool(_pid);

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        if(updateLocked) {
            updateLockItem(_pid, msg.sender, 0, user.locked.length);
            updateLockAmount(_pid, msg.sender);
        }

        if (user.amount > 0) {
            (user.accGains,) = pendingRewards(_pid, msg.sender);
        }

        require(_amount <= user.amount.sub(user.lockedAmount), 'amount locked');

        if(_amount > 0) {
            user.amount = user.amount.sub(_amount);
            IERC20(pool.lpToken).safeTransfer(address(msg.sender), _amount);
        }
        
        user.gainsDebt = user.amount.mul(pool.accRewardPerShare).div(1e18);
        pool.totalAmount = pool.totalAmount.sub(_amount);

        IERC20(address(daoToken)).safeTransferFrom(msg.sender, address(this), _amount);
        daoToken.burn(_amount);

        updateTopAccountsAmount(msg.sender);
    
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        require(emergencyEnabled, 'not in emergency');

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint256 withdrawAmount = user.amount;

        user.amount = 0;
        user.accGains = 0;
        user.gainsDebt = 0;
        pool.totalAmount = pool.totalAmount.sub(withdrawAmount);
        
        if(withdrawAmount > 0) {
            IERC20(pool.lpToken).safeTransfer(address(msg.sender), withdrawAmount);
        }

        IERC20(address(daoToken)).safeTransferFrom(msg.sender, address(this), withdrawAmount);
        daoToken.burn(withdrawAmount);

        emit Withdraw(msg.sender, _pid, withdrawAmount);
    }

    function claim(uint256 _pid) external nonReentrant {
        _claim(_pid, msg.sender);
    }

    function claims(uint256[] memory _pids) external {
        for(uint256 u = 0; u < _pids.length; u ++) {
            _claim(_pids[u], msg.sender);
        }
    }    

    function withdrawAll(uint256 _pid, uint256 _amount, bool updateLocked) external {
        withdraw(_pid, _amount, updateLocked);
        _claim(_pid, msg.sender);
    }

    function _claim(uint256 _pid, address _account) internal {
        updatePool(_pid);
        updateTopAccountsAmount(_account);

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_account];
        (uint256 accGains,) = pendingRewards(_pid, _account);
        uint256 accRewards = accGains.add(topAccountBonus[_account]);

        user.accGains = 0;
        user.gainsDebt = user.amount.mul(pool.accRewardPerShare).div(1e18);
        topAccountBonus[_account] = 0;

        if(accRewards > 0) {
            IERC20(rewardToken).safeTransfer(_account, accRewards);
        }
    }

    function getTopAccounts()
        external view returns (address[] memory accounts, uint256[] memory amounts) {
        accounts = new address[](topAccountInfo.length);
        amounts = new uint256[](topAccountInfo.length);
        for (uint256 i = 0; i < topAccountInfo.length; i++) {
            accounts[i] = topAccountInfo[i].accounts;
            amounts[i] = topAccountInfo[i].amount;
        }
    }
    
    // Safe Token transfer function, just in case if rounding error causes pool to not have enough Tokens.
    function safeTokenTransfer(address _to, uint256 _amount) internal returns (uint256 value) {
        uint256 balance = rewardToken.balanceOf(address(this));
        value = _amount > balance ? balance : _amount;
        // require(_amount <= balance, 'debug? balance');
        if ( value > 0 ) {
            IERC20(rewardToken).safeTransfer(_to, value);
        }
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public {
        require(msg.sender == devaddr, "dev: wut?");
        devaddr = _devaddr;
    }
}
