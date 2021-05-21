// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface IStrategyV2SwapPool {

    // get strategy
    function getName() external view returns (string memory);

    // swap functions
    function getPair(address _t0, address _t1) external view returns (address pairs);
    function getReserves(address _lpToken) external view returns (uint256 a, uint256 b);
    function getToken01(address _pairs) external view returns (address token0, address token1);
    function getAmountOut(address _tokenIn, address _tokenOut, uint256 _amountOut) external view returns (uint256);
    function getAmountIn(address _tokenIn, uint256 _amountIn, address _tokenOut) external view returns (uint256);
    function getLPTokenAmountInBaseToken(address _lpToken, uint256 _lpTokenAmount, address _baseToken) external view returns (uint256 amount);
    function swapTokenTo(address _tokenIn, uint256 _amountIn, address _tokenOut, address _toAddress) external returns (uint256 value);

    function optimalBorrowAmount(address _lpToken, uint256 _amount0, uint256 _amount1) external view returns (uint256 borrow0, uint256 borrow1);
    function optimalDepositAmount(address lpToken, uint amtA, uint amtB) external view returns (uint swapAmt, bool isReversed);

    // pool functions
    function getDepositToken(uint256 _poolId) external view returns (address lpToken);
    function getRewardToken(uint256 _poolId) external view returns (address rewardToken);
    function getPending(uint256 _poolId) external view returns (uint256 rewards);
    function deposit(uint256 _poolId, bool _autoPool) external returns (uint256 liquidity);
    function withdraw(uint256 _poolId, uint256 _liquidity, bool _autoPool) external returns (uint256 amountA, uint256 amountB);
    function claim(uint256 _poolId) external returns (uint256 rewards);
    function extraRewards() external returns (address token, uint256 rewards);
}