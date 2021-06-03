// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import './IStrategyLink.sol';

interface IStrategyV2Pair is IStrategyLink {

    event AddPool(uint256 _pid, uint256 _poolId, address lpToken, address _baseToken);
    event SetMiniRewardAmount(uint256 _pid, uint256 _miniRewardAmount);
    event SetPoolImpl(address _oldv, address _new);
    event SetComponents(address _compActionPool, address _buyback, address _priceChecker, address _config);
    event SetPoolConfig(uint256 _pid, string _key, uint256 _value);

    event StrategyBorrow2(address indexed strategy, uint256 indexed pid, address user, address indexed bFrom, uint256 borrowAmount);
    event StrategyRepayBorrow2(address indexed strategy, uint256 indexed pid, address user, address indexed bFrom, uint256 amount);
    event StrategyLiquidation2(address indexed strategy, uint256 indexed pid, address user, uint256 lpamount, uint256 hunteramount);

    function getBorrowInfo(uint256 _pid, address _account, uint256 _bindex) 
        external view returns (address borrowFrom, uint256 bid, uint256 amount);
}