// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface ITokenOracle {
    function getPrice(address _token) external view returns (int);
}
