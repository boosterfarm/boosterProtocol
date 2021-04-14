// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import '../interfaces/ICompActionTrigger.sol';
import '../interfaces/IActionPools.sol';
import '../interfaces/IClaimFromBank.sol';

import "../utils/TenMath.sol";
import '../BOOToken.sol';

// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once Token is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract ActionCompPools is Ownable, IActionPools, IClaimFromBank {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 rewardDebt;     // debt rewards
        uint256 rewardRemain;   // Remain rewards
    }

    // Info of each pool.
    struct PoolInfo {
        address callFrom;           // Address of trigger contract.
        uint256 callId;             // id of trigger action id, or maybe its poolid
        IERC20  rewardToken;        // Address of reward token address.
        uint256 rewardMaxPerBlock;  // max rewards per block.
        uint256 lastRewardBlock;    // Last block number that Token distribution occurs.
        uint256 lastRewardTotal;    // Last total amount that reward Token distribution use for calculation.
        uint256 lastRewardClosed;   // Last amount that reward Token distribution.
        uint256 poolTotalRewards;   // amount will reward in contract.
        bool autoUpdate;         // auto updatepool while event
        bool autoClaim;          // auto claim while event
    }

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that remain and debt.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // index of poollist by contract and contract-call-id
    mapping (address => mapping(uint256 => uint256[])) public poolIndex;
    // total amount of each reward token
    mapping (address => uint256) public tokenTotalRewards;
    // block hacker to restricted reward
    mapping (address => uint256) public rewardRestricted;
    // event notify source, contract in whitlist
    mapping (address => bool) public eventSources;
    // mint from bootoken, when reward token is booToken , mint it
    BOOToken public booToken;
    // mint for boodev, while mint bootoken, mint a part for dev
    address public boodev;
    // allow bank proxy claim
    address public bank;

    event ActionDeposit(address indexed user, uint256 indexed pid, uint256 fromAmount, uint256 toAmount);
    event ActionWithdraw(address indexed user, uint256 indexed pid, uint256 fromAmount, uint256 toAmount);
    event ActionClaim(address indexed user, uint256 indexed pid, uint256 amount);
    // event ActionEmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    event AddPool(uint256 indexed _pid, address _callFrom, uint256 _callId, address _rewardToken, uint256 _maxPerBlock);
    event SetRewardMaxPerBlock(uint256 indexed _pid, uint256 _maxPerBlock);
    event SetRewardRestricted(address _hacker, uint256 _rate);

    constructor (address _bank, address _booToken, address _boodev) public {
        bank = _bank;
        booToken = BOOToken(_booToken);
        require(booToken.totalSupply() >= 0, 'booToken');
        boodev = _boodev;
    }

    // If the user transfers TH to contract, it will revert
    receive() external payable {
        revert();
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function getPoolInfo(uint256 _pid) external override view
        returns (address callFrom, uint256 callId, address rewardToken) {
        callFrom = poolInfo[_pid].callFrom; 
        callId = poolInfo[_pid].callId;
        rewardToken = address(poolInfo[_pid].rewardToken);
    }

    function getPoolIndex(address _callFrom, uint256 _callId) external override view returns (uint256[] memory) {
        return poolIndex[_callFrom][_callId];
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(address _callFrom, uint256 _callId, 
                address _rewardToken, uint256 _maxPerBlock) external onlyOwner {

        (address lpToken,, uint256 totalPoints,) = 
                    ICompActionTrigger(_callFrom).getCATPoolInfo(_callId);
        require(lpToken != address(0) && totalPoints >= 0, 'pool not right');
        poolInfo.push(PoolInfo({
            callFrom: _callFrom,
            callId: _callId,
            rewardToken: IERC20(_rewardToken),
            rewardMaxPerBlock: _maxPerBlock,
            lastRewardBlock: block.number,
            lastRewardTotal: 0,
            lastRewardClosed: 0,
            poolTotalRewards: 0,
            autoUpdate: true,
            autoClaim: false
        }));

        eventSources[_callFrom] = true;
        poolIndex[_callFrom][_callId].push(poolInfo.length.sub(1));

        emit AddPool(poolInfo.length.sub(1), _callFrom, _callId, _rewardToken, _maxPerBlock);
    }

    // Set the number of reward produced by each block
    function setRewardMaxPerBlock(uint256 _pid, uint256 _maxPerBlock) external onlyOwner {
        poolInfo[_pid].rewardMaxPerBlock = _maxPerBlock;
        emit SetRewardMaxPerBlock(_pid, _maxPerBlock);
    }

    function setAutoUpdate(uint256 _pid, bool _set) external onlyOwner {
        poolInfo[_pid].autoUpdate = _set;
    }

    function setAutoClaim(uint256 _pid, bool _set) external onlyOwner {
        poolInfo[_pid].autoClaim = _set;
    }
    
    function setRewardRestricted(address _hacker, uint256 _rate) external onlyOwner {
        require(_rate <= 1e9, 'max is 1e9');
        rewardRestricted[_hacker] = _rate;
        emit SetRewardRestricted(_hacker, _rate);
    }

    function setBooDev(address _boodev) external {
        require(msg.sender == boodev, 'prev dev only');
        boodev = _boodev;
    }

    // Return reward multiplier over the given _from to _to block.
    function getBlocksReward(uint256 _pid, uint256 _from, uint256 _to) public view returns (uint256 value) {
        require(_from <= _to, 'getBlocksReward error');
        PoolInfo storage pool = poolInfo[_pid];
        value = pool.rewardMaxPerBlock.mul(_to.sub(_from));
        if( address(pool.rewardToken) == address(booToken)) {
            return value;
        }
        if( pool.lastRewardClosed.add(value) > pool.poolTotalRewards) {
            value = pool.lastRewardClosed < pool.poolTotalRewards ?
                    pool.poolTotalRewards.sub(pool.lastRewardClosed) : 0;
        }
    }

    // View function to see pending Tokens on frontend.
    function pendingRewards(uint256 _pid, address _account) public view returns (uint256 value) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_account];
        uint256 userPoints = ICompActionTrigger(pool.callFrom).getCATUserAmount(pool.callId, _account);
        (,,uint256 poolTotalPoints,) = ICompActionTrigger(pool.callFrom).getCATPoolInfo(pool.callId);
        value = pendingRewards(_pid, _account, userPoints, poolTotalPoints);
    }

    function pendingRewards(uint256 _pid, address _account, uint256 _points, uint256 _totalPoints)
            public view returns (uint256 value) {
        UserInfo storage user = userInfo[_pid][_account];
        value = totalRewards(_pid, _points, _totalPoints)
                    .add(user.rewardRemain);
        value = TenMath.safeSub(value, user.rewardDebt);
    }

    function totalRewards(uint256 _pid, uint256 _points, uint256 _totalPoints) 
            public view returns (uint256 value) {
        if(_totalPoints <= 0) {
            return 0;
        }
        PoolInfo storage pool = poolInfo[_pid];
        uint256 poolRewardTotal = pool.lastRewardTotal;
        if (block.number > pool.lastRewardBlock && _totalPoints != 0) {
            uint256 poolReward = getBlocksReward(_pid, pool.lastRewardBlock, block.number);
            poolRewardTotal = poolRewardTotal.add(poolReward);
        }
        value = _points.mul(poolRewardTotal).div(_totalPoints);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools(uint256 _start, uint256 _end) public {
        if(_end <= 0) {
            _end = poolInfo.length;
        }
        for (uint256 pid = _start; pid < _end; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return ;
        }

        (,,uint256 poolTotalAmount,) = ICompActionTrigger(pool.callFrom).getCATPoolInfo(pool.callId);
        if ( pool.rewardMaxPerBlock <= 0 ||
             poolTotalAmount <= 0) {
            pool.lastRewardBlock = block.number;
            return ;
        }

        uint256 poolReward = getBlocksReward(_pid, pool.lastRewardBlock, block.number);
        if (poolReward > 0) {
            address rewardToken = address(pool.rewardToken);
            if( rewardToken == address(booToken)) {
                booToken.mint(address(this), poolReward);
                booToken.mint(boodev, poolReward.div(8));   // mint for dev
                pool.poolTotalRewards = pool.poolTotalRewards.add(poolReward);
                tokenTotalRewards[rewardToken] = tokenTotalRewards[rewardToken].add(poolReward);
            }
            pool.lastRewardClosed = pool.lastRewardClosed.add(poolReward);
            pool.lastRewardTotal = pool.lastRewardTotal.add(poolReward);
        }
        pool.lastRewardBlock = block.number;
    }

    function onAcionIn(uint256 _callId, address _account, uint256 _fromPoints, uint256 _toPoints) external override {
        if(!eventSources[msg.sender]) {
            return ;
        }
        for(uint256 u = 0; u < poolIndex[msg.sender][_callId].length; u ++) {
            uint256 pid = poolIndex[msg.sender][_callId][u];
            deposit(pid, _account, _fromPoints, _toPoints);
        }
    }

    function onAcionOut(uint256 _callId, address _account, uint256 _fromPoints, uint256 _toPoints) external override  {
        if(!eventSources[msg.sender]) {
            return ;
        }
        for(uint256 u = 0; u < poolIndex[msg.sender][_callId].length; u ++) {
            uint256 pid = poolIndex[msg.sender][_callId][u];
            withdraw(pid, _account, _fromPoints, _toPoints);
        }
    }

    function onAcionClaim(uint256 _callId, address _account) external override  {
        if(!eventSources[msg.sender]) {
            return ;
        }
        for(uint256 u = 0; u < poolIndex[msg.sender][_callId].length; u ++) {
            uint256 pid = poolIndex[msg.sender][_callId][u];
            if( !poolInfo[pid].autoClaim ) {
                continue;
            }
            _claim(pid, _account);
        }
    }

    function onAcionEmergency(uint256 _callId, address _account) external override  {
        _callId;
        _account;
    }

    function onAcionUpdate(uint256 _callId) external override  {
        if(!eventSources[msg.sender]) {
            return ;
        }
        for(uint256 u = 0; u < poolIndex[msg.sender][_callId].length; u ++) {
            uint256 pid = poolIndex[msg.sender][_callId][u];
            if( !poolInfo[pid].autoUpdate ) {
                continue;
            }
            updatePool(pid);
        }
    }

    function mintRewards(uint256 _pid) external override {
        updatePool(_pid);
        PoolInfo storage pool = poolInfo[_pid];
        address rewardToken = address(pool.rewardToken);
        if(rewardToken == address(booToken)) {
            return ;
        }
        uint256 balance = pool.rewardToken.balanceOf(address(this));
        if ( balance > tokenTotalRewards[rewardToken]) {
            uint256 mint = balance.sub(tokenTotalRewards[rewardToken]);
            pool.poolTotalRewards = pool.poolTotalRewards.add(mint);
            tokenTotalRewards[rewardToken] = balance;
        }
    }

    // Deposit points for Token allocation.
    function deposit(uint256 _pid, address _account, uint256 _fromPoints, uint256 _toPoints) internal {
        // require(_fromPoints <= _toPoints, 'deposit order error'); // for debug
        
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_account];
        (,,uint256 poolTotalPoints,) = ICompActionTrigger(pool.callFrom).getCATPoolInfo(pool.callId);
        uint256 addPoint = TenMath.safeSub(_toPoints, _fromPoints);
        uint256 poolTotalPointsOld = TenMath.safeSub(poolTotalPoints, addPoint);
    
        user.rewardRemain = pendingRewards(_pid, _account, _fromPoints, poolTotalPointsOld);

        uint256 poolDebt = 0;
        if(poolTotalPointsOld > 0) {
            poolDebt = TenMath.safeSub(pool.lastRewardTotal.mul(poolTotalPoints).div(poolTotalPointsOld), pool.lastRewardTotal);
        }

        user.rewardDebt = 0;
        pool.lastRewardTotal = pool.lastRewardTotal.add(poolDebt);
        if (poolTotalPoints > 0) {
            user.rewardDebt = pool.lastRewardTotal.mul(_toPoints).div(poolTotalPoints);
        }

        emit ActionDeposit(_account, _pid, _fromPoints, _toPoints);
    }

    // Withdraw LP tokens from StarPool.
    function withdraw(uint256 _pid, address _account, uint256 _fromPoints, uint256 _toPoints) internal {
        // require(_fromPoints >= _toPoints, 'deposit order error'); // debug

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_account];
        (,,uint256 poolTotalPoints,) = ICompActionTrigger(pool.callFrom).getCATPoolInfo(pool.callId);
        uint256 removePoint = TenMath.safeSub(_fromPoints, _toPoints);
        uint256 poolTotalPointsOld = poolTotalPoints.add(removePoint);

        // recorde rewards and recalculate debt
        user.rewardRemain = pendingRewards(_pid, _account, _fromPoints, poolTotalPointsOld);

        // recalculate lastRewardTotal
        uint256 poolDebt = TenMath.safeSub(pool.lastRewardTotal,
                                pool.lastRewardTotal.mul(poolTotalPoints).div(poolTotalPointsOld));
        pool.lastRewardTotal = TenMath.safeSub(pool.lastRewardTotal, poolDebt);

        user.rewardDebt = 0;
        if (poolTotalPoints > 0) {
            user.rewardDebt = pool.lastRewardTotal.mul(_toPoints).div(poolTotalPoints);
        }

        emit ActionWithdraw(_account, _pid, _fromPoints, _toPoints);
    }

    function claimIds(uint256[] memory _pidlist) external returns (uint256 value) {
        for (uint256 piid = 0; piid < _pidlist.length; ++piid) {
            value = value.add(claim(_pidlist[piid]));
        }
    }

    function claimFromBank(address _account, uint256[] memory _pidlist) external override returns (uint256 value) {
        require(bank==msg.sender, 'only call from bank');
        for (uint256 piid = 0; piid < _pidlist.length; ++piid) {
            value = value.add(_claim(_pidlist[piid], _account));
        }       
    }

    function claim(uint256 _pid) public returns (uint256 value) {
        return _claim(_pid, msg.sender);
    }

    function _claim(uint256 _pid, address _account) internal returns (uint256 value) {
        updatePool(_pid);
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_account];
        value = pendingRewards(_pid, _account);

        if (value > 0) {
            // make remain booking to debt and claim out
            user.rewardRemain = 0;
            user.rewardDebt = 0;
            user.rewardDebt = pendingRewards(_pid, _account);
            // pool.lastRewardTotal; // no changed
            pool.lastRewardClosed = TenMath.safeSub(pool.lastRewardClosed, value);
            
            if(rewardRestricted[_account] > 0) {
                value = TenMath.safeSub(value, value.mul(rewardRestricted[_account]).div(1e9));
            }
            pool.poolTotalRewards = TenMath.safeSub(pool.poolTotalRewards, value);
            address rewardToken = address(pool.rewardToken);
            tokenTotalRewards[rewardToken] = TenMath.safeSub(tokenTotalRewards[rewardToken], value);

            value = safeTokenTransfer(pool.rewardToken, _account, value);
        }

        emit ActionClaim(_account, _pid, value);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid, address _account) internal {
        _pid;
        _account;
    }

    // Safe Token transfer function, just in case if rounding error causes pool to not have enough Tokens.
    function safeTokenTransfer(IERC20 _token, address _to, uint256 _amount) internal returns (uint256 value) {
        uint256 balance = _token.balanceOf(address(this));
        value = _amount > balance ? balance : _amount;
        if ( value > 0 ) {
            _token.safeTransfer(_to, value);
            value =  TenMath.safeSub(balance, _token.balanceOf(address(this)));
        }
    }
}
