// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import '../interfaces/IActionPools.sol';
import "../interfaces/IBuyback.sol";
import "../interfaces/IPriceChecker.sol";
import '../interfaces/IStrategyConfig.sol';

import "../interfaces/IStrategyV2SwapPool.sol";

contract StrategyV2Data {

    // Info of each user.
    struct UserInfo {
        uint256 lpAmount;       // deposit lptoken amount
        uint256 lpPoints;       // deposit proportion
        address[] borrowFrom;   // borrowFrom
        uint256[] bids;
    }

    // Info of each pool.
    struct PoolInfo {
        address[] collateralToken;      // collateral Token list, last must be baseToken
        address baseToken;              // baseToken can be borrowed
        address lpToken;                // lptoken to deposit
        uint256 poolId;                 // poolid for mdex pools
        uint256 lastRewardsBlock;       //
        uint256 totalPoints;            // total of user lpPoints
        uint256 totalLPAmount;          // total of user lpAmount
        uint256 totalLPReinvest;        // total of lptoken amount with totalLPAmount and reinvest rewards
        uint256 miniRewardAmount;       //
    }

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo2;

    address public _bank;                // address of bank
    address public _this;
    address public helperImpl;

    IStrategyConfig public sconfig;
    IStrategyV2SwapPool public swapPoolImpl;

    IBuyback public buyback;
    IPriceChecker public priceChecker;
    IActionPools public compActionPool;     // address of comp action pool
}
