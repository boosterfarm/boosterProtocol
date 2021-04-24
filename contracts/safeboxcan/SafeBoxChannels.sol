// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import '../../interfaces/IChannelsPool.sol';
import '../interfaces/ISafeBox.sol';

import './SafeBoxCanCToken.sol';

// Distribution of CAN token
contract SafeBoxChannels is SafeBoxCanCToken {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IChannelsPool public constant ipools = IChannelsPool(0x8955aeC67f06875Ee98d69e6fe5BDEA7B60e9770);
    IERC20 public constant REWARDS_TOKEN = IERC20(0x1e6395E6B059fc97a4ddA925b6c5ebf19E05c69f);

    uint256 public lastRewardsTokenBlock;        // rewards update
    
    address public actionPoolRewards;            // address for action pool
    uint256 public poolDepositId;               // poolid of depositor s token rewards in action pool, the action pool relate boopool deposit
    uint256 public poolBorrowId;                // poolid of borrower s token rewards in action pool 

    uint256 public constant REWARDS_DEPOSIT_CALLID = 16;      // depositinfo callid for action callback
    uint256 public constant REWARDS_BORROW_CALLID = 18;       // borrowinfo callid for comp action callback

    event SetRewardsDepositPool(address _actionPoolRewards, uint256 _piddeposit);
    event SetRewardsBorrowPool(address _compActionPool, uint256 _pidborrow);

    constructor (
        address _bank,
        address _cToken
    ) public SafeBoxCanCToken(_bank, _cToken) {
    }

    function update() public virtual override {
        _update();
        updatetoken();
    }

    // mint rewards for supplies to action pools
    function setRewardsDepositPool(address _actionPoolRewards, uint256 _piddeposit) public onlyOwner {
        actionPoolRewards = _actionPoolRewards;
        poolDepositId = _piddeposit;
        emit SetRewardsDepositPool(_actionPoolRewards, _piddeposit);
    }

    // mint rewards for borrows to comp action pools
    function setRewardsBorrowPool(uint256 _pidborrow) public onlyOwner {
        _checkActionPool(compActionPool, _pidborrow, REWARDS_BORROW_CALLID);
        poolBorrowId = _pidborrow;
        emit SetRewardsBorrowPool(compActionPool, _pidborrow);
    }

    function _checkActionPool(address _actionPool, uint256 _pid, uint256 _rewardscallid) internal view {
        (address callFrom, uint256 callId, address rewardToken)
            = IActionPools(_actionPool).getPoolInfo(_pid);
        require(callFrom == address(this), 'call from error');
        require(callId == _rewardscallid, 'callid error');
        require(rewardToken == address(REWARDS_TOKEN), 'rewardToken error');
    }

    function deposit(uint256 _value) external virtual override nonReentrant {
        update();
        IERC20(token).safeTransferFrom(msg.sender, address(this), _value);
        _deposit(msg.sender, _value);
    }

    function withdraw(uint256 _tTokenAmount) external virtual override nonReentrant {
        update();
        _withdraw(msg.sender, _tTokenAmount);
    }
    
    function borrow(uint256 _bid, uint256 _value, address _to) external virtual override onlyBank {
        update();
        address owner = borrowInfo[_bid].owner;
        uint256 accountBorrowPointsOld = accountBorrowPoints[owner];
        _borrow(_bid, _value, _to);

        if(compActionPool != address(0) && _value > 0) {
            IActionPools(compActionPool).onAcionIn(REWARDS_DEPOSIT_CALLID, owner, 
                    accountBorrowPointsOld, accountBorrowPoints[owner]);
        }
    }

    function repay(uint256 _bid, uint256 _value) external virtual override {
        update();
        address owner = borrowInfo[_bid].owner;
        uint256 accountBorrowPointsOld = accountBorrowPoints[owner];
        _repay(_bid, _value);

        if(compActionPool != address(0) && _value > 0) {
            IActionPools(compActionPool).onAcionOut(REWARDS_BORROW_CALLID, owner, 
                    accountBorrowPointsOld, accountBorrowPoints[owner]);
        }
    }

    function updatetoken() public {
        if(lastRewardsTokenBlock == block.number) {
            return ;
        }
        lastRewardsTokenBlock = block.number;
        
        // FILDA pools
        address[] memory holders = new address[](1);
        holders[0] = address(this);
        address[] memory cTokens = new address[](1);
        cTokens[0] = address(cToken);

        uint256 uBalanceBefore;
        uint256 uBalanceAfter;

        // rewards for borrow, mint for comp action pool
        if(borrowTotalAmountWithPlatform > 0 && compActionPool != address(0)) {
            uBalanceBefore = REWARDS_TOKEN.balanceOf(address(this));
            ipools.claimCan(holders, cTokens, true, false);
            uBalanceAfter = REWARDS_TOKEN.balanceOf(address(this));
            uint256 borrowerRewards = uBalanceAfter.sub(uBalanceBefore);
            REWARDS_TOKEN.transfer(compActionPool, borrowerRewards);
            IActionPools(compActionPool).mintRewards(poolBorrowId);
        }

        // rewards for supply, mint for action pool
        if(totalSupply() > 0 && actionPoolRewards != address(0)) {
            uBalanceBefore = REWARDS_TOKEN.balanceOf(address(this));
            ipools.claimCan(holders, cTokens, false, true);
            uBalanceAfter = REWARDS_TOKEN.balanceOf(address(this));
            uint256 supplyerRewards = uBalanceAfter.sub(uBalanceBefore);
            REWARDS_TOKEN.transfer(actionPoolRewards, supplyerRewards);
            IActionPools(actionPoolRewards).mintRewards(poolDepositId);
        }
    }

    function claim(uint256 _value) external virtual override nonReentrant {
        update();
        _claim(msg.sender, _value);
    }
}
