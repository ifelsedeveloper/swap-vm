// SPDX-License-Identifier: LicenseRef-Degensoft-ARSL-1.0-Audit

pragma solidity 0.8.30;

import { Context } from "../libs/VM.sol";

import { Opcodes } from "./Opcodes.sol";
import { Debug } from "../instructions/Debug.sol";

contract OpcodesDebug is Opcodes, Debug {
    constructor(address aqua) Opcodes(aqua) {}

    function _opcodes() internal pure override returns (function(Context memory, bytes calldata) internal[] memory) {
        return _injectDebugOpcodes(super._opcodes());
    }
}
