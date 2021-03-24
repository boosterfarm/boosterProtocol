// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import './IStrategyLink.sol';

interface IStrategyConfig {
    // event
    event SetFeeGather(address _feeGatherOld, address _feeGather);
    event SetReservedGather(address _old, address _new);
    event SetBorrowFactor(address _strategy, uint256 _poolid, uint256 _borrowFactor);
    event SetLiquidationFactor(address _strategy, uint256 _poolid, uint256 _liquidationFactor);
    event SetFarmPoolFactor(address _strategy, uint256 _poolid, uint256 _farmPoolFactor);
    event SetDepositFee(address _strategy, uint256 _poolid, uint256 _depositFee);
    event SetWithdrawFee(address _strategy, uint256 _poolid, uint256 _withdrawFee);
    event SetRefundFee(address _strategy, uint256 _poolid, uint256 _refundFee);
    event SetClaimFee(address _strategy, uint256 _poolid, uint256 _claimFee);
    event SetLiquidationFee(address _strategy, uint256 _poolid, uint256 _liquidationFee);

    // factor 
    function getBorrowFactor(address _strategy, uint256 _poolid) external view returns (uint256);
    function setBorrowFactor(address _strategy, uint256 _poolid, uint256 _borrowFactor) external;

    function getLiquidationFactor(address _strategy, uint256 _poolid) external view returns (uint256);
    function setLiquidationFactor(address _strategy, uint256 _poolid, uint256 _liquidationFactor) external;
    
    function getFarmPoolFactor(address _strategy, uint256 _poolid) external view returns (uint256 value);
    function setFarmPoolFactor(address _strategy, uint256 _poolid, uint256 _farmPoolFactor) external;

    // fee manager
    function getDepositFee(address _strategy, uint256 _poolid) external view returns (address, uint256);
    function setDepositFee(address _strategy, uint256 _poolid, uint256 _depositFee) external;

    function getWithdrawFee(address _strategy, uint256 _poolid) external view returns (address, uint256);
    function setWithdrawFee(address _strategy, uint256 _poolid, uint256 _withdrawFee) external;

    function getRefundFee(address _strategy, uint256 _poolid) external view returns (address, uint256);
    function setRefundFee(address _strategy, uint256 _poolid, uint256 _refundFee) external;

    function getClaimFee(address _strategy, uint256 _poolid) external view returns (address, uint256);
    function setClaimFee(address _strategy, uint256 _poolid, uint256 _claimFee) external;

    function getLiquidationFee(address _strategy, uint256 _poolid) external view returns (address, uint256);
    function setLiquidationFee(address _strategy, uint256 _poolid, uint256 _liquidationFee) external;
}