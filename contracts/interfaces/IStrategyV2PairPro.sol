// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import './IStrategyV2Pair.sol';

interface IStrategyV2PairPro is IStrategyV2Pair {

    function initialize(address bank_, address _swapPoolImpl, address _helperImpl) external;
    
    function bank() external override view returns(address);
    function owner() external view returns (address);

    function setWhitelist(address _contract, bool _enable) external;
    function setComponents(address _compActionPool, address _buyback, address _priceChecker, address _config) external;
    function setPoolConfig(uint256 _pid, string memory _key, uint256 _value) external;

    function addPool(uint256 _poolId, address[] memory _collateralToken, address _baseToken) external;
}