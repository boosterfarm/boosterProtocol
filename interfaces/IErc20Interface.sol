// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface IErc20Interface {

    /*** User Interface ***/
    function underlying() external view returns (address);

    function mint(uint mintAmount) external returns (uint);  //
    function redeem(uint redeemTokens) external returns (uint);
    function redeemUnderlying(uint redeemAmount) external returns (uint);
    function borrow(uint borrowAmount) external returns (uint);
    function repayBorrow(uint repayAmount) external returns (uint);
    // function repayBorrowBehalf(address borrower, uint repayAmount) external returns (uint);
    // function liquidateBorrow(address borrower, uint repayAmount, CTokenInterface cTokenCollateral) external returns (uint);

}