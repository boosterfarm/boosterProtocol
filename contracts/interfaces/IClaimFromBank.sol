// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IClaimFromBank {
    function claimFromBank(address _account, uint256[] memory _pidlist) external returns (uint256 value);
}