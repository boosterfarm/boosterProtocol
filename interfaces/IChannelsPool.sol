// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface IChannelsPool {

    // 查询各种池子信息
    function claimCan(address holder) external;
    function claimCan(address holder, address[] memory cTokens) external;
    function claimCan(address[] memory holders, address[] memory cTokens, bool borrowers, bool suppliers) external;

    function getAllMarkets() external view returns (address[] memory);
}