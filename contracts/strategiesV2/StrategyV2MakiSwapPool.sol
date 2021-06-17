// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

import "../../interfaces/uniswapv2/IUniswapV2Pair.sol";
import "../../interfaces/uniswapv2/IUniswapV2Factory.sol";
import "../../interfaces/uniswapv2/IUniswapV2Router02.sol";
import "../../interfaces/IMakiHecoPool.sol";

import "../interfaces/IStrategyV2SwapPool.sol";
import "../utils/TenMath.sol";

// Connecting to third party swap for pool lptoken
contract StrategyV2MakiSwapPool is IStrategyV2SwapPool {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IUniswapV2Factory public constant factory = IUniswapV2Factory(0x11cdC9Bd86fF68b6A6152037342bAe0c3a717f56);
    IUniswapV2Router02 public constant router = IUniswapV2Router02(0x7F88bC12aa1Ed9fF4605123649Ac90F2Cd9407eB);

    IMakiHecoPool public constant farmpool = IMakiHecoPool(0x4cb4c9C8cC67B171Ce86eB947cf558AFDBcAB17E);
    address public constant makiToken = address(0x5FaD6fBBA4BbA686bA9B8052Cf0bd51699f38B93);
    
    address public strategy;

    constructor(address strategy_) public {
        strategy = strategy_;
    }
    
    modifier onlyStrategy() {
        require(msg.sender == strategy);
        _;
    }

    function getName() external override view returns (string memory name) {
        name = 'maki';
    }

    function getPair(address _t0, address _t1) 
        public override view returns (address pairs) {
        pairs = factory.getPair(_t0, _t1);
    }

    function getToken01(address _pairs) 
        public override view returns (address token0, address token1) {
        token0 = IUniswapV2Pair(_pairs).token0();
        token1 = IUniswapV2Pair(_pairs).token1();
    }

    function getReserves(address _lpToken)
        public override view returns (uint256 a, uint256 b) {
        (a, b, ) = IUniswapV2Pair(_lpToken).getReserves();
    }

    function getAmountOut(address _tokenIn, address _tokenOut, uint256 _amountOut)
        external override view returns (uint256) {
        if(_tokenIn == _tokenOut) {
            return _amountOut;
        }
        if(_amountOut == 0) {
            return 0;
        }
        address[] memory path = new address[](2);
        path[0] = _tokenIn;
        path[1] = _tokenOut;
        uint256[] memory result = router.getAmountsIn(_amountOut, path);
        if(result.length == 0) {
            return 0;
        }
        return result[0];
    }

    function getAmountIn(address _tokenIn, uint256 _amountIn, address _tokenOut)
        public override view returns (uint256) {
        if(_tokenIn == _tokenOut) {
            return _amountIn;
        }
        if(_amountIn == 0) {
            return 0;
        }
        address[] memory path = new address[](2);
        path[0] = _tokenIn;
        path[1] = _tokenOut;
        uint256[] memory result = router.getAmountsOut(_amountIn, path);
        if(result.length == 0) {
            return 0;
        }
        return result[result.length-1];
    }

    function getLPTokenAmountInBaseToken(address _lpToken, uint256 _lpTokenAmount, address _baseToken)
        external override view returns (uint256 amount) {
        (uint256 a, uint256 b) = getReserves(_lpToken);
        (address token0, address token1) = getToken01(_lpToken);
        uint256 totalSupply = IERC20(_lpToken).totalSupply();
        if(token0 == _baseToken) {
            amount = _lpTokenAmount.mul(a).div(totalSupply).mul(2);
        }else if(token1 == _baseToken) {
            amount = _lpTokenAmount.mul(b).div(totalSupply).mul(2);
        }
        else{
            require(false, 'unsupport baseToken not in pairs');
        }
    }

    function swapTokenTo(address _tokenIn, uint256 _amountIn, address _tokenOut, address _toAddress) 
        public override onlyStrategy returns (uint256) {
        if(_tokenIn == _tokenOut) {
            return _safeTransferAll(_tokenOut, _toAddress);
        }
        if(_amountIn == 0 || getAmountIn(_tokenIn, _amountIn, _tokenOut) <= 0) {
            return 0;
        }
        address[] memory path = new address[](2);
        path[0] = _tokenIn;
        path[1] = _tokenOut;
        IERC20(_tokenIn).approve(address(router), _amountIn);
        uint256[] memory result = router.swapExactTokensForTokens(_amountIn, 0, path, _toAddress, block.timestamp.add(60));
        if(result.length == 0) {
            return 0;
        } else {
            return result[result.length-1];
        }
    }

    function optimalBorrowAmount(address _lpToken, uint256 _amount0, uint256 _amount1)
        external view override returns (uint256 borrow0, uint256 borrow1) {
        (uint256 a, uint256 b) = getReserves(_lpToken);
        if (a.mul(_amount1) >= b.mul(_amount0)) {
            borrow0 = _amount1.mul(a).div(b).sub(_amount0);
            borrow1 = 0;
        } else {
            borrow0 = 0;
            borrow1 = _amount0.mul(b).div(a).sub(_amount1);
        }
    }

    /// @dev Compute optimal deposit amount
    /// @param lpToken amount
    /// @param amtA amount of token A desired to deposit
    /// @param amtB amount of token B desired to deposit
    function optimalDepositAmount(
        address lpToken,
        uint amtA,
        uint amtB
    ) public override view returns (uint swapAmt, bool isReversed) {
        (uint256 resA, uint256 resB) = getReserves(lpToken);
        if (amtA.mul(resB) >= amtB.mul(resA)) {
            swapAmt = _optimalDepositA(amtA, amtB, resA, resB);
            isReversed = false;
        } else {
            swapAmt = _optimalDepositA(amtB, amtA, resB, resA);
            isReversed = true;
        }
    }

    /// @dev Compute optimal deposit amount helper.
    /// @param amtA amount of token A desired to deposit
    /// @param amtB amount of token B desired to deposit
    /// @param resA amount of token A in reserve
    /// @param resB amount of token B in reserve
    /// Formula: https://blog.alphafinance.io/byot/
    function _optimalDepositA(
        uint amtA,
        uint amtB,
        uint resA,
        uint resB
    ) internal pure returns (uint) {
        require(amtA.mul(resB) >= amtB.mul(resA), 'Reversed');
        uint a = 998;
        uint b = uint(1998).mul(resA);
        uint _c = (amtA.mul(resB)).sub(amtB.mul(resA));
        uint c = _c.mul(1000).div(amtB.add(resB)).mul(resA);
        uint d = a.mul(c).mul(4);
        uint e = TenMath.sqrt(b.mul(b).add(d));
        uint numerator = e.sub(b);
        uint denominator = a.mul(2);
        return numerator.div(denominator);
    }

    function getDepositToken(uint256 _poolId) 
        public override view returns (address lpToken) {
        (lpToken,,,) = farmpool.poolInfo(_poolId);
    }

    function getRewardToken(uint256 _poolId) 
        external override view returns (address rewardToken) {
        _poolId;
        rewardToken = makiToken;
    }

    function getPending(uint256 _poolId) external override view returns (uint256 rewards) {
        rewards = farmpool.pendingMaki(_poolId, address(this));
    }

    function deposit(uint256 _poolId, bool _autoPool)
        external override onlyStrategy returns (uint256 liquidity) {
        address lpToken = getDepositToken(_poolId);
        (address tokenA, address tokenB) = getToken01(lpToken);
        uint256 amountA;
        uint256 amountB;
        amountA = IERC20(tokenA).balanceOf(address(this));
        amountB = IERC20(tokenB).balanceOf(address(this));
        (uint256 swapAmt, bool isReversed) = optimalDepositAmount(lpToken, amountA, amountB);
        if(swapAmt > 0) {
            swapTokenTo(isReversed?tokenB:tokenA, swapAmt, isReversed?tokenA:tokenB, address(this));
        }
        amountA = IERC20(tokenA).balanceOf(address(this));
        amountB = IERC20(tokenB).balanceOf(address(this));
        if(amountA > 0 && amountB > 0) {
            IERC20(tokenA).approve(address(router), amountA);
            IERC20(tokenB).approve(address(router), amountB);
            router.addLiquidity(tokenA, tokenB, 
                                amountA, amountB, 
                                0, 0, 
                                address(this), block.timestamp.add(60));
            liquidity = IERC20(lpToken).balanceOf(address(this));
            if(liquidity > 0 && _autoPool) {
                IERC20(lpToken).approve(address(farmpool), liquidity);
                farmpool.deposit(_poolId, liquidity);
            }
        }
        _safeTransferAll(lpToken, strategy);
        _safeTransferAll(tokenA, strategy);
        _safeTransferAll(tokenB, strategy);
    }

    function withdraw(uint256 _poolId, uint256 _liquidity, bool _autoPool)
        external override onlyStrategy returns (uint256 amountA, uint256 amountB) {
        if(_liquidity <= 0) return (0, 0);
        if(_autoPool) {
            farmpool.withdraw(_poolId, _liquidity);
        }
        address lpToken = getDepositToken(_poolId);
        (address tokenA, address tokenB) = getToken01(lpToken);
        IERC20(lpToken).approve(address(router), _liquidity);
        // (amountA, amountB) = 
        router.removeLiquidity(tokenA, tokenB, 
                            _liquidity, 
                            0, 0, 
                            strategy, block.timestamp.add(60));
        amountA = _safeTransferAll(tokenA, strategy);
        amountB = _safeTransferAll(tokenB, strategy);
    }

    function claim(uint256 _poolId) 
        external override onlyStrategy returns (uint256 rewards) {
        farmpool.deposit(_poolId, 0);
        rewards = _safeTransferAll(makiToken, strategy);
    }

    function extraRewards() 
        external override onlyStrategy returns (address token, uint256 rewards) {
    }

    function _safeTransferAll(address _token, address _to)
        internal returns (uint256 value){
        value = IERC20(_token).balanceOf(address(this));
        if(value > 0) {
            IERC20(_token).safeTransfer(_to, value);
        }
    }

}
