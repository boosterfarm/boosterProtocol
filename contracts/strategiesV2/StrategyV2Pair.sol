// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../interfaces/ISafeBox.sol";
import '../interfaces/IActionPools.sol';
import '../interfaces/ICompActionTrigger.sol';
import "../interfaces/ITenBankHall.sol";
import "../interfaces/IStrategyV2Pair.sol";
import "../interfaces/IStrategyV2PairHelper.sol";

import "../utils/TenMath.sol";
import "./StrategyV2Data.sol";
import "./StrategyV2PairsHelper.sol";

// farm strategy
contract StrategyV2Pair is StrategyV2Data, Ownable, IStrategyV2Pair, ICompActionTrigger {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    constructor(address bank_) public {
        _bank = bank_;
        _this = address(this);
        helperImpl = address(new StrategyV2PairHelper());
    }
    
    modifier onlyBank() {
        require(_bank == msg.sender, 'strategy only call by bank');
        _;
    }

    function bank() external override view returns(address) {
        return _bank;
    }

    function getSource() external override view returns (string memory source) {
        source = string(abi.encodePacked(swapPoolImpl.getName(), "_v2"));
    }

    function utils() external view returns(address) {
        // Compatible with old version 1
        return address(0);
    }

    function setPoolImpl(address _swapPoolImpl) external onlyOwner {
        require(address(swapPoolImpl) == address(0), 'only once');
        emit SetPoolImpl(_this, _swapPoolImpl);
        swapPoolImpl = IStrategyV2SwapPool(_swapPoolImpl);
    }

    function setComponents(address _compActionPool, address _buyback, address _priceChecker, address _config)
        external onlyOwner {
        compActionPool = IActionPools(_compActionPool);
        buyback = IBuyback(_buyback);
        priceChecker = IPriceChecker(_priceChecker);
        sconfig = IStrategyConfig(_config);
        emit SetComponents(_compActionPool, _buyback, _priceChecker, _config);
    }

    function setPoolConfig(uint256 _pid, string memory _key, uint256 _value)
        external onlyOwner {
        poolConfig[_pid][_key] = _value;
        emit SetPoolConfig(_pid, _key, _value);
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
        lpPoints = userInfo2[_pid][_account].lpPoints;
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

    function userInfo(uint256 _pid, address _account)
        external override view returns (uint256 lpAmount, uint256 lpPoints, address borrowFrom, uint256 bid) {
        // Compatible with old version 1
        UserInfo storage user = userInfo2[_pid][_account];
        lpAmount = user.lpAmount;
        lpPoints = user.lpPoints;
        borrowFrom;
        bid;
    }

    function getBorrowInfo(uint256 _pid, address _account) 
        external override view returns (address borrowFrom, uint256 bid) {
        (borrowFrom, bid, ) = getBorrowInfo(_pid, _account, 0);
        if(borrowFrom == address(0)) {
            (borrowFrom, bid, ) = getBorrowInfo(_pid, _account, 1);
        }
    }

    function getBorrowInfo(uint256 _pid, address _account, uint256 _bindex) 
        public override view returns (address borrowFrom, uint256 bid, uint256 amount) {
        UserInfo storage user = userInfo2[_pid][_account];
        if(_bindex >= user.borrowFrom.length) return (address(0), 0, 0);
        borrowFrom = user.borrowFrom[_bindex];
        bid = user.bids[_bindex];
        if(borrowFrom == address(0)) return (address(0), 0, 0);
        amount = ISafeBox(borrowFrom).pendingBorrowAmount(bid);
        amount = amount.add(ISafeBox(borrowFrom).pendingBorrowRewards(bid));
    }
    
    function pendingLPAmount(uint256 _pid, address _account) public override view returns (uint256 value) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo2[_pid][_account];
        if(pool.totalPoints <= 0) return 0;

        value = user.lpPoints.mul(pool.totalLPReinvest).div(pool.totalPoints);
        value = TenMath.min(value, pool.totalLPReinvest);
    }

    function getDepositAmount(uint256 _pid, address _account) external override view returns (uint256 amount) {
        PoolInfo storage pool = poolInfo[_pid];
        uint256 lpTokenAmount = pendingLPAmount(_pid, _account);
        amount = swapPoolImpl.getLPTokenAmountInBaseToken(pool.lpToken, lpTokenAmount, pool.baseToken);
    }

    function getPoolCollateralToken(uint256 _pid) external override view returns (address[] memory collateralToken) {
        collateralToken = poolInfo[_pid].collateralToken;
    }

    function getPoollpToken(uint256 _pid) external override view returns (address lpToken) {
        lpToken = poolInfo[_pid].lpToken;
    }

    function getBaseToken(uint256 _pid) external override view returns (address baseToken) {
        baseToken = poolInfo[_pid].baseToken;
    }

    // query user rewards  
    function pendingRewards(uint256 _pid, address _account) public override view returns (uint256 value) {
        UserInfo storage user = userInfo2[_pid][_account];
        value = pendingLPAmount(_pid, _account);
        value = TenMath.safeSub(value, user.lpAmount);
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function addPool(uint256 _poolId, address[] memory _collateralToken, address _baseToken)
        external onlyOwner {

        require(_collateralToken.length == 2);
        address lpTokenInPools = swapPoolImpl.getPair(_collateralToken[0], _collateralToken[1]);
        poolInfo.push(PoolInfo({
            collateralToken: _collateralToken,
            baseToken: _baseToken,
            lpToken: lpTokenInPools,
            poolId: _poolId,
            lastRewardsBlock: block.number,
            totalPoints: 0,
            totalLPAmount: 0,
            totalLPReinvest: 0, 
            miniRewardAmount: 1e4
        }));

        uint256 pid = poolInfo.length.sub(1);
        checkAddPoolLimit(pid);

        emit AddPool(pid, _poolId, lpTokenInPools, _baseToken);
    }

    function checkAddPoolLimit(uint256 _pid) public view {
        delegateToViewImplementation(
            abi.encodeWithSignature("checkAddPoolLimit(uint256)", _pid));
    }

    function checkDepositLimit(uint256 _pid, address _account, uint256 _orginSwapRate) public view {
        delegateToViewImplementation(
            abi.encodeWithSignature("checkDepositLimit(uint256,address,uint256)", _pid, _account, _orginSwapRate));
    }

    function checkLiquidationLimit(uint256 _pid, address _account, bool liqucheck) public view {
        delegateToViewImplementation(
            abi.encodeWithSignature("checkLiquidationLimit(uint256,address,bool)", _pid, _account, liqucheck));
    }

    function checkOraclePrice(uint256 _pid, bool _large) public view {
        delegateToViewImplementation(
            abi.encodeWithSignature("checkOraclePrice(uint256,bool)", _pid, _large));
    }

    function checkBorrowLimit(uint256 _pid, address _account) public view {
        delegateToViewImplementation(
            abi.encodeWithSignature("checkBorrowLimit(uint256,address)", _pid, _account));
    }

    function calcDepositFee(uint256 _pid) 
        public view returns (address feer, uint256 a0, uint256 a1) {
        bytes memory data = delegateToViewImplementation(
            abi.encodeWithSignature("calcDepositFee(uint256)", _pid));
        return abi.decode(data, (address,uint256,uint256));
    }
    
    function calcBorrowAmount(uint256 _pid, address _account, address _debtFrom, uint256 _bAmount) 
        public view returns (uint256 bindex, uint256 amount) {
        bytes memory data = delegateToViewImplementation(
            abi.encodeWithSignature("calcBorrowAmount(uint256,address,address,uint256)",
                    _pid,_account,_debtFrom,_bAmount));
        return abi.decode(data, (uint256,uint256));
    }

    function calcRemoveLiquidity(uint256 _pid, address _account, uint256 _rate) 
        public view returns (uint256 removedLPAmount, uint256 removedPoint) {
        bytes memory data = delegateToViewImplementation(
            abi.encodeWithSignature("calcRemoveLiquidity(uint256,address,uint256)",
                    _pid,_account,_rate));
        return abi.decode(data, (uint256,uint256));
    }

    function calcWithdrawFee(uint256 _pid, address _account, uint256 _rate)
        public view returns (address gather, uint256 a0, uint256 a1) {
        bytes memory data = delegateToViewImplementation(
            abi.encodeWithSignature("calcWithdrawFee(uint256,address,uint256)",
                    _pid,_account,_rate));
        return abi.decode(data, (address,uint256,uint256));
    }

    function calcLiquidationFee(uint256 _pid, address _account)
        public view returns (address gather, uint256 baseAmount) {
        bytes memory data = delegateToViewImplementation(
            abi.encodeWithSignature("calcLiquidationFee(uint256,address)",
                    _pid,_account));
        return abi.decode(data, (address,uint256));
    }

    function calcRefundFee(uint256 _pid, uint256 _rewardAmount)
        public view returns (address gather, uint256 baseAmount) {
        bytes memory data = delegateToViewImplementation(
            abi.encodeWithSignature("calcRefundFee(uint256,uint256)",
                    _pid,_rewardAmount));
        return abi.decode(data, (address,uint256));
    }

    function calcWithdrawRepayBorrow(uint256 _pid, address _account, uint256 _rate, uint256 _index) 
        public view returns (address token, uint256 amount, bool swap, uint256 swapAmount) {
        bytes memory data = delegateToViewImplementation(
            abi.encodeWithSignature("calcWithdrawRepayBorrow(uint256,address,uint256,uint256)",
                    _pid,_account,_rate,_index));
        return abi.decode(data, (address,uint256,bool,uint256));
    }

    function getBorrowAmount(uint256 _pid, address _account)
        external override view returns (uint256 value) {
        // Compatible with old version 1
        value = getBorrowAmountInBaseToken(_pid, _account);
    }

    function getBorrowAmountInBaseToken(uint256 _pid, address _account)
        public override view returns (uint256 amount) {
        bytes memory data = delegateToViewImplementation(
            abi.encodeWithSignature("getBorrowAmountInBaseToken(uint256,address)",
                    _pid,_account));
        return abi.decode(data, (uint256));
    }

    // function massUpdatePools(uint256 _start, uint256 _end) external;
    function updatePool(uint256 _pid, uint256 _unused, uint256 _minOutput) external override {
        _unused;
        checkOraclePrice(_pid, true);
        uint256 lpAmount = _updatePool(_pid);
        require(lpAmount >= _minOutput, 'insufficient LP output');
    }

    function _updatePool(uint256 _pid) internal returns (uint256 lpAmount) {
        PoolInfo storage pool = poolInfo[_pid];

        if(address(compActionPool) != address(0)) {
            compActionPool.onAcionUpdate(_pid);
        }

        if(pool.lastRewardsBlock == block.number || 
            pool.totalLPReinvest <= 0) {
            pool.lastRewardsBlock = block.number;
            return 0;
        }
        pool.lastRewardsBlock = block.number;

        address refundToken = swapPoolImpl.getRewardToken(pool.poolId);
        uint256 newRewards = swapPoolImpl.getPending(pool.poolId);

        if(newRewards < pool.miniRewardAmount) {
            return 0;
        }

        newRewards = swapPoolImpl.claim(pool.poolId);

        // gather fee
        {
            (address gather, uint256 feeamount) = calcRefundFee(_pid, newRewards);
            if(feeamount > 0) IERC20(refundToken).safeTransfer(gather, feeamount);
            newRewards = newRewards.sub(feeamount);
        }

        // swap to basetoken
        if(refundToken != pool.collateralToken[0] && refundToken != pool.collateralToken[1]) {
            IERC20(refundToken).safeTransfer(address(swapPoolImpl), newRewards);
            newRewards = swapPoolImpl.swapTokenTo(refundToken, newRewards, pool.baseToken, _this);
            refundToken = pool.baseToken;
        }

        IERC20(refundToken).safeTransfer(address(swapPoolImpl), newRewards);
        lpAmount = swapPoolImpl.deposit(pool.poolId, true);

        pool.totalLPReinvest = pool.totalLPReinvest.add(lpAmount);
    }

    function deposit(uint256 _pid, address _account, address _debtFrom0,
                uint256 _bAmount0, uint256 _debtFrom1, uint256 _minOutput) 
        external override onlyBank returns (uint256 lpAmount) {
        lpAmount = _deposit(_pid, _account, _debtFrom0, _bAmount0, address(_debtFrom1), _minOutput);
    }

    function depositLPToken(uint256 _pid, address _account, address _debtFrom0,
                uint256 _bAmount0, uint256 _debtFrom1, uint256 _minOutput)
        external override onlyBank returns (uint256 lpAmount) {
        PoolInfo storage pool = poolInfo[_pid];
        uint256 liquidity = _safeTransferAll(pool.lpToken, address(swapPoolImpl));
        swapPoolImpl.withdraw(_pid, liquidity, false);
        lpAmount = _deposit(_pid, _account, _debtFrom0, _bAmount0, address(_debtFrom1), _minOutput);
    }

    function _deposit(uint256 _pid, address _account, address _debtFrom0, 
        uint256 _bAmount0, address _debtFrom1, uint256 _minOutput)
        internal returns (uint256 lpAmount)  {

        require(tx.origin == _account, 'not contract');

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo2[_pid][_account];

        // update rewards
        _updatePool(_pid);

        address token0 = pool.collateralToken[0];
        address token1 = pool.collateralToken[1];
        uint256 orginSwapRate = 0;
        {
            (uint256 res0, uint256 res1) = swapPoolImpl.getReserves(pool.lpToken);
            orginSwapRate = res0.mul(1e18).div(res1);
        }

        // borrow
        if(user.borrowFrom.length == 0) {
            user.borrowFrom = new address[](2);
            user.bids = new uint256[](2);
        }

        if(_bAmount0 > 0) {
            checkOraclePrice(_pid, false);  // Only Check the price when there is leverage
            _makeBorrow(_pid, _account, _debtFrom0, _bAmount0);
            _makeBorrow(_pid, _account, _debtFrom1, 0); // 0 = auto fit balance
        }

        // deposit fee
        {
            (address gather, uint256 bAmount0, uint256 bAmount1) = calcDepositFee(_pid);
            if(bAmount0 > 0) IERC20(token0).safeTransfer(gather, bAmount0);
            if(bAmount1 > 0) IERC20(token1).safeTransfer(gather, bAmount1);
        }
        
        // add liquidity and deposit
        _safeTransferAll(token0, address(swapPoolImpl));
        _safeTransferAll(token1, address(swapPoolImpl));
        lpAmount = swapPoolImpl.deposit(pool.poolId, true);

        // return cash
        _safeTransferAll(token0, _account);
        _safeTransferAll(token1, _account);

        // // booking
        uint256 lpPointsOld = user.lpPoints;
        uint256 addPoint = lpAmount;
        if(pool.totalLPReinvest > 0) {
            addPoint = lpAmount.mul(pool.totalPoints).div(pool.totalLPReinvest);
        }

        user.lpPoints = user.lpPoints.add(addPoint);
        pool.totalPoints = pool.totalPoints.add(addPoint);
        pool.totalLPReinvest = pool.totalLPReinvest.add(lpAmount);

        user.lpAmount = user.lpAmount.add(lpAmount);
        pool.totalLPAmount = pool.totalLPAmount.add(lpAmount);

        emit StrategyDeposit(_this, _pid, _account, lpAmount, _bAmount0);

        // check pool deposit limit
        require(lpAmount >= _minOutput, 'insufficient LP output');
        checkDepositLimit(_pid, _account, orginSwapRate);
        checkBorrowLimit(_pid, _account);
        checkLiquidationLimit(_pid, _account, false);

        if(address(compActionPool) != address(0) && addPoint > 0) {
            compActionPool.onAcionIn(_pid, _account, lpPointsOld, user.lpPoints);
        }
    }
    
    function withdraw(uint256 _pid, address _account, uint256 _rate, address _toToken, uint256 _minOutputToken0, uint256 _minOutput)
        external override onlyBank {
        _withdraw(_pid, _account, _rate);

        // PoolInfo storage pool = poolInfo[_pid];
        uint256 outValue;
        (address token0, address token1) = (poolInfo[_pid].collateralToken[0], poolInfo[_pid].collateralToken[1]);
        if(_toToken == address(0)) {
            uint256 outValue0 = _safeTransferAll(token0, _account);
            require(outValue0 >= _minOutputToken0, 'insufficient Token output first');
            outValue = _safeTransferAll(token1, _account);
        } else if(token0 == _toToken) {
            _swapTokenAllTo(token1, _toToken);
            outValue = _safeTransferAll(_toToken, _account);
        } else if(token1 == _toToken) {
            _swapTokenAllTo(token0, _toToken);
            outValue = _safeTransferAll(_toToken, _account);
        } else {
            require(false, 'toToken unknown');
        }
        require(outValue >= _minOutput, 'insufficient Token output');
    }

    function withdrawLPToken(uint256 _pid, address _account, uint256 _rate, uint256 _unused, uint256 _minOutput)
        external override onlyBank {
        _withdraw(_pid, _account, _rate);

        PoolInfo storage pool = poolInfo[_pid];
        _safeTransferAll(pool.collateralToken[0], address(swapPoolImpl));
        _safeTransferAll(pool.collateralToken[1], address(swapPoolImpl));
        swapPoolImpl.deposit(pool.poolId, false);
        uint256 lpAmount = _safeTransferAll(pool.lpToken, _account);
        require(lpAmount >= _minOutput, 'insufficient LPToken output');
    }

    function _withdraw(uint256 _pid, address _account, uint256 _rate) internal {

        require(tx.origin == _account, 'not contract');

        // update rewards
        _updatePool(_pid);

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo2[_pid][_account];

        address token0 = pool.collateralToken[0];
        address token1 = pool.collateralToken[1];

        // withdraw and remove liquidity
        (uint256 removedLPAmount, uint256 removedPoint) = calcRemoveLiquidity(_pid, _account, _rate);

        if(removedLPAmount > 0) swapPoolImpl.withdraw(pool.poolId, removedLPAmount, true);

        {
            (address gather, uint256 feeAmount0, uint256 feeAmount1) = calcWithdrawFee(_pid, _account, _rate);
            if(feeAmount0 > 0) IERC20(token0).safeTransfer(gather, feeAmount0);
            if(feeAmount1 > 0) IERC20(token1).safeTransfer(gather, feeAmount1); 
        }

        repayBorrow(_pid, _account, _rate, true);

        uint256 withdrawLPTokenAmount = removedPoint.mul(pool.totalLPReinvest).div(pool.totalPoints);
        withdrawLPTokenAmount = TenMath.min(withdrawLPTokenAmount, pool.totalLPReinvest);

        // booking
        uint256 lpPointsOld = user.lpPoints;
        user.lpPoints = TenMath.safeSub(user.lpPoints, removedPoint);
        pool.totalPoints = TenMath.safeSub(pool.totalPoints, removedPoint);
        pool.totalLPReinvest = TenMath.safeSub(pool.totalLPReinvest, withdrawLPTokenAmount);

        user.lpAmount = TenMath.safeSub(user.lpAmount, removedLPAmount);
        pool.totalLPAmount = TenMath.safeSub(pool.totalLPAmount, removedLPAmount);

        emit StrategyWithdraw(_this, _pid, _account, withdrawLPTokenAmount);

        if(address(compActionPool) != address(0) && removedPoint > 0) {
            compActionPool.onAcionOut(_pid, _account, lpPointsOld, user.lpPoints);
        }
    }

    function _makeBorrow(uint256 _pid, address _account, address _debtFrom, uint256 _bAmount)
        internal {
        (uint256 bindex, uint256 amount) = calcBorrowAmount(_pid, _account, _debtFrom, _bAmount);
        
        if(amount > 0) {
            UserInfo storage user = userInfo2[_pid][_account];
            require(user.borrowFrom[bindex] == address(0) || user.borrowFrom[bindex] == _debtFrom, 'borrow token error');
            uint256 newbid = ITenBankHall(_bank).makeBorrowFrom(_pid, _account, _debtFrom, amount);
            require(newbid != 0, 'borrow new id');
            if(user.borrowFrom[bindex] == _debtFrom) {
                require(user.bids[bindex] == newbid, 'borrow newbid error');
            } else {
                require(user.borrowFrom[bindex] == address(0) && user.bids[bindex] == 0, 'borrow cannot change');
                user.borrowFrom[bindex] = _debtFrom;
                user.bids[bindex] = newbid;
            }
            emit StrategyBorrow2(_this, _pid, _account, _debtFrom, amount);
        }
    }

    function repayBorrow(uint256 _pid, address _account, uint256 _rate, bool _force) public override {
        UserInfo storage user = userInfo2[_pid][_account];
        if(user.borrowFrom[0] != address(0) || user.borrowFrom[1] != address(0)) {
            // _force as true, must repay all lending
            checkOraclePrice(_pid, _force ? false : true);
        }
        _repayBorrow(_pid, _account, _rate, 0, _force);
        _repayBorrow(_pid, _account, _rate, 1, _force);
    }

    function _repayBorrow(uint256 _pid, address _account, uint256 _rate, uint256 _index, bool _force) internal {
        UserInfo storage user = userInfo2[_pid][_account];
        PoolInfo storage pool = poolInfo[_pid];

        address borrowFrom = user.borrowFrom[_index];
        uint256 bid = user.bids[_index];

        if(borrowFrom != address(0)) {
            ISafeBox(borrowFrom).update();
        }

        (address btoken, uint256 bAmount, bool swap, uint256 swapAmount) = 
                calcWithdrawRepayBorrow(_pid, _account, _rate, _index);

        if(swapAmount > 0) {
            (address fromToken, address toToken) = swap ? 
                (pool.collateralToken[1], pool.collateralToken[0]) :
                (pool.collateralToken[0], pool.collateralToken[1]);
            IERC20(fromToken).safeTransfer(address(swapPoolImpl), swapAmount);
            swapPoolImpl.swapTokenTo(fromToken, swapAmount, toToken, _this);
        }

        if(bAmount > 0){
            bAmount = TenMath.min(bAmount, IERC20(btoken).balanceOf(_this));
            IERC20(btoken).safeTransfer(borrowFrom, bAmount);
            ISafeBox(borrowFrom).repay(user.bids[_index], bAmount);
            emit StrategyRepayBorrow2(_this, _pid, _account, borrowFrom, bAmount);
        }

        if(_rate == 1e9 && _force && borrowFrom != address(0)) {
            uint256 value = ISafeBox(borrowFrom).pendingBorrowAmount(bid);
            value = value.add(ISafeBox(borrowFrom).pendingBorrowRewards(bid));

            require(value == 0, 'repayBorrow not clear');
            user.borrowFrom[_index] = address(0);
            user.bids[_index] = 0;
        }
    }

    function emergencyWithdraw(uint256 _pid, address _account, uint256 _minOutput0, uint256 _minOutput1)
        external override onlyBank {

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo2[_pid][_account];

        // total of deposit and reinvest
        uint256 withdrawLPTokenAmount = pendingLPAmount(_pid, _account);

        // booking
        poolInfo[_pid].totalLPReinvest = TenMath.safeSub(poolInfo[_pid].totalLPReinvest, withdrawLPTokenAmount);
        poolInfo[_pid].totalPoints = TenMath.safeSub(poolInfo[_pid].totalPoints, user.lpPoints);
        poolInfo[_pid].totalLPAmount = TenMath.safeSub(poolInfo[_pid].totalLPAmount, user.lpAmount);
        
        user.lpPoints = 0;
        user.lpAmount = 0;

        address token0 = pool.collateralToken[0];
        address token1 = pool.collateralToken[1];

        swapPoolImpl.withdraw(pool.poolId, withdrawLPTokenAmount, true);

        repayBorrow(_pid, _account, 1e9, true);

        require(_safeTransferAll(token0, _account) >= _minOutput0, 'insufficient output 0');
        require(_safeTransferAll(token1, _account) >= _minOutput1, 'insufficient output 1');
    }

    function liquidation(uint256 _pid, address _account, address _hunter, uint256 _maxDebt)
        external override onlyBank {
        
        _maxDebt;

        UserInfo storage user = userInfo2[_pid][_account];
        PoolInfo storage pool = poolInfo[_pid];

        // update rewards
        _updatePool(_pid);

        // check liquidation limit
        checkLiquidationLimit(_pid, _account, true);

        uint256 lpPointsOld = user.lpPoints;
        uint256 withdrawLPTokenAmount = pendingLPAmount(_pid, _account);
        // booking
        pool.totalLPAmount = TenMath.safeSub(pool.totalLPAmount, user.lpAmount);
        pool.totalLPReinvest = TenMath.safeSub(pool.totalLPReinvest, withdrawLPTokenAmount);
        pool.totalPoints = TenMath.safeSub(pool.totalPoints, user.lpPoints);
        
        user.lpPoints = 0;
        user.lpAmount = 0;

        if(withdrawLPTokenAmount > 0) {
            swapPoolImpl.withdraw(pool.poolId, withdrawLPTokenAmount, true);
        }

        // repay borrow
        repayBorrow(_pid, _account, 1e9, false);

        // swap all token to basetoken
        {
            address tokensell = pool.baseToken == pool.collateralToken[0] ? 
                                pool.collateralToken[1] : pool.collateralToken[0];
            _swapTokenAllTo(tokensell, pool.baseToken);
        }

        // liquidation fee
        {
            (address gather, uint256 feeAmount) = calcLiquidationFee(_pid, _account);
            if(feeAmount > 0) IERC20(pool.baseToken).safeTransfer(gather, feeAmount);
        }

        // send rewards to hunter
        uint256 hunterAmount = _safeTransferAll(pool.baseToken, _hunter);

        emit StrategyLiquidation2(_this, _pid, _account, withdrawLPTokenAmount, hunterAmount);

        if(address(compActionPool) != address(0) && lpPointsOld > 0) {
            compActionPool.onAcionOut(_pid, _account, lpPointsOld, 0);
        }
    }
    
    function makeExtraRewards() external {
        if(address(buyback) == address(0)) {
            return ;
        }
        (address rewardsToken, uint256 value) = swapPoolImpl.extraRewards();
        if(rewardsToken == address(0) || value == 0) {
            return ;
        }
        uint256 fee = value.mul(3e6).div(1e9);
        IERC20(rewardsToken).transfer(msg.sender, fee);
        IERC20(rewardsToken).approve(address(buyback), value.sub(fee));
        buyback.buyback(rewardsToken, value.sub(fee));
    }

    function _safeTransferAll(address _token, address _to)
        internal returns (uint256 value){
        value = IERC20(_token).balanceOf(_this);
        if(value > 0) {
            IERC20(_token).safeTransfer(_to, value);
        }
    }

    function _swapTokenAllTo(address _token, address _toToken)
        internal returns (uint256 value){
        uint256 amount = _safeTransferAll(_token, address(swapPoolImpl));
        if(amount > 0) {
            swapPoolImpl.swapTokenTo(_token, amount, _toToken, _this);
        }
    }

    function _delegateTo(address callee, bytes memory data) internal returns (bytes memory) {
        (bool success, bytes memory returnData) = callee.delegatecall(data);
        assembly {
            if eq(success, 0) {
                revert(add(returnData, 0x20), returndatasize())
            }
        }
        return returnData;
    }

    function delegateToImplementation(bytes memory data) public returns (bytes memory) {
        require(msg.sender == _this, 'only _this');
        return _delegateTo(helperImpl, data);
    }

    function delegateToViewImplementation(bytes memory data) public view returns (bytes memory) {
        (bool success, bytes memory returnData) = _this.staticcall(abi.encodeWithSignature("delegateToImplementation(bytes)", data));
        assembly {
            if eq(success, 0) {
                revert(add(returnData, 0x20), returndatasize())
            }
        }
        return abi.decode(returnData, (bytes));
    }
}