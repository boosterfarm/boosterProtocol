// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import './IStrategyV2SwapPool.sol';

interface IStrategyV2SwapPoolPro is IStrategyV2SwapPool {
    function setStrategy(address _strategy) external;
}