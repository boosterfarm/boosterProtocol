// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPriceChecker {
    function getPriceSlippage(address _lptoken) external view returns (uint256);
    function checkLPTokenPriceLimit(address _lptoken, bool _largeType) external view returns (bool);
}