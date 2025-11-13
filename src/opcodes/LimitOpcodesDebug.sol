// SPDX-License-Identifier: LicenseRef-Degensoft-ARSL-1.0-Audit

pragma solidity 0.8.30;

import { Context } from "../libs/VM.sol";

import { LimitOpcodes } from "./LimitOpcodes.sol";
import { Debug } from "../instructions/Debug.sol";

contract LimitOpcodesDebug is LimitOpcodes, Debug {
    constructor(address aqua) LimitOpcodes(aqua) {}

    function _opcodes() internal pure override returns (function(Context memory, bytes calldata) internal[] memory) {
        return _injectDebugOpcodes(super._opcodes());
    }
}
