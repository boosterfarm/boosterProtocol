// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface ICompActionTrigger {
    function getCATPoolInfo(uint256 _pid) external view 
        returns (address lpToken, uint256 allocRate, uint256 totalPoints, uint256 totalAmount);
    function getCATUserAmount(uint256 _pid, address _account) external view 
        returns (uint256 points);
}