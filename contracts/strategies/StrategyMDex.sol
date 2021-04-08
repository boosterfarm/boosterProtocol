// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../../interfaces/IMdexRouter.sol";
import "../../interfaces/IMdexPair.sol";
import "../../interfaces/IMdexFactory.sol";
import "../interfaces/ISafeBox.sol";
import "../interfaces/IStrategyLink.sol";
import '../interfaces/IActionPools.sol';
import '../interfaces/ICompActionTrigger.sol';
import "../interfaces/ITenBankHall.sol";
import "../interfaces/IBuyback.sol";
import "../utils/TenMath.sol";
import "./StrategyMDexPools.sol";
import "./StrategyUtils.sol";

// Farming and Booking
contract StrategyMDex is StrategyMDexPools, Ownable, IStrategyLink, ICompActionTrigger {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 lpAmount;       // deposit lptoken amount
        uint256 lpPoints;       // deposit proportion
        address borrowFrom;     // borrowfrom 
        uint256 bid;            // borrow order id
    }

    // Info of each pool.
    struct PoolInfo {
        address[] collateralToken;      // collateral Token list, last must be baseToken
        address baseToken;              // baseToken can be borrowed
        IMdexPair lpToken;              // lptoken to deposit
        uint256 poolId;                 // poolid for mdex pools
        uint256 lastRewardsBlock;       //
        uint256 totalPoints;            // total of user lpPoints
        uint256 totalLPAmount;          // total of user lpAmount
        uint256 totalLPReinvest;        // total of lptoken amount with totalLPAmount and reinvest rewards
        uint256 miniRewardAmount;       //
    }

    IMdexFactory constant factory = IMdexFactory(0xb0b670fc1F7724119963018DB0BfA86aDb22d941);
    IMdexRouter constant router = IMdexRouter(0xED7d5F38C79115ca12fe6C0041abb22F0A06C300);

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public override userInfo;

    StrategyUtils public utils;            // some functions 
    address public override bank;          // address of bank
    IActionPools public compActionPool;    // address of comp action pool
    IBuyback public buyback;
 
    event AddPool(uint256 _pid, uint256 _poolId, address lpToken, address _baseToken);
    event SetSConfig(address _old, address _new);
    event SetCompAcionPool(address _old, address _new);
    event SetMiniRewardAmount(uint256 _pid, uint256 _miniRewardAmount);

    modifier onlyBank() {
        require(bank == msg.sender, 'mdex strategy only call by bank');
        _;
    }

    constructor(address _bank, address _sconfig) public {
        bank = _bank;
        utils = new StrategyUtils(address(_sconfig));
    }
    
    function getSource() external virtual override view returns (string memory) {
        return 'mdex';
    }

    function poolLength() external override view returns (uint256) {
        return poolInfo.length;
    }

    // for action pool, farming rewards
    function getCATPoolInfo(uint256 _pid) external override view 
        returns (address lpToken, uint256 allocRate, uint256 totalPoints, uint256 totalAmount) {
            lpToken = address(poolInfo[_pid].lpToken);
            allocRate = 5e8;
            totalPoints = poolInfo[_pid].totalPoints;
            totalAmount = poolInfo[_pid].totalLPReinvest;
    }

    function getCATUserAmount(uint256 _pid, address _account) external override view 
        returns (uint256 lpPoints) {
            lpPoints = userInfo[_pid][_account].lpPoints;
    }

    function getPoolInfo(uint256 _pid) external override view 
        returns(address[] memory collateralToken, address baseToken, address lpToken, 
            uint256 poolId, uint256 totalLPAmount, uint256 totalLPReinvest) {
        PoolInfo storage pool = poolInfo[_pid];
        collateralToken = pool.collateralToken;
        baseToken = address(pool.baseToken);
        lpToken = address(pool.lpToken);
        poolId = pool.poolId;
        totalLPAmount = pool.totalLPAmount;
        totalLPReinvest = pool.totalLPReinvest;
    }

    function getPoolCollateralToken(uint256 _pid) external override view returns (address[] memory collateralToken) {
        collateralToken = poolInfo[_pid].collateralToken;
    }

    function getPoollpToken(uint256 _pid) external override view returns (address lpToken) {
        lpToken = address(poolInfo[_pid].lpToken);
    }

    function getBaseToken(uint256 _pid) external override view returns (address baseToken) {
        baseToken = address(poolInfo[_pid].baseToken);
    }

    function getBorrowInfo(uint256 _pid, address _account) 
        external override view returns (address borrowFrom, uint256 bid) {
        borrowFrom = userInfo[_pid][_account].borrowFrom;
        bid = userInfo[_pid][_account].bid;
    }

    function getTokenBalance_this(address _token0, address _token1)
        internal view returns (uint256 a1, uint256 a2) {
        a1 = IERC20(_token0).balanceOf(address(this));
        a2 = IERC20(_token1).balanceOf(address(this));
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function addPool(uint256 _poolId, address[] memory _collateralToken, address _baseToken) public onlyOwner {
        require(_collateralToken.length == 2, 'lptoken pool only');

        address lpTokenInPools = poolDepositToken(_poolId);

        poolInfo.push(PoolInfo({
            collateralToken: _collateralToken,
            baseToken: _baseToken,
            lpToken: IMdexPair(lpTokenInPools),
            poolId: _poolId,
            lastRewardsBlock: block.number,
            totalPoints: 0,
            totalLPAmount: 0,
            totalLPReinvest: 0, 
            miniRewardAmount: 1e4
        }));

        uint256 pid = poolInfo.length.sub(1);
        require(utils.checkAddPoolLimit(pid, _baseToken, lpTokenInPools), 'check add pool limit');
        resetApprove(poolInfo.length.sub(1));
        emit AddPool(pid, _poolId, lpTokenInPools, _baseToken);
    }

    function resetApprove(uint256 _pid) public onlyOwner {
        PoolInfo storage pool = poolInfo[_pid];
        address rewardToken = poolRewardToken(pool.poolId);
        // approve to router
        IERC20(pool.collateralToken[0]).approve(address(router), uint256(-1));
        IERC20(pool.collateralToken[1]).approve(address(router), uint256(-1));
        IERC20(address(pool.lpToken)).approve(address(router), uint256(-1));
        IERC20(rewardToken).approve(address(router), uint256(-1));
        // approve to utils
        IERC20(pool.collateralToken[0]).approve(address(utils), uint256(-1));
        IERC20(pool.collateralToken[1]).approve(address(utils), uint256(-1));
        IERC20(address(pool.lpToken)).approve(address(utils), uint256(-1));
        IERC20(rewardToken).approve(address(utils), uint256(-1));
        // approve lptoken to mdex pool
        poolTokenApprove(address(pool.lpToken), uint256(-1));
    }
    
    function setCompAcionPool(address _compactionPool) external onlyOwner {
        emit SetCompAcionPool(address(compActionPool), _compactionPool);
        compActionPool = IActionPools(_compactionPool);
    }

    function setSConfig(address _sconfig) external onlyOwner {
        emit SetSConfig(address(utils.sconfig()), _sconfig);
        utils.setSConfig(_sconfig);
    }

    function setBuyback(address _buyback) external onlyOwner {
        buyback = IBuyback(_buyback);
    }

    function setMiniRewardAmount(uint256 _pid, uint256 _miniRewardAmount) external onlyOwner {
        emit SetMiniRewardAmount(_pid, _miniRewardAmount);
        poolInfo[_pid].miniRewardAmount = _miniRewardAmount;
    }

    // query user rewards  
    function pendingRewards(uint256 _pid, address _account) public override view returns (uint256 value) {
        value = pendingLPAmount(_pid, _account);
        value = TenMath.safeSub(value, userInfo[_pid][_account].lpAmount);
    }

    // query lpamount
    function pendingLPAmount(uint256 _pid, address _account) public override view returns (uint256 value) {
        PoolInfo storage pool = poolInfo[_pid];
        if(pool.totalPoints <= 0) {
            return 0;
        }
        value = userInfo[_pid][_account].lpPoints.mul(pool.totalLPReinvest).div(pool.totalPoints);
        value = TenMath.min(value, pool.totalLPReinvest);
    }
    
    function getBorrowAmount(uint256 _pid, address _account) public override view returns (uint256 amount) {
        amount = utils.getBorrowAmount(_pid, _account);
    }

    function getBorrowAmountInBaseToken(uint256 _pid, address _account) public override view returns (uint256 amount) {
        amount = utils.getBorrowAmountInBaseToken(_pid, _account);
    }

    function getDepositAmount(uint256 _pid, address _account) external override view returns (uint256 amount) {
        uint256 lpTokenAmount = pendingLPAmount(_pid, _account);
        amount = utils.getLPToken2TokenAmount(address(poolInfo[_pid].lpToken), poolInfo[_pid].baseToken, lpTokenAmount);
    }

    // update reward variables for all pools. 
    function massUpdatePools(uint256 _start, uint256 _end) external override {
        if(_end <= 0) {
            _end = poolInfo.length;
        }
        for (uint256 pid = _start; pid < _end; ++pid) {
            updatePool(pid);
        }
    }
    
    // update pools
    function updatePool(uint256 _pid) public override {
        PoolInfo storage pool = poolInfo[_pid];
        if(pool.lastRewardsBlock == block.number || 
            pool.totalLPReinvest <= 0) {
            pool.lastRewardsBlock = block.number;
            return ;
        }

        if(address(compActionPool) != address(0)) {
            compActionPool.onAcionUpdate(_pid);
        }

        pool.lastRewardsBlock = block.number;

        address token0 = pool.collateralToken[0];
        address token1 = pool.collateralToken[1];
        (uint256 uBalanceBefore0, uint256 uBalanceBefore1) = getTokenBalance_this(token0, token1);
        uint256 newRewards = poolClaim(pool.poolId);
        if(newRewards < pool.miniRewardAmount) {
            return ;
        }

        address rewardToken = poolRewardToken(pool.poolId);
        if(utils.getAmountIn(rewardToken, newRewards, pool.baseToken) <= 0) {
            return ;
        }

        uint256 newRewardBase = utils.getTokenIn(rewardToken, newRewards, pool.baseToken);

        // reinvestment fee
        utils.makeRefundFee(_pid, newRewardBase);

        // balance quantity
        (uint256 uBalanceAfter0, uint256 uBalanceAfter1) = getTokenBalance_this(token0, token1);

        makeBalanceOptimalLiquidityByAmount(_pid, 
                                uBalanceAfter0.sub(uBalanceBefore0), 
                                uBalanceAfter1.sub(uBalanceBefore1));

        (uBalanceAfter0, uBalanceAfter1) = getTokenBalance_this(token0, token1);

        // add liquidity and deposit to mdex pool
        uint256 lpAmount = makeLiquidityAndDepositByAmount(_pid,
                        uBalanceAfter0.sub(uBalanceBefore0), 
                        uBalanceAfter1.sub(uBalanceBefore1));
        (uBalanceAfter0, uBalanceAfter1) = getTokenBalance_this(token0, token1);
        
        pool.totalLPReinvest = pool.totalLPReinvest.add(lpAmount);
    }


    // deposit and withdraw
    function depositLPToken(uint256 _pid, address _account, address _borrowFrom,
                            uint256 _bAmount, uint256 _desirePrice, uint256 _slippage) 
                            public override onlyBank returns (uint256 lpAmount) {

        address token0 = poolInfo[_pid].collateralToken[0];
        address token1 = poolInfo[_pid].collateralToken[1];

        // remove to tokens
        uint256 withdrawLPAmount = poolInfo[_pid].lpToken.balanceOf(address(this));

        router.removeLiquidity(token0, token1, withdrawLPAmount, 0, 0, address(this), block.timestamp.add(60));

        // deposit
        lpAmount = deposit(_pid, _account, _borrowFrom, _bAmount, _desirePrice, _slippage);
    }

    function deposit(uint256 _pid, address _account, address _borrowFrom, 
                    uint256 _bAmount, uint256 _desirePrice, uint256 _slippage)
                    public override onlyBank returns (uint256 lpAmount) {

        UserInfo storage user = userInfo[_pid][_account];
        require(user.borrowFrom == address(0) || _bAmount == 0 ||
                user.borrowFrom == _borrowFrom, 
                'borrowFrom cannot changed');
        if(user.borrowFrom == address(0) && _borrowFrom != address(0)) {
            user.borrowFrom = _borrowFrom;
            address borrowToken = ISafeBox(user.borrowFrom).token();
            require( borrowToken == poolInfo[_pid].collateralToken[0] || 
                     borrowToken == poolInfo[_pid].collateralToken[1], "borrow token error");
        }

        require(utils.checkSlippageLimit(_pid, _desirePrice, _slippage), 'check slippage error');

        // update rewards
        updatePool(_pid);

        require(utils.checkBorrowLimit(_pid, _account, user.borrowFrom, _bAmount), 'borrow to limit');

        // deposit fee
        utils.makeDepositFee(_pid);

        // borrow
        makeBorrowBaseToken(_pid, _account, user.borrowFrom, _bAmount);

        // swap 
        makeBalanceOptimalLiquidity(_pid);
        
        // add liquidity and deposit
        lpAmount = makeLiquidityAndDeposit(_pid);

        // check pool deposit limit
        require(lpAmount > 0, 'no liqu lptoken');
        require(utils.checkDepositLimit(_pid, _account, lpAmount), 'farm lptoken amount to high');

        // return cash
        address token0 = poolInfo[_pid].collateralToken[0];
        address token1 = poolInfo[_pid].collateralToken[1];
        utils.transferFromAllToken(address(this), _account, token0, token1);

        // booking
        uint256 lpPointsOld = user.lpPoints;
        uint256 addPoint = lpAmount;
        if(poolInfo[_pid].totalLPReinvest > 0) {
            addPoint = lpAmount.mul(poolInfo[_pid].totalPoints).div(poolInfo[_pid].totalLPReinvest);
        }

        user.lpPoints = user.lpPoints.add(addPoint);
        poolInfo[_pid].totalPoints = poolInfo[_pid].totalPoints.add(addPoint);
        poolInfo[_pid].totalLPReinvest = poolInfo[_pid].totalLPReinvest.add(lpAmount);

        user.lpAmount = user.lpAmount.add(lpAmount);
        poolInfo[_pid].totalLPAmount = poolInfo[_pid].totalLPAmount.add(lpAmount);

        // check liquidation limit
        (,, uint256 borrowRate) =  makeWithdrawCalcAmount(_pid, _account);
        require(!utils.checkLiquidationLimit(_pid, _account, borrowRate), 'deposit in liquidation');
               
        emit StrategyDeposit(address(this), _pid, _account, lpAmount, _bAmount);

        if(address(compActionPool) != address(0) && addPoint > 0) {
            compActionPool.onAcionIn(_pid, _account, lpPointsOld, user.lpPoints);
        }
    }

    function makeBorrowBaseToken(uint256 _pid, address _account, address _borrowFrom, uint256 _bAmount) internal {
        if(_borrowFrom == address(0) || _bAmount <= 0) {
            return ;
        }

        if(userInfo[_pid][_account].borrowFrom == address(0)) {
            return ;
        }

        uint256 bid = ITenBankHall(bank).makeBorrowFrom(_pid, _account, _borrowFrom, _bAmount);

        emit StrategyBorrow(address(this), _pid, _account, _bAmount);

        if(userInfo[_pid][_account].bid != 0 && bid != 0) {
            require(userInfo[_pid][_account].bid == bid, 'cannot change bid order');
        }
        userInfo[_pid][_account].bid = bid;
    }

    function makeBalanceOptimalLiquidity(uint256 _pid) internal {
        // available balance
        address token0 = poolInfo[_pid].collateralToken[0];
        address token1 = poolInfo[_pid].collateralToken[1];
        (uint256 amount0, uint256 amount1) = getTokenBalance_this(token0, token1);
        makeBalanceOptimalLiquidityByAmount(_pid, amount0, amount1);
    }

    function makeBalanceOptimalLiquidityByAmount(uint256 _pid, uint256 _amount0, uint256 _amount1) internal {
        address pairs = factory.getPair(poolInfo[_pid].collateralToken[0], poolInfo[_pid].collateralToken[1]);
        address token0 = IMdexPair(pairs).token0();
        address token1 = IMdexPair(pairs).token1();
        if(token0 != poolInfo[_pid].collateralToken[0]) {
            (_amount0, _amount1) = (_amount1, _amount0);
        }
        (uint256 swapAmt, bool isReversed) = utils.optimalDepositAmount(address(pairs), _amount0, _amount1);
        if(swapAmt <= 0) {
            return ;
        }
        if(isReversed) {
            if(utils.getAmountIn(token1, swapAmt, token0) > 0) {
                utils.getTokenIn(token1, swapAmt, token0);
            }
        } else {
            if(utils.getAmountIn(token0, swapAmt, token1) > 0) {
                utils.getTokenIn(token0, swapAmt, token1);
            }  
        }
    }

    function makeLiquidityAndDeposit(uint256 _pid) internal returns (uint256 lpAmount) {
        // available balance
        address token0 = poolInfo[_pid].collateralToken[0];
        address token1 = poolInfo[_pid].collateralToken[1];
        (uint256 amount0, uint256 amount1) = getTokenBalance_this(token0, token1);
        lpAmount = makeLiquidityAndDepositByAmount(_pid, amount0, amount1);
    }

    function makeLiquidityAndDepositByAmount(uint256 _pid, uint256 _amount0, uint256 _amount1)
        internal returns (uint256 lpAmount) {

        // Available balance
        if(_amount0 <= 0 || _amount1 <= 0) {
            return 0;
        }
        // add liquidity
        uint256 uBalanceBefore = poolInfo[_pid].lpToken.balanceOf(address(this));
        router.addLiquidity(poolInfo[_pid].collateralToken[0], poolInfo[_pid].collateralToken[1], 
                        _amount0, _amount1, 0, 0, 
                        address(this), block.timestamp.add(60));
        uint256 uBalanceAfter = poolInfo[_pid].lpToken.balanceOf(address(this));

        // lptoken deposit to pool
        lpAmount = uBalanceAfter.sub(uBalanceBefore);
        if(lpAmount > 0) {
            poolDeposit(poolInfo[_pid].poolId, lpAmount);
        }
    }

    function withdrawLPToken(uint256 _pid, address _account, uint256 _rate, uint256 _desirePrice, uint256 _slippage) external override onlyBank {
        _withdraw(_pid, _account, _rate, _desirePrice, _slippage);

        // make withdraw token to lptoken
        address token0 = poolInfo[_pid].collateralToken[0];
        address token1 = poolInfo[_pid].collateralToken[1];
        makeBalanceOptimalLiquidity(_pid);
        (uint256 amount0, uint256 amount1) = getTokenBalance_this(token0, token1);
        if(amount0 != 0 && amount1 != 0) {
            router.addLiquidity(token0, token1, amount0, amount1, 0, 0, _account, block.timestamp.add(60));
        }
        utils.transferFromAllToken(address(this), _account, token0, token1);
        utils.transferFromAllToken(address(this), _account, poolInfo[_pid].baseToken, address(poolInfo[_pid].lpToken));
    }

    function withdraw(uint256 _pid, address _account, uint256 _rate, address _toToken, uint256 _desirePrice, uint256 _slippage) public override onlyBank {
        address token0 = poolInfo[_pid].collateralToken[0];
        address token1 = poolInfo[_pid].collateralToken[1];
        require(_toToken == token0 || _toToken == token1, 'totoken error');
        _withdraw(_pid, _account, _rate, _desirePrice, _slippage);
        address tokensell = _toToken == token0 ? token1 : token0;
        uint256 amountsell = IERC20(tokensell).balanceOf(address(this));
        if(amountsell > 0 && utils.getAmountIn(tokensell, amountsell, _toToken) > 0) {
            utils.getTokenIn(tokensell, amountsell, _toToken);
        }
        utils.transferFromAllToken(address(this), _account, token0, token1);
    }

    function _withdraw(uint256 _pid, address _account, uint256 _rate, uint256 _desirePrice, uint256 _slippage) internal {
        
        require(utils.checkSlippageLimit(_pid, _desirePrice, _slippage), 'check slippage error');

        // update rewards
        updatePool(_pid);

        UserInfo storage user = userInfo[_pid][_account];

        // calc rate
        (, uint256 rewardsRate, uint256 borrowRate) =  makeWithdrawCalcAmount(_pid, _account);
        require(poolInfo[_pid].totalPoints > 0 && poolInfo[_pid].totalLPReinvest > 0, 'empty pool');

        uint256 removedPoint = user.lpPoints.mul(_rate).div(1e9);
        uint256 withdrawLPTokenAmount = removedPoint.mul(poolInfo[_pid].totalLPReinvest).div(poolInfo[_pid].totalPoints);
        uint256 removedLPAmount = _rate >= 1e9 ? user.lpAmount : user.lpAmount.mul(_rate).div(1e9);

        // withdraw and remove liquidity
        withdrawLPTokenAmount = TenMath.min(withdrawLPTokenAmount, poolInfo[_pid].totalLPReinvest);
        makeWithdrawRemoveLiquidity(_pid, withdrawLPTokenAmount);

        if(borrowRate > 0) {
            // withdraw fee
            utils.makeWithdrawRewardFee(_pid, borrowRate, rewardsRate);
            // repay
            repayBorrow(_pid, _account, _rate, true);
        }

        // booking
        uint256 lpPointsOld = user.lpPoints;
        user.lpPoints = TenMath.safeSub(user.lpPoints, removedPoint);
        poolInfo[_pid].totalPoints = TenMath.safeSub(poolInfo[_pid].totalPoints, removedPoint);
        poolInfo[_pid].totalLPReinvest = TenMath.safeSub(poolInfo[_pid].totalLPReinvest, withdrawLPTokenAmount);

        user.lpAmount = TenMath.safeSub(user.lpAmount, removedLPAmount);
        poolInfo[_pid].totalLPAmount = TenMath.safeSub(poolInfo[_pid].totalLPAmount, removedLPAmount);

        emit StrategyWithdraw(address(this), _pid, _account, withdrawLPTokenAmount);

        if(address(compActionPool) != address(0) && removedPoint > 0) {
            compActionPool.onAcionOut(_pid, _account, lpPointsOld, user.lpPoints);
        }
    }

    function makeWithdrawCalcAmount(uint256 _pid, address _account) public view 
                returns (uint256 withdrawLPTokenAmount, uint256 rewardsRate, uint256 borrowRate) {
        UserInfo storage accountInfo = userInfo[_pid][_account];

        withdrawLPTokenAmount = pendingLPAmount(_pid, _account);

        if(withdrawLPTokenAmount > 0) {
            rewardsRate = pendingRewards(_pid, _account).mul(1e9).div(withdrawLPTokenAmount);
        }

        // calc borrow rate
        uint256 borrowAmount = getBorrowAmountInBaseToken(_pid, _account);        
        uint256 withdrawBaseAmount = utils.getLPToken2TokenAmount(address(poolInfo[_pid].lpToken), poolInfo[_pid].baseToken, withdrawLPTokenAmount);
        if (withdrawBaseAmount > 0) {
            borrowRate = borrowAmount.mul(1e9).div(withdrawBaseAmount);
        } else {
            borrowRate = uint256(1e4).mul(1e9);
        }
    }

    function makeWithdrawRemoveLiquidity(uint256 _pid, uint256 _withdrawLPTokenAmount) internal {
        address token0 = poolInfo[_pid].collateralToken[0];
        address token1 = poolInfo[_pid].collateralToken[1];

        // withdraw from mdex pool and remove liquidity
        poolWithdraw(poolInfo[_pid].poolId, _withdrawLPTokenAmount);
        router.removeLiquidity(token0, token1, _withdrawLPTokenAmount, 0, 0, address(this), block.timestamp.add(60));
    }

    function repayBorrow(uint256 _pid, address _account, uint256 _rate, bool _force) public override onlyBank {
        utils.makeRepay(_pid, userInfo[_pid][_account].borrowFrom, _account, _rate, _force);
        if(getBorrowAmount(_pid, _account) == 0) {
            userInfo[_pid][_account].borrowFrom = address(0);
            userInfo[_pid][_account].bid = 0;
        }
        if(_rate == 1e9 && _force) {
            require(getBorrowAmount(_pid, _account) == 0, 'repay not clear');
        }
    }

    function emergencyWithdraw(uint256 _pid, address _account) external override onlyBank {
        _emergencyWithdraw(_pid, _account);
    }

    function _emergencyWithdraw(uint256 _pid, address _account) internal {
        _account;
        UserInfo storage user = userInfo[_pid][_account];

        // total of deposit and reinvest
        uint256 withdrawLPTokenAmount = pendingLPAmount(_pid, _account);

        // booking
        poolInfo[_pid].totalLPReinvest = TenMath.safeSub(poolInfo[_pid].totalLPReinvest, withdrawLPTokenAmount);
        poolInfo[_pid].totalPoints = TenMath.safeSub(poolInfo[_pid].totalPoints, user.lpPoints);
        poolInfo[_pid].totalLPAmount = TenMath.safeSub(poolInfo[_pid].totalLPAmount, user.lpAmount);
        
        user.lpPoints = 0;
        user.lpAmount = 0;

        makeWithdrawRemoveLiquidity(_pid, withdrawLPTokenAmount);
        repayBorrow(_pid, _account, 1e9, true);

        utils.transferFromAllToken(address(this), _account, 
                        poolInfo[_pid].collateralToken[0], 
                        poolInfo[_pid].collateralToken[1]);
    }

    function liquidation(uint256 _pid, address _account, address _hunter, uint256 _maxDebt) external override onlyBank {
        _maxDebt;

        UserInfo storage user = userInfo[_pid][_account];
        PoolInfo storage pool = poolInfo[_pid];

        // update rewards
        updatePool(_pid);

        // check liquidation limit
        (,, uint256 borrowRate) =  makeWithdrawCalcAmount(_pid, _account);
        require(utils.checkLiquidationLimit(_pid, _account, borrowRate), 'not in liquidation');

        // check borrow amount
        uint256 borrowAmount = getBorrowAmount(_pid, _account);
        if(borrowAmount <= 0) {
            return ;
        }

        uint256 lpPointsOld = user.lpPoints;
        uint256 withdrawLPTokenAmount = pendingLPAmount(_pid, _account);
        // booking
        pool.totalLPAmount = TenMath.safeSub(pool.totalLPAmount, user.lpAmount);
        pool.totalLPReinvest = TenMath.safeSub(pool.totalLPReinvest, withdrawLPTokenAmount);
        pool.totalPoints = TenMath.safeSub(pool.totalPoints, user.lpPoints);
        
        user.lpPoints = 0;
        user.lpAmount = 0;

        // withdraw and remove liquidity
        if( withdrawLPTokenAmount > 0) {
            makeWithdrawRemoveLiquidity(_pid, withdrawLPTokenAmount);
        }

        emit StrategyLiquidation(address(this), _pid, _account, withdrawLPTokenAmount);

        // repay borrow
        repayBorrow(_pid, _account, 1e9, false);

        // swap all token to basetoken
        address tokensell = pool.baseToken == pool.collateralToken[0] ? 
                            pool.collateralToken[1] : pool.collateralToken[0];
        uint256 amountsell = IERC20(tokensell).balanceOf(address(this));
        if(amountsell > 0) {
            utils.getTokenIn(tokensell, amountsell, pool.baseToken);
        }

        // liquidation fee
        utils.makeLiquidationFee(_pid, pool.baseToken, borrowAmount);

        utils.transferFromAllToken(address(this), _hunter, 
                                pool.collateralToken[0], 
                                pool.collateralToken[1]);

        if(address(compActionPool) != address(0) && lpPointsOld > 0) {
            compActionPool.onAcionOut(_pid, _account, lpPointsOld, 0);
        }
    }

    function makeExtraRewards() external {
        if(address(buyback) == address(0)) {
            return ;
        }
        (address mdxToken, uint256 value) = utils.getMdexExtraReward();
        uint256 fee = value.mul(3e6).div(1e9);
        IERC20(mdxToken).transfer(msg.sender, fee);
        IERC20(mdxToken).approve(address(buyback), value.sub(fee));
        buyback.buyback(mdxToken, value.sub(fee));
    }
}
