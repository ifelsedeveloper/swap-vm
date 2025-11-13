// SPDX-License-Identifier: LicenseRef-Degensoft-ARSL-1.0-Audit

pragma solidity 0.8.30;

import { Context } from "../libs/VM.sol";
import { Simulator } from "../libs/Simulator.sol";

import { SwapVM } from "../SwapVM.sol";
import { AquaOpcodesDebug } from "../opcodes/AquaOpcodesDebug.sol";

contract AquaSwapVMRouterDebug is Simulator, SwapVM, AquaOpcodesDebug {
    constructor(address aqua, string memory name, string memory version) SwapVM(aqua, name, version) AquaOpcodesDebug(aqua) { }

    function _instructions() internal pure override returns (function(Context memory, bytes calldata) internal[] memory) {
        return _opcodes();
    }
}
