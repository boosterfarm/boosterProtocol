// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.5.0 <0.8.0;

interface ICocoHecoSwapMining {
    function dex() external view returns (address);
    
    function takerWithdraw() external;
}
