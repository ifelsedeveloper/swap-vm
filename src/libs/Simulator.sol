// SPDX-License-Identifier: LicenseRef-Degensoft-ARSL-1.0-Audit

pragma solidity 0.8.30;

contract Simulator {
    error Simulated(address delegatee, bytes data, bool success, bytes result);

    function simulate(address delegatee, bytes calldata data) external payable {
        (bool success, bytes memory result) = delegatee.delegatecall(data);
        revert Simulated(delegatee, data, success, result);
    }
}
