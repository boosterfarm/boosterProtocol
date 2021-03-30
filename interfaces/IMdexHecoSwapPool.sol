// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.5.0 <0.8.0;

interface IMdexHecoSwapPool {
    function takerWithdraw() external;
    function mdx() external returns (address);
}
