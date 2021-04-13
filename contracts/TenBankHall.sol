// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import './interfaces/IStrategyLink.sol';
import './interfaces/ITenBankHall.sol';
import './interfaces/ISafeBox.sol';
import './interfaces/IClaimFromBank.sol';

// TenBank bank
contract TenBankHall is Ownable, ITenBankHall, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    struct StrategyInfo {
        bool isListed;          // if enabled, it will access
        IStrategyLink iLink;    // strategy interface
        uint256 pid;            // strategy poolid, multiple strategys pools
    }

    // safebox manager
    ISafeBox[] public boxInfo;
    mapping(address => uint256) public boxIndex;
    mapping(uint256 => bool) public boxlisted;

    // strategyinfo manager
    StrategyInfo[] public strategyInfo;
    mapping(address => mapping(uint256 => uint256)) public strategyIndex; // strategy + pid => strategyInfo index

    // actionpools claim
    IClaimFromBank[] public poolClaim;

    // blacklist
    mapping(address => bool) public blacklist;
    mapping(uint256 => bool) public emergencyEnabled;

    event AddBox(uint256 indexed _boxid, address _safebox);
    event AddStrategy(uint256 indexed _sid, address indexed _strategylink, uint256 indexed _pid, bool _blisted);
    event SetBlacklist(address indexed _account, bool _newset);
    event SetEmergencyEnabled(uint256 indexed _sid, bool _newset);
    event SetBoxListed(uint256 indexed _boxid, bool _listed);

    constructor() public {
    }

    // blacklist manager
    function setBlacklist(address _account, bool _newset) external onlyOwner {
        blacklist[_account] = _newset;
        if(_newset) {
            require(isContract(_account), 'contract address only');
        }
        emit SetBlacklist(_account, _newset);
    }

    function isContract(address addr) internal returns (bool) {
        uint size;
        assembly { size := extcodesize(addr) }
        return size > 0;
    }
    
    function setEmergencyEnabled(uint256 _sid, bool _newset) external onlyOwner {
        emergencyEnabled[_sid] = _newset;
        emit SetEmergencyEnabled(_sid, _newset);
    }

    function claimLength() external view returns (uint256) {
        return poolClaim.length;
    }
    
    function addClaimPool(address _poolClaim) external onlyOwner {
        poolClaim.push(IClaimFromBank(_poolClaim));
    }

    // box manager
    function boxesLength() external view returns (uint256) {
        return boxInfo.length;
    }

    function addBox(address _safebox) external onlyOwner {
        require(boxIndex[_safebox] == 0, 'add once only');
        boxInfo.push(ISafeBox(_safebox));
        uint256 boxid = boxInfo.length.sub(1);
        boxlisted[boxid] = true;
        boxIndex[_safebox] = boxid;
        emit AddBox(boxid, _safebox);
        require(ISafeBox(_safebox).bank() == address(this), 'bank not me?');
    }

    function setBoxListed(uint256 _boxid, bool _listed) external onlyOwner {
        boxlisted[_boxid] = _listed;
        emit SetBoxListed(_boxid, _listed);
    }

    // Strategy manager
    function strategyInfoLength() external view returns (uint256 length) {
        length = strategyInfo.length;
    }

    function strategyIsListed(uint256 _sid) external view returns (bool) {
        return strategyInfo[_sid].isListed;
    }

    function setStrategyListed(uint256 _sid, bool _listed) external onlyOwner {
        strategyInfo[_sid].isListed = _listed;
    }

    function addStrategy(address _strategylink, uint256 _pid, bool _blisted) external onlyOwner {
        require(IStrategyLink(_strategylink).poolLength() > _pid, 'not strategy pid');
        strategyInfo.push(StrategyInfo(
            _blisted,
            IStrategyLink(_strategylink),
            _pid));
        strategyIndex[_strategylink][_pid] = strategyInfo.length.sub(1);
        emit AddStrategy(strategyIndex[_strategylink][_pid], _strategylink, _pid, _blisted);
        require(IStrategyLink(_strategylink).bank() == address(this), 'bank not me?');
    }

    function depositLPToken(uint256 _sid, uint256 _amount, uint256 _bid, uint256 _bAmount, uint256 _desirePrice, uint256 _slippage) 
            public nonReentrant returns (uint256 lpAmount) {
        require(strategyInfo[_sid].isListed, 'not listed');
        require(!blacklist[msg.sender], 'address in blacklist');

        address lpToken = strategyInfo[_sid].iLink.getPoollpToken(strategyInfo[_sid].pid);
        IERC20(lpToken).safeTransferFrom(msg.sender, address(strategyInfo[_sid].iLink), _amount);

        address boxitem = address(0);
        if(_bAmount > 0) {
            boxitem = address(boxInfo[_bid]);
        }
        return strategyInfo[_sid].iLink.depositLPToken(strategyInfo[_sid].pid, msg.sender, boxitem, _bAmount, _desirePrice, _slippage);
    }

    function deposit(uint256 _sid, uint256[] memory _amount, uint256 _bid, uint256 _bAmount, uint256 _desirePrice, uint256 _slippage)
            public nonReentrant returns (uint256 lpAmount) {
        require(strategyInfo[_sid].isListed, 'not listed');
        require(!blacklist[msg.sender], 'address in blacklist');

        address[] memory collateralToken = strategyInfo[_sid].iLink.getPoolCollateralToken(strategyInfo[_sid].pid);
        require(collateralToken.length == _amount.length, '_amount length error');

        for(uint256 u = 0; u < collateralToken.length; u ++) {
            if(_amount[u] > 0) {
                IERC20(collateralToken[u]).safeTransferFrom(msg.sender, address(strategyInfo[_sid].iLink), _amount[u]);
            }
        }

        address boxitem = address(0);
        if(_bAmount > 0) {
            boxitem = address(boxInfo[_bid]);
        }
        return strategyInfo[_sid].iLink.deposit(strategyInfo[_sid].pid, msg.sender, boxitem, _bAmount, _desirePrice, _slippage);
    }

    function withdrawLPToken(uint256 _sid, uint256 _rate, uint256 _desirePrice, uint256 _slippage) external nonReentrant {
        return strategyInfo[_sid].iLink.withdrawLPToken(strategyInfo[_sid].pid, msg.sender, _rate, _desirePrice, _slippage);
    }

    function withdraw(uint256 _sid, uint256 _rate, address _toToken, uint256 _desirePrice, uint256 _slippage) external nonReentrant {
        return strategyInfo[_sid].iLink.withdraw(strategyInfo[_sid].pid, msg.sender, _rate, _toToken, _desirePrice, _slippage);
    }

    function withdrawLPTokenAndClaim(uint256 _sid, uint256 _rate, 
                                    uint256 _desirePrice, uint256 _slippage, 
                                    uint256 _poolClaimId, uint256[] memory _pidlist) external nonReentrant {
        strategyInfo[_sid].iLink.withdrawLPToken(strategyInfo[_sid].pid, msg.sender, _rate, _desirePrice, _slippage);
        if(_pidlist.length > 0) {
            poolClaim[_poolClaimId].claimFromBank(msg.sender, _pidlist);
        }
    }

    function withdrawAndClaim(uint256 _sid, uint256 _rate, address _toToken, 
                                uint256 _desirePrice, uint256 _slippage,
                                uint256 _poolClaimId, uint256[] memory _pidlist) external nonReentrant {
        strategyInfo[_sid].iLink.withdraw(strategyInfo[_sid].pid, msg.sender, _rate, _toToken, _desirePrice, _slippage);
        if(_pidlist.length > 0) {
            poolClaim[_poolClaimId].claimFromBank(msg.sender, _pidlist);
        }
    }

    function claim(uint256 _poolClaimId, uint256[] memory _pidlist) external nonReentrant {
        poolClaim[_poolClaimId].claimFromBank(msg.sender, _pidlist);
    }

    function emergencyWithdraw(uint256 _sid, uint256 _desirePrice, uint256 _slippage) external nonReentrant {
        require(emergencyEnabled[_sid], 'emergency not enabled');
        return strategyInfo[_sid].iLink.emergencyWithdraw(strategyInfo[_sid].pid, msg.sender, _desirePrice, _slippage);
    }

    function liquidation(uint256 _sid, address _account, uint256 _maxDebt) external nonReentrant {
        uint256 pid = strategyInfo[_sid].pid;
        if(_maxDebt > 0) {
            (address borrowFrom,) = IStrategyLink(strategyInfo[_sid].iLink).getBorrowInfo(pid, _account);
            address borrowToken = ISafeBox(borrowFrom).token();
            IERC20(borrowToken).safeTransferFrom(msg.sender, address(strategyInfo[_sid].iLink), _maxDebt);
        }
        strategyInfo[_sid].iLink.liquidation(pid, _account, msg.sender, _maxDebt);
    }

    function getBorrowAmount(uint256 _sid, address _account) external view returns (uint256 value) {
        value = strategyInfo[_sid].iLink.getBorrowAmount(strategyInfo[_sid].pid, _account);
    }

    function getDepositAmount(uint256 _sid, address _account) external view returns (uint256 value) {
        value = strategyInfo[_sid].iLink.getDepositAmount(strategyInfo[_sid].pid, _account);
    }

    function makeBorrowFrom(uint256 _pid, address _account, address _borrowFrom, uint256 _value) 
        external override returns (uint256 bid) {
        // borrow from bank will check contract authority
        uint256 sid = strategyIndex[msg.sender][_pid];
        require(address(strategyInfo[sid].iLink) == msg.sender, 'only call from strategy');
        bid = ISafeBox(_borrowFrom).getBorrowId(msg.sender, _pid, _account, true);
        require(bid > 0, 'bid go run');
        ISafeBox(_borrowFrom).borrow(bid, _value, msg.sender);
    }

    receive() external payable {
        revert();
    }
}
