// SPDX-License-Identifier: LicenseRef-Degensoft-ARSL-1.0-Audit

pragma solidity 0.8.30;

library Power {
    /// @notice Calculates base^exponent with given precision
    /// @param base The base value (scaled by precision)
    /// @param exponent The exponent (unscaled)
    /// @param precision The precision scale (e.g., 1e18)
    /// @return result The result of base^exponent (scaled by precision)
    function pow(uint256 base, uint256 exponent, uint256 precision) internal pure returns (uint256 result) {
        result = precision;

        while (exponent > 0) {
            if (exponent & 1 == 1) {
                result = (result * base) / precision;
            }
            base = (base * base) / precision;
            exponent >>= 1;
        }
    }
}
