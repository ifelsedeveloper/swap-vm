// SPDX-License-Identifier: LicenseRef-Degensoft-ARSL-1.0-Audit

pragma solidity 0.8.30;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Context, ContextLib } from "../libs/VM.sol";

contract XYCSwap {
    using ContextLib for Context;

    error XYCSwapRecomputeDetected();
    error XYCSwapRequiresBothBalancesNonZero(uint256 balanceIn, uint256 balanceOut);

    function _xycSwapXD(Context memory ctx, bytes calldata /* args */) internal pure {
        require(ctx.swap.balanceIn > 0 && ctx.swap.balanceOut > 0, XYCSwapRequiresBothBalancesNonZero(ctx.swap.balanceIn, ctx.swap.balanceOut));

        if (ctx.query.isExactIn) {
            require(ctx.swap.amountOut == 0, XYCSwapRecomputeDetected());
            ctx.swap.amountOut = ( // Floor division for tokenOut is desired behavior
                (ctx.swap.amountIn * ctx.swap.balanceOut) /
                (ctx.swap.balanceIn + ctx.swap.amountIn)
            );
        } else {
            require(ctx.swap.amountIn == 0, XYCSwapRecomputeDetected());
            ctx.swap.amountIn = Math.ceilDiv( // Ceiling division for tokenIn is desired behavior
                ctx.swap.amountOut * ctx.swap.balanceIn,
                (ctx.swap.balanceOut - ctx.swap.amountOut)
            );
        }
    }
}
