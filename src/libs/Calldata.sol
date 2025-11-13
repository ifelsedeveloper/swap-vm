// SPDX-License-Identifier: LicenseRef-Degensoft-ARSL-1.0-Audit

pragma solidity 0.8.30;

library Calldata {
    function slice(bytes calldata calls, uint256 begin, uint256 end) internal pure returns (bytes calldata res) {
        assembly ("memory-safe") {  // solhint-disable-line no-inline-assembly
            res.offset := add(calls.offset, begin)
            res.length := sub(end, begin)
        }
    }

    function slice(bytes calldata calls, uint256 begin, uint256 end, bytes4 exception) internal pure returns (bytes calldata res) {
        if (end > calls.length) {
            assembly ("memory-safe") {  // solhint-disable-line no-inline-assembly
                mstore(0, exception)
                revert(0, 4)
            }
        }
        assembly ("memory-safe") {  // solhint-disable-line no-inline-assembly
            res.offset := add(calls.offset, begin)
            res.length := sub(end, begin)
        }
    }

    function slice(bytes calldata calls, uint256 begin) internal pure returns (bytes calldata res) {
        assembly ("memory-safe") {  // solhint-disable-line no-inline-assembly
            res.offset := add(calls.offset, begin)
            res.length := sub(calls.length, begin)
        }
    }

    function slice(bytes calldata calls, uint256 begin, bytes4 exception) internal pure returns (bytes calldata res) {
        if (begin > calls.length) {
            assembly ("memory-safe") {  // solhint-disable-line no-inline-assembly
                mstore(0, exception)
                revert(0, 4)
            }
        }
        assembly ("memory-safe") {  // solhint-disable-line no-inline-assembly
            res.offset := add(calls.offset, begin)
            res.length := sub(calls.length, begin)
        }
    }
}
