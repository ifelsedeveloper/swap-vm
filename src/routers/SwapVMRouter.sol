// SPDX-License-Identifier: LicenseRef-Degensoft-ARSL-1.0-Audit

pragma solidity 0.8.30;

import { Context } from "../libs/VM.sol";
import { Simulator } from "../libs/Simulator.sol";

import { SwapVM } from "../SwapVM.sol";
import { Opcodes } from "../opcodes/Opcodes.sol";

contract SwapVMRouter is Simulator, SwapVM, Opcodes {
    constructor(address aqua, string memory name, string memory version) SwapVM(aqua, name, version) Opcodes(aqua) { }

    function _instructions() internal pure override returns (function(Context memory, bytes calldata) internal[] memory result) {
        return _opcodes();
    }
}
