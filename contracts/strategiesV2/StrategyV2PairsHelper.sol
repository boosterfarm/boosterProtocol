// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../interfaces/ISafeBox.sol";
import '../interfaces/IActionPools.sol';
import '../interfaces/ICompActionTrigger.sol';
import "../interfaces/ITenBankHallV2.sol";
import "../interfaces/IBuyback.sol";
import "../interfaces/IPriceChecker.sol";
import "../interfaces/IStrategyV2Pair.sol";
import "../interfaces/IStrategyV2PairHelper.sol";

import "../utils/TenMath.sol";
import "./StrategyV2Data.sol";

// Borrow and Repay
contract StrategyV2PairHelper is StrategyV2Data, IStrategyV2PairHelper {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    constructor() public {
    }

    // check limit 
    function checkAddPoolLimit(uint256 _pid) external view {
        PoolInfo memory pool = poolInfo[_pid];
        require(pool.collateralToken[0] == pool.baseToken ||
                pool.collateralToken[1] == pool.baseToken, 
                'baseToken not in pair');
        require(swapPoolImpl.getDepositToken(pool.poolId) == pool.lpToken, 'lptoken error');
    }

    function checkDepositLimit(uint256 _pid, address _account, uint256 _orginSwapRate) external view {
        _account;
        require(address(sconfig) != address(0), 'not config');
        uint256 farmLimit = sconfig.getFarmPoolFactor(_this, _pid);
        if(farmLimit > 0) {
            require(poolInfo[_pid].totalLPReinvest <= farmLimit, 'pool invest limit');
        }

        (uint256 res0, uint256 res1) = swapPoolImpl.getReserves(poolInfo[_pid].lpToken);
        uint256 curSwapRate = res0.mul(1e18).div(res1);
        uint256 slippage = poolConfig[_pid][string('deposit_slippage')];
        require(slippage > 0, 'deposit_slippage == 0');
        uint256 swapSlippage = _orginSwapRate.mul(1e9).div(curSwapRate);
        require(swapSlippage < slippage.add(1e9) && 
                swapSlippage > uint256(1e9).sub(slippage), 'pool slippage over');
    }

    function checkLiquidationLimit(uint256 _pid, address _account, bool liqucheck) external view {
        require(address(sconfig) != address(0), 'not config liquidation');
        
        uint256 liquRate = sconfig.getLiquidationFactor(_this, _pid);
        uint256 borrowAmount = IStrategyV2Pair(_this).getBorrowAmountInBaseToken(_pid, _account);
        if(borrowAmount == 0) {
            return ;
        }

        uint256 holdLPTokenAmount = IStrategyV2Pair(_this).pendingLPAmount(_pid, _account);
        uint256 holdBaseAmount = swapPoolImpl.getLPTokenAmountInBaseToken(poolInfo[_pid].lpToken, holdLPTokenAmount, poolInfo[_pid].baseToken);
        if(liqucheck) {
            // check whether in liquidation 
            if(holdBaseAmount > 0) {
                require(borrowAmount.mul(1e9).div(holdBaseAmount) > liquRate, 'check in liquidation');
            }
        } else {
            // check must not in liquidation
            require(holdBaseAmount > 0, 'no hold in liquidation');
            require(borrowAmount.mul(1e9).div(holdBaseAmount) < liquRate, 'check out liquidation');
        }
    }

    function checkOraclePrice(uint256 _pid, bool _large) external view {
        if(address(priceChecker) == address(0)) {
            return ;
        }
        bool oracle = priceChecker.checkLPTokenPriceLimit(poolInfo[_pid].lpToken, _large);
        require(oracle, 'oracle price limit');
    }

    function checkBorrowLimit(uint256 _pid, address _account) external view {
        PoolInfo memory pool = poolInfo[_pid];
        UserInfo storage user = userInfo2[_pid][_account];

        uint256 borrowAmount = IStrategyV2Pair(_this).getBorrowAmountInBaseToken(_pid, _account);
        uint256 holdBaseAmount = IStrategyV2Pair(_this).getDepositAmount(_pid, _account);
        uint256 borrowFactor = sconfig.getBorrowFactor(_this, _pid);

        require(borrowAmount <= holdBaseAmount.mul(borrowFactor).div(1e9), 'borrow limit');
    }

    function calcDepositFee(uint256 _pid)
        external view returns (address gather, uint256 _amount0, uint256 _amount1) {
        PoolInfo storage pool = poolInfo[_pid];
        uint256 feerate;
        (gather, feerate) = sconfig.getDepositFee(_this, _pid);
        _amount0 = IERC20(pool.collateralToken[0]).balanceOf(_this).mul(feerate).div(1e9);
        _amount1 = IERC20(pool.collateralToken[1]).balanceOf(_this).mul(feerate).div(1e9);
    }


    function calcRefundFee(uint256 _pid, uint256 _rewardAmount)
        public view returns (address gather, uint256 feeAmount) {
        PoolInfo storage pool = poolInfo[_pid];
        uint256 feerate;
        (gather, feerate) = sconfig.getRefundFee(_this, _pid);
        feeAmount = _rewardAmount.mul(feerate).div(1e9);
    }

    function calcBorrowAmount(uint256 _pid, address _account, address _debtFrom, uint256 _bAmount) 
        external view returns (uint256 bindex, uint256 amount) {
        if(_debtFrom == address(0)) return (0, 0);

        PoolInfo memory pool = poolInfo[_pid];
        address token0 = pool.collateralToken[0];
        address token1 = pool.collateralToken[1];
        amount = _bAmount;

        {
            // check _debtFrom address book in bank
            uint256 debtid = ITenBankHallV2(_bank).boxIndex(_debtFrom);
            require(debtid > 0 || ITenBankHallV2(_bank).boxInfo(debtid) == _debtFrom, 'borrow from bank');
        }

        address borrowToken = ISafeBox(_debtFrom).token();
        require(borrowToken == token0 || borrowToken == token1, 'debtFrom token error');

        bindex = borrowToken == token0 ? 0 : 1;
        if(amount > 0) {
            return (bindex, amount);
        }
        
        (uint256 res0, uint256 res1) = swapPoolImpl.getReserves(pool.lpToken);
        {
            (address token00,) = swapPoolImpl.getToken01(pool.lpToken);
            (res0, res1) = token00 == token0 ? (res0, res1) : (res1, res0);
        }

        uint256 balance0 = IERC20(token0).balanceOf(_this);
        uint256 balance1 = IERC20(token1).balanceOf(_this);
        if(bindex == 0) {
            amount = balance1.mul(res0).div(res1);
            if(amount > balance0) amount = amount.sub(balance0);
        } else {
            amount = balance0.mul(res1).div(res0);
            if(amount > balance1) amount = amount.sub(balance1);
        }
    }

    function calcRemoveLiquidity(uint256 _pid, address _account, uint256 _rate) 
        external view returns (uint256 removedLPAmount, uint256 removedPoint) {
        PoolInfo memory pool = poolInfo[_pid];
        UserInfo storage user = userInfo2[_pid][_account];
        if(pool.totalPoints == 0) {
            return (0, 0);
        }
        if(_rate >= 1e9) {
            removedPoint = user.lpPoints;
        } else {
            removedPoint = user.lpPoints.mul(_rate).div(1e9);
        }
        removedLPAmount = removedPoint.mul(pool.totalLPReinvest).div(pool.totalPoints);
        removedLPAmount = TenMath.min(removedLPAmount, pool.totalLPReinvest);
    }

    function calcWithdrawFee(uint256 _pid, address _account, uint256 _rate)
        external view returns (address gather, uint256 a0, uint256 a1) {

        // sconfig.
        uint256 feerate;
        (gather, feerate) = sconfig.getWithdrawFee(_this, _pid);
        return (gather, 0, 0);

        uint256 borrowAmount = IStrategyV2Pair(_this).getBorrowAmountInBaseToken(_pid, _account);
        uint256 holdLPTokenAmount = IStrategyV2Pair(_this).pendingLPAmount(_pid, _account);
        uint256 holdLPRewardsAmount = IStrategyV2Pair(_this).pendingRewards(_pid, _account);
        if(holdLPRewardsAmount == 0 || holdLPTokenAmount == 0) {
            return (gather, 0, 0);
        }
        PoolInfo memory pool = poolInfo[_pid];
        uint256 holdBaseAmount = swapPoolImpl.getLPTokenAmountInBaseToken(pool.lpToken, holdLPTokenAmount, pool.baseToken);
        uint256 borrowRate = borrowAmount.mul(1e9).div(holdBaseAmount);
        if(borrowRate == 0) {
            return (gather, 0, 0);
        }
        uint256 rewardsRate = holdLPRewardsAmount.mul(1e9).div(holdLPTokenAmount);
        uint256 rewardsByBorrowRate = rewardsRate.mul(borrowRate).div(1e9).mul(feerate).div(1e9);
        a0 = IERC20(pool.collateralToken[0]).balanceOf(_this).mul(rewardsByBorrowRate).div(1e9);
        a1 = IERC20(pool.collateralToken[1]).balanceOf(_this).mul(rewardsByBorrowRate).div(1e9);
    }

    function calcLiquidationFee(uint256 _pid, address _account)
        public view returns (address gather, uint256 baseAmount) {
        if(address(sconfig) == address(0)) return (address(0), 0);

        PoolInfo memory pool = poolInfo[_pid];
        uint256 feerate;
        (gather, feerate) = sconfig.getLiquidationFee(_this, _pid);
        baseAmount = IERC20(pool.baseToken).balanceOf(_this).mul(feerate).div(1e9);
    }

    function calcWithdrawRepayBorrow(uint256 _pid, address _account, uint256 _rate, uint256 _index) 
        public view returns (address token, uint256 amount, bool swap, uint256 swapAmount) {

        UserInfo storage user = userInfo2[_pid][_account];
        if(_index >= user.borrowFrom.length || user.borrowFrom[_index] == address(0)) {
            return (address(0), 0, false, 0);
        }

        PoolInfo memory pool = poolInfo[_pid];
        ISafeBox borrowFrom = ISafeBox(user.borrowFrom[_index]);
        token = borrowFrom.token();

        amount = borrowFrom.pendingBorrowAmount(user.bids[_index]);
        amount = amount.add(borrowFrom.pendingBorrowRewards(user.bids[_index]));
        if(_rate < 1e9) {
            amount = amount.mul(_rate).div(1e9);
        }

        uint256 balance = IERC20(token).balanceOf(_this);
        if(balance < amount) {
            address swapToken = _index == 0 ? pool.collateralToken[1] : pool.collateralToken[0];
            swap = swapToken == pool.collateralToken[1];
            swapAmount = swapPoolImpl.getAmountOut(swapToken, token, amount.sub(balance));
            swapAmount = TenMath.min(swapAmount, IERC20(swapToken).balanceOf(_this));
        }
    }

    function getBorrowAmount(uint256 _pid, address _account, uint _index)
        public view returns (address token, uint256 amount) {
        address borrowFrom = userInfo2[_pid][_account].borrowFrom[_index];
        if(borrowFrom == address(0)) return (borrowFrom, 0);

        uint256 bid = userInfo2[_pid][_account].bids[_index];
        token = ISafeBox(borrowFrom).token();
        amount = ISafeBox(borrowFrom).pendingBorrowAmount(bid);
        amount = amount.add(ISafeBox(borrowFrom).pendingBorrowRewards(bid));
    }

    function getBorrowAmountInBaseToken(uint256 _pid, address _account)
        external view returns (uint256 amount) {
        UserInfo storage user = userInfo2[_pid][_account];
        for(uint256 i = 0; i < user.borrowFrom.length; i ++) {
            (address token, uint256 value) = getBorrowAmount(_pid, _account, i);
            if(value == 0) continue ;
            amount = amount.add(swapPoolImpl.getAmountIn(token, value, poolInfo[_pid].baseToken));
        }
    }
}