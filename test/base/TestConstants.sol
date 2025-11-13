// SPDX-License-Identifier: LicenseRef-Degensoft-ARSL-1.0-Audit
pragma solidity 0.8.30;

abstract contract TestConstants {
    uint256 constant ONE = 1e18;

    // Common balances
    uint256 constant INITIAL_BALANCE_A = 1000e18;
    uint256 constant INITIAL_BALANCE_B = 2000e18;

    // Get base price from initial balances
    function getBasePrice() public pure returns (uint256) {
        return (INITIAL_BALANCE_B * ONE) / INITIAL_BALANCE_A; // 2.0
    }
}
