// SPDX-License-Identifier: LicenseRef-Degensoft-ARSL-1.0-Audit

pragma solidity ^0.8.24; // tload/tstore are available since 0.8.24

import { TransientLib, tuint256 } from "./Transient.sol";

struct TransientLock {
    tuint256 _raw;
}

library TransientLockLib {
    using TransientLib for tuint256;

    error UnexpectedLock();
    error UnexpectedUnlock();

    uint256 constant private _UNLOCKED = 0;
    uint256 constant private _LOCKED = 1;

    function lock(TransientLock storage self) internal {
        require(self._raw.inc() == _LOCKED, UnexpectedLock());
    }

    function unlock(TransientLock storage self) internal {
        self._raw.dec(UnexpectedUnlock.selector);
    }

    function isLocked(TransientLock storage self) internal view returns (bool) {
        return self._raw.tload() == _LOCKED;
    }
}
