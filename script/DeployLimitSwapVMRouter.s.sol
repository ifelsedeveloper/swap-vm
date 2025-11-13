// SPDX-License-Identifier: LicenseRef-Degensoft-ARSL-1.0-Audit
pragma solidity 0.8.30;

import { Script } from "forge-std/Script.sol";

import { Config } from "./utils/Config.sol";

import { LimitSwapVMRouter } from "../src/routers/LimitSwapVMRouter.sol";

// solhint-disable no-console
import { console2 } from "forge-std/console2.sol";

contract DeployLimitSwapVMRouter is Script {
    using Config for *;

    function run() external {
        (
            address aquaAddress,
            string memory name,
            string memory version
        ) = vm.readSwapVMRouterParameters();

        vm.startBroadcast();
        LimitSwapVMRouter swapVMRouter = new LimitSwapVMRouter(
            aquaAddress,
            name,
            version
        );
        vm.stopBroadcast();

        console2.log("LimitSwapVMRouter deployed at: ", address(swapVMRouter));
    }
}
// solhint-enable no-console
