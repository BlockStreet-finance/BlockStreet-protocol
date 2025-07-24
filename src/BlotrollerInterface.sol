// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

abstract contract BlotrollerInterface {
    /// @notice Indicator that this is a Blotroller contract (for inspection)
    bool public constant isBlotroller = true;

    /// @notice Indicator that this is a Comptroller contract (for inspection)
    function isComptroller() external pure returns (bool) {
        return true;
    }

    /*** Assets You Are In ***/

    function enterMarkets(address[] calldata bTokens) virtual external returns (uint[] memory);
    function exitMarket(address bToken) virtual external returns (uint);

    /*** Policy Hooks ***/

    function mintAllowed(address bToken, address minter, uint mintAmount) virtual external returns (uint);
    function mintVerify(address bToken, address minter, uint mintAmount, uint mintTokens) virtual external;

    function redeemAllowed(address bToken, address redeemer, uint redeemTokens) virtual external returns (uint);
    function redeemVerify(address bToken, address redeemer, uint redeemAmount, uint redeemTokens) virtual external;

    function borrowAllowed(address bToken, address borrower, uint borrowAmount) virtual external returns (uint);
    function borrowVerify(address bToken, address borrower, uint borrowAmount) virtual external;

    function repayBorrowAllowed(
        address bToken,
        address payer,
        address borrower,
        uint repayAmount) virtual external returns (uint);
    function repayBorrowVerify(
        address bToken,
        address payer,
        address borrower,
        uint repayAmount,
        uint borrowerIndex) virtual external;

    function liquidateBorrowAllowed(
        address bTokenBorrowed,
        address bTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount) virtual external returns (uint);
    function liquidateBorrowVerify(
        address bTokenBorrowed,
        address bTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount,
        uint seizeTokens) virtual external;

    function seizeAllowed(
        address bTokenCollateral,
        address bTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) virtual external returns (uint);
    function seizeVerify(
        address bTokenCollateral,
        address bTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens) virtual external;

    function transferAllowed(address bToken, address src, address dst, uint transferTokens) virtual external returns (uint);
    function transferVerify(address bToken, address src, address dst, uint transferTokens) virtual external;

    /*** Liquidity/Liquidation Calculations ***/

    function liquidateCalculateSeizeTokens(
        address bTokenBorrowed,
        address bTokenCollateral,
        uint repayAmount) virtual external view returns (uint, uint);
}
