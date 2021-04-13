// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import '../interfaces/ISafeBox.sol';
import '../interfaces/ICompActionTrigger.sol';
import '../interfaces/IActionPools.sol';
import '../interfaces/IBuyback.sol';
import "../utils/TenMath.sol";

import "./SafeBoxCTokenImplETH.sol";

contract SafeBoxCTokenETH is SafeBoxCTokenImplETH, ReentrancyGuard, Ownable, ICompActionTrigger, ISafeBox {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct BorrowInfo {
        address strategy;      // borrow from strategy
        uint256 pid;           // borrow to pool
        address owner;         // borrower
        uint256 amount;        // borrow amount
        uint256 bPoints;       // borrow proportion
    }

    // supply manager
    uint256 public accDebtPerSupply;    // platform debt is shared to each supply lptoken

    // borrow manager
    BorrowInfo[] public borrowInfo;     // borrow order info
    mapping(address => mapping(address => mapping(uint256 => uint256))) public borrowIndex;   // _account, _strategy, _pid,  mapping id of borrowinfo, base from 1
    mapping(address => uint256) public  accountBorrowPoints;   // _account,  amount
    uint256 public lastBorrowCurrent;   // last settlement for 

    uint256 public borrowTotalPoints;          // total of user bPoints
    uint256 public borrowTotalAmountWithPlatform;  // total of user borrows and interests and platform
    uint256 public borrowTotalAmount;          // total of user borrows and interests
    uint256 public borrowTotal;                // total of user borrows

    uint256 public borrowLimitRate = 7e8;    // borrow limit,  max = borrowTotal * borrowLimitRate / 1e9, default=80%
    uint256 public borrowMinAmount;          // borrow min amount limit

    mapping(address => bool) public blacklist;  // deposit blacklist
    bool public depositEnabled = true;
    bool public emergencyRepayEnabled;
    bool public emergencyWithdrawEnabled;

    address public override bank;       // borrow can from bank only 
    address public override token;      // deposit and borrow token

    address public compActionPool;          // action pool for borrow rewards
    uint256 public constant CTOKEN_BORROW = 1;  // action pool borrow action id

    uint256 public optimalUtilizationRate1 = 6e8;  // Lending rate, ideal 1e9, default = 60%
    uint256 public optimalUtilizationRate2 = 7.5e8;  // Lending rate, ideal 1e9, default = 75%
    uint256 public stableRateSlope1 = 2e9;         // loan interest times in max borrow rate
    uint256 public stableRateSlope2 = 20e9;         // loan interest times in max borrow rate

    address public iBuyback;

    event SafeBoxDeposit(address indexed user, uint256 amount);
    event SafeBoxWithdraw(address indexed user, uint256 amount);
    event SafeBoxClaim(address indexed user, uint256 amount);

    event SetBlacklist(address indexed _account, bool _newset);
    event SetBuyback(address indexed buyback);
    event SetBorrowLimitRate(uint256 oldRate, uint256 newRate);
    event SetOptimalUtilizationRate(uint256 oldV1, uint256 oldV2, uint256 newV1, uint256 newV2);
    event SetStableRateSlope(uint256 oldV1, uint256 oldV2, uint256 newV1, uint256 newV2);

    constructor (
        address _bank,
        address _cToken
    ) public SafeBoxCTokenImplETH(_cToken) {
        token = baseToken();
        require(IERC20(token).totalSupply() >= 0, 'token error');
        bank = _bank;
        // 0 id  Occupied,  Available bid never be zero
        borrowInfo.push(BorrowInfo(address(0), 0, address(0), 0, 0));
    }

    modifier onlyBank() {
        require(bank == msg.sender, 'borrow only from bank');
        _;
    }

    // link to actionpool , for borrower s allowance
    function getCATPoolInfo(uint256 _pid) external virtual override view 
        returns (address lpToken, uint256 allocRate, uint256 totalPoints, uint256 totalAmount) {
            _pid;
            lpToken = token;
            allocRate = 5e8; // never use
            totalPoints = borrowTotalPoints;
            totalAmount = borrowTotalAmountWithPlatform;
    }

    function getCATUserAmount(uint256 _pid, address _account) external virtual override view 
        returns (uint256 acctPoints) {
            _pid;
            acctPoints = accountBorrowPoints[_account];
    }

    function getSource() external virtual override view returns (string memory) {
        return 'filda';
    }

    // blacklist
    function setBlacklist(address _account, bool _newset) external onlyOwner {
        blacklist[_account] = _newset;
        emit SetBlacklist(_account, _newset);
    }

    function setCompAcionPool(address _compActionPool) public onlyOwner {
        compActionPool = _compActionPool;
    }

    function setBuyback(address _iBuyback) public onlyOwner {
        iBuyback = _iBuyback;
        emit SetBuyback(_iBuyback);
    }

    function setBorrowLimitRate(uint256 _borrowLimitRate) external onlyOwner {
        require(_borrowLimitRate <= 1e9, 'rate too high');
        emit SetBorrowLimitRate(borrowLimitRate, _borrowLimitRate);
        borrowLimitRate = _borrowLimitRate;
    }

    function setBorrowMinAmount(uint256 _borrowMinAmount) external onlyOwner {
        borrowMinAmount = _borrowMinAmount;
    }

    function setEmergencyRepay(bool _emergencyRepayEnabled) external onlyOwner {
        emergencyRepayEnabled = _emergencyRepayEnabled;
    }

    function setEmergencyWithdraw(bool _emergencyWithdrawEnabled) external onlyOwner {
        emergencyWithdrawEnabled = _emergencyWithdrawEnabled;
    }
    
    // for platform borrow interest rate
    function setOptimalUtilizationRate(uint256 _optimalUtilizationRate1, uint256 _optimalUtilizationRate2) external onlyOwner {
        require(_optimalUtilizationRate1 <= 1e9 && 
                _optimalUtilizationRate2 <= 1e9 && 
                _optimalUtilizationRate1 < _optimalUtilizationRate2
                , 'rate set error');
        emit SetOptimalUtilizationRate(optimalUtilizationRate1, optimalUtilizationRate2, _optimalUtilizationRate1, _optimalUtilizationRate2);
        optimalUtilizationRate1 = _optimalUtilizationRate1;
        optimalUtilizationRate2 = _optimalUtilizationRate2;
    }

    function setStableRateSlope(uint256 _stableRateSlope1, uint256 _stableRateSlope2) external onlyOwner {
        require(_stableRateSlope1 <= 1e4*1e9 && _stableRateSlope1 >= 1e9 &&
                 _stableRateSlope2 <= 1e4*1e9 && _stableRateSlope2 >= 1e9 , 'rate set error');
        emit SetStableRateSlope(stableRateSlope1, stableRateSlope2, _stableRateSlope1, _stableRateSlope2);
        stableRateSlope1 = _stableRateSlope1;
        stableRateSlope2 = _stableRateSlope2;
    }

    function supplyRatePerBlock() external override view returns (uint256) {
        return ctokenSupplyRatePerBlock();
    }

    function borrowRatePerBlock() external override view returns (uint256) {
        return ctokenBorrowRatePerBlock().mul(getBorrowFactorPrewiew()).div(1e9);
    }

    function borrowInfoLength() external override view returns (uint256) {
        return borrowInfo.length.sub(1);
    }

    function getBorrowInfo(uint256 _bid) external override view 
        returns (address owner, uint256 amount, address strategy, uint256 pid) {

        strategy = borrowInfo[_bid].strategy;
        pid = borrowInfo[_bid].pid;
        owner = borrowInfo[_bid].owner;
        amount = borrowInfo[_bid].amount;
    }

    function getBorrowFactorPrewiew() public virtual view returns (uint256) {
        return _getBorrowFactor(getDepositTotal());
    }

    function getBorrowFactor() public virtual returns (uint256) {
        return _getBorrowFactor(call_balanceOfBaseToken_this());
    }

    function _getBorrowFactor(uint256 supplyAmount) internal virtual view returns (uint256 value) {
        if(supplyAmount <= 0) {
            return uint256(1e9);
        }
        uint256 borrowRate = getBorrowTotal().mul(1e9).div(supplyAmount);
        if(borrowRate <= optimalUtilizationRate1) {
            return uint256(1e9);
        }
        uint256 value1 = stableRateSlope1.sub(1e9).mul(borrowRate.sub(optimalUtilizationRate1))
                    .div(uint256(1e9).sub(optimalUtilizationRate1))
                    .add(uint256(1e9));
        if(borrowRate <= optimalUtilizationRate2) {
            value = value1;
            return value;
        }
        uint256 value2 = stableRateSlope2.sub(1e9).mul(borrowRate.sub(optimalUtilizationRate2))
                    .div(uint256(1e9).sub(optimalUtilizationRate2))
                    .add(uint256(1e9));
        value = value2 > value1 ? value2 : value1;
    }

    function getBorrowTotal() public virtual override view returns (uint256) {
        return borrowTotalAmountWithPlatform;
    }

    function getDepositTotal() public virtual override view returns (uint256) {
        return totalSupply().mul(getBaseTokenPerLPToken()).div(1e18);
    }

    function getBaseTokenPerLPToken() public virtual override view returns (uint256) {
        return getBaseTokenPerCToken();
    }

    function pendingSupplyAmount(address _account) external virtual override view returns (uint256 value) {
        value = call_balanceOf(address(this), _account).mul(getBaseTokenPerLPToken()).div(1e18);
    }

    function pendingBorrowAmount(uint256 _bid) public virtual override view returns (uint256 value) {
        value = borrowInfo[_bid].amount;
    }

    // borrow interest, the sum of filda interest and platform interest
    function pendingBorrowRewards(uint256 _bid) public virtual override view returns (uint256 value) {
        if(borrowTotalPoints <= 0) {
            return 0;
        }
        value = borrowInfo[_bid].bPoints.mul(borrowTotalAmountWithPlatform).div(borrowTotalPoints);
        value = TenMath.safeSub(value, borrowInfo[_bid].amount);
    }

    // deposit
    function deposit(uint256 _value) external virtual override nonReentrant {
        update();
        IERC20(token).safeTransferFrom(msg.sender, address(this), _value);
        _deposit(msg.sender, _value);
    }

    function _deposit(address _account, uint256 _value) internal returns (uint256) {
        require(depositEnabled, 'safebox closed');
        require(!blacklist[_account], 'address in blacklist');
        // token held in contract
        uint256 balanceInput = call_balanceOf(token, address(this));
        require(balanceInput > 0 &&  balanceInput >= _value, 'where s token?');

        // update booking, mintValue is number of deposit credentials
        uint256 mintValue = ctokenDeposit(_value);
        if(mintValue > 0) {
            _mint(_account, mintValue);
        }
        emit SafeBoxDeposit(_account, mintValue);
        return mintValue;
    }

    function withdraw(uint256 _tTokenAmount) external virtual override nonReentrant {
        update();
        _withdraw(msg.sender, _tTokenAmount);
    }

    function _withdraw(address _account, uint256 _tTokenAmount) internal returns (uint256) {
        // withdraw if lptokens value is not up borrowLimitRate
        if(_tTokenAmount > balanceOf(_account)) {
            _tTokenAmount = balanceOf(_account);
        }
        uint256 maxBorrowAmount = call_balanceOfCToken_this().sub(_tTokenAmount)
                                    .mul(getBaseTokenPerLPToken()).div(1e18)
                                    .mul(borrowLimitRate).div(1e9);
        require(maxBorrowAmount >= borrowTotalAmountWithPlatform, 'no money to withdraw');

        _burn(_account, uint256(_tTokenAmount));

        if(accDebtPerSupply > 0) {
            // If platform loss, the loss will be shared by supply
            uint256 debtAmount = _tTokenAmount.mul(accDebtPerSupply).div(1e18);
            require(_tTokenAmount >= debtAmount, 'debt too much');
            _tTokenAmount = _tTokenAmount.sub(debtAmount);
        }

        ctokenWithdraw(_tTokenAmount);
        tokenSafeTransfer(address(token), _account);
        emit SafeBoxWithdraw(_account, _tTokenAmount);
        return _tTokenAmount;
    }

    function claim(uint256 _value) external virtual override nonReentrant {
        update();
        _claim(msg.sender, uint256(_value));
    }

    function _claim(address _account, uint256 _value) internal {
        emit SafeBoxClaim(_account, _value);
    }

    function getBorrowId(address _strategy, uint256 _pid, address _account)
        public virtual override view returns (uint256 borrowId) {
        borrowId = borrowIndex[_account][_strategy][_pid];
    }

    function getBorrowId(address _strategy, uint256 _pid, address _account, bool _add) 
        external virtual override onlyBank returns (uint256 borrowId) {

        require(_strategy != address(0), 'borrowid _strategy error');
        require(_account != address(0), 'borrowid _account error');
        borrowId = getBorrowId(_strategy, _pid, _account);
        if(borrowId == 0 && _add) {
            borrowInfo.push(BorrowInfo(_strategy, _pid, _account, 0, 0));
            borrowId = borrowInfo.length.sub(1);
            borrowIndex[_account][_strategy][_pid] = borrowId;
        }
        require(borrowId > 0, 'not found borrowId');
    }

    function borrow(uint256 _bid, uint256 _value, address _to) external virtual override onlyBank {
        update();
        _borrow(_bid, _value, _to);
    }

    function _borrow(uint256 _bid, uint256 _value, address _to) internal {
        // withdraw if lptokens value is not up borrowLimitRate
        uint256 maxBorrowAmount = call_balanceOfCToken_this()
                                    .mul(getBaseTokenPerLPToken()).div(1e18)
                                    .mul(borrowLimitRate).div(1e9);
        require(maxBorrowAmount >= borrowTotalAmountWithPlatform.add(_value), 'no money to borrow');
        require(_value >= borrowMinAmount, 'borrow amount too low');

        BorrowInfo storage borrowCurrent = borrowInfo[_bid];

        // borrow
        uint256 ubalance = ctokenBorrow(_value);
        require(ubalance == _value, 'token borrow error');

        tokenSafeTransfer(address(token), _to);

        // booking
        uint256 addPoint = _value;
        if(borrowTotalPoints > 0) {
            addPoint = _value.mul(borrowTotalPoints).div(borrowTotalAmountWithPlatform);
        }

        borrowCurrent.bPoints = borrowCurrent.bPoints.add(addPoint);
        borrowTotalPoints = borrowTotalPoints.add(addPoint);
        borrowTotalAmountWithPlatform = borrowTotalAmountWithPlatform.add(_value);
        lastBorrowCurrent = call_borrowBalanceCurrent_this();

        borrowCurrent.amount = borrowCurrent.amount.add(_value);
        borrowTotal = borrowTotal.add(_value);
        borrowTotalAmount = borrowTotalAmount.add(_value);
        
        // notify for action pool
        uint256 accountBorrowPointsOld = accountBorrowPoints[borrowCurrent.owner];
        accountBorrowPoints[borrowCurrent.owner] = accountBorrowPoints[borrowCurrent.owner].add(addPoint);

        if(compActionPool != address(0) && addPoint > 0) {
            IActionPools(compActionPool).onAcionIn(CTOKEN_BORROW, borrowCurrent.owner,
                    accountBorrowPointsOld, accountBorrowPoints[borrowCurrent.owner]);
        }
        return ;
    }

    function repay(uint256 _bid, uint256 _value) external virtual override {
        update();
        _repay(_bid, _value);
    }

    function _repay(uint256 _bid, uint256 _value) internal {
        BorrowInfo storage borrowCurrent = borrowInfo[_bid];

        uint256 removedPoints;
        if(_value >= pendingBorrowRewards(_bid).add(borrowCurrent.amount)) {
            removedPoints = borrowCurrent.bPoints;
        }else{
            removedPoints = _value.mul(borrowTotalPoints).div(borrowTotalAmountWithPlatform);
            removedPoints = TenMath.min(removedPoints, borrowCurrent.bPoints);
        }

        // booking
        uint256 userAmount = removedPoints.mul(borrowCurrent.amount).div(borrowCurrent.bPoints); // to reduce amount for booking
        uint256 repayAmount = removedPoints.mul(borrowTotalAmount).div(borrowTotalPoints); // to repay = amount + interest
        uint256 platformAmount = TenMath.safeSub(removedPoints.mul(borrowTotalAmountWithPlatform).div(borrowTotalPoints),
                                 repayAmount);  // platform interest
    
        borrowCurrent.bPoints = TenMath.safeSub(borrowCurrent.bPoints, removedPoints);
        borrowTotalPoints = TenMath.safeSub(borrowTotalPoints, removedPoints);
        borrowTotalAmountWithPlatform = TenMath.safeSub(borrowTotalAmountWithPlatform, repayAmount.add(platformAmount));
        lastBorrowCurrent = call_borrowBalanceCurrent_this();

        borrowCurrent.amount = TenMath.safeSub(borrowCurrent.amount, userAmount);
        borrowTotal = TenMath.safeSub(borrowTotal, userAmount);
        borrowTotalAmount = TenMath.safeSub(borrowTotalAmount, repayAmount);
        
        // platform interest will buyback
        if(platformAmount > 0 && iBuyback != address(0)) {
            IERC20(token).approve(iBuyback, platformAmount);
            IBuyback(iBuyback).buyback(token, platformAmount);
        }

        // repay borrow
        repayAmount = TenMath.min(repayAmount, lastBorrowCurrent);

        ctokenRepayBorrow(repayAmount);
        lastBorrowCurrent = call_borrowBalanceCurrent_this();

        // return of the rest
        tokenSafeTransfer(token, msg.sender);

        // notify for action pool
        uint256 accountBorrowPointsOld = accountBorrowPoints[borrowCurrent.owner];
        accountBorrowPoints[borrowCurrent.owner] = TenMath.safeSub(accountBorrowPoints[borrowCurrent.owner], removedPoints);

        if(compActionPool != address(0) && removedPoints > 0) {
            IActionPools(compActionPool).onAcionOut(CTOKEN_BORROW, borrowCurrent.owner,
                    accountBorrowPointsOld, accountBorrowPoints[borrowCurrent.owner]);
        }
        return ;
    }

    function emergencyWithdraw() external virtual override nonReentrant {
        require(emergencyWithdrawEnabled, 'not in emergency');

        uint256 withdrawAmount = call_balanceOf(address(this), msg.sender);
        _burn(msg.sender, withdrawAmount);

        if(accDebtPerSupply > 0) {
            // If platform loss, the loss will be shared by supply
            uint256 debtAmount = withdrawAmount.mul(accDebtPerSupply).div(1e18);
            require(withdrawAmount >= debtAmount, 'debt too much');
            withdrawAmount = withdrawAmount.sub(debtAmount);
        }

        // withdraw ctoken
        ctokenWithdraw(withdrawAmount);

        tokenSafeTransfer(address(token), msg.sender);
    }

    function emergencyRepay(uint256 _bid) external virtual override nonReentrant {
        require(emergencyRepayEnabled, 'not in emergency');
        // in emergency mode , only repay loan
        BorrowInfo storage borrowCurrent = borrowInfo[_bid];

        uint256 repayAmount = borrowCurrent.amount;

        IERC20(baseToken()).safeTransferFrom(msg.sender, address(this), repayAmount);
        ctokenRepayBorrow(repayAmount);

        uint256 accountBorrowPointsOld = accountBorrowPoints[borrowCurrent.owner];
        accountBorrowPoints[borrowCurrent.owner] = TenMath.safeSub(accountBorrowPoints[borrowCurrent.owner], borrowCurrent.bPoints);

        // booking
        borrowTotal = TenMath.safeSub(borrowTotal, repayAmount);
        borrowTotalPoints = TenMath.safeSub(borrowTotalPoints, borrowCurrent.bPoints);
        borrowTotalAmount = TenMath.safeSub(borrowTotalAmount, repayAmount);
        borrowTotalAmountWithPlatform = TenMath.safeSub(borrowTotalAmountWithPlatform, repayAmount);
        borrowCurrent.amount = 0;
        borrowCurrent.bPoints = 0;
        lastBorrowCurrent = call_borrowBalanceCurrent_this();
    }

    function update() public virtual override {
        _update();
    }

    function _update() internal {
        // update borrow interest
        uint256 lastBorrowCurrentNow = call_borrowBalanceCurrent_this();
        if(lastBorrowCurrentNow != lastBorrowCurrent && borrowTotal > 0) {
            if(lastBorrowCurrentNow >= lastBorrowCurrent) {
                // booking
                uint256 newDebtAmount1 = lastBorrowCurrentNow.sub(lastBorrowCurrent);
                uint256 newDebtAmount2 = newDebtAmount1.mul(getBorrowFactor()).div(1e9);
                borrowTotalAmount = borrowTotalAmount.add(newDebtAmount1);
                borrowTotalAmountWithPlatform = borrowTotalAmountWithPlatform.add(newDebtAmount2);
            }
            lastBorrowCurrent = lastBorrowCurrentNow;
        }

        // manage ctoken amount
        uint256 uCTokenTotalAmount = call_balanceOfCToken_this();
        if(uCTokenTotalAmount >= totalSupply()) {
            // The platform has no debt
            accDebtPerSupply = 0;
        }
        if(totalSupply() > 0 && accDebtPerSupply > 0) {
            // The platform has debt, uCTokenTotalAmount will be totalSupply()
            uCTokenTotalAmount = uCTokenTotalAmount.add(accDebtPerSupply.mul(totalSupply()).div(1e18));
        }
        if(uCTokenTotalAmount < totalSupply()) {
            // totalSupply() != 0  new debt divided equally
            accDebtPerSupply = accDebtPerSupply.add(totalSupply().sub(uCTokenTotalAmount).mul(1e18).div(totalSupply()));
        } else if(uCTokenTotalAmount > totalSupply() && accDebtPerSupply > 0) {
            // reduce debt divided equally
            uint256 accDebtReduce = uCTokenTotalAmount.sub(totalSupply()).mul(1e18).div(totalSupply());
            accDebtReduce = TenMath.min(accDebtReduce, accDebtPerSupply);
            accDebtPerSupply = accDebtPerSupply.sub(accDebtReduce);
        }

        if(compActionPool != address(0)) {
            IActionPools(compActionPool).onAcionUpdate(CTOKEN_BORROW);
        }
    }

    function mintDonate(uint256 _value) public virtual override nonReentrant {
        IERC20(token).safeTransferFrom(msg.sender, address(this), _value);
        ctokenDeposit(_value);
        update();
    }

    function tokenSafeTransfer(address _token, address _to) internal {
        uint256 value = IERC20(_token).balanceOf(address(this));
        if(value > 0) {
            IERC20(_token).transfer(_to, value);
        }
    }
}
