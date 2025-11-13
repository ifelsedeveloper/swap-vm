// SPDX-License-Identifier: LicenseRef-Degensoft-ARSL-1.0-Audit
pragma solidity 0.8.30;

import { ISwapVM } from "../../src/interfaces/ISwapVM.sol";
import { SwapVM } from "../../src/SwapVM.sol";

/**
 * @title ExactInOutSymmetry
 * @notice Tests exactIn(X) → Y, then exactOut(Y) should require X
 */
library ExactInOutSymmetry {
    error AsymmetryDetected(uint256 expectedIn, uint256 actualIn, uint256 diff);

    function assertSymmetry(
        SwapVM swapVM,
        ISwapVM.Order memory order,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        bytes memory takerDataExactIn,
        bytes memory takerDataExactOut,
        uint256 tolerance
    ) internal view {
        // ExactIn: amountIn → ?
        (, uint256 amountOut,) = swapVM.asView().quote(
            order, tokenIn, tokenOut, amountIn, takerDataExactIn
        );

        // ExactOut: ? → amountOut
        (uint256 amountInBack,,) = swapVM.asView().quote(
            order, tokenIn, tokenOut, amountOut, takerDataExactOut
        );

        uint256 diff = amountInBack > amountIn ?
            amountInBack - amountIn : amountIn - amountInBack;

        if (diff > tolerance) {
            revert AsymmetryDetected(amountIn, amountInBack, diff);
        }
    }

    function assertSymmetryBatch(
        SwapVM swapVM,
        ISwapVM.Order memory order,
        address tokenIn,
        address tokenOut,
        uint256[] memory amounts,
        bytes memory takerDataExactIn,
        bytes memory takerDataExactOut,
        uint256 tolerance
    ) internal view {
        for (uint256 i = 0; i < amounts.length; i++) {
            assertSymmetry(
                swapVM, order, tokenIn, tokenOut, amounts[i],
                takerDataExactIn, takerDataExactOut, tolerance
            );
        }
    }
}
