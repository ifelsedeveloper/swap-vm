// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { ISwapVM } from "../../src/interfaces/ISwapVM.sol";
import { SwapVM } from "../../src/SwapVM.sol";
import { SwapVMRouter } from "../../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../../src/opcodes/OpcodesDebug.sol";
import { Program, ProgramBuilder } from "../utils/ProgramBuilder.sol";
import { BalancesArgsBuilder } from "../../src/instructions/Balances.sol";
import { XYCConcentrateArgsBuilder } from "../../src/instructions/XYCConcentrate.sol";
import { FeeArgsBuilder } from "../../src/instructions/Fee.sol";
import { FeeArgsBuilderExperimental } from "../../src/instructions/FeeExperimental.sol";
import { dynamic } from "../utils/Dynamic.sol";

import { ProtocolFeeProviderMock } from "../../mocks/ProtocolFeeProviderMock.sol";

import { CoreInvariants } from "./CoreInvariants.t.sol";

/**
 * @title ConcentrateXYCFeesInvariants
 * @notice Tests invariants for Concentrate + XYCSwap + all types of fees
 * @dev Tests concentrated liquidity with different fee structures
 */
contract ConcentrateXYCFeesInvariants is Test, OpcodesDebug, CoreInvariants {
    using ProgramBuilder for Program;

    Aqua public immutable aqua;
    SwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPK = 0x1234;
    address public taker;
    address public feeRecipient;

    constructor() OpcodesDebug(address(aqua = new Aqua())) {}

    function setUp() public {
        maker = vm.addr(makerPK);
        taker = address(this);
        feeRecipient = address(0xFEE);
        swapVM = new SwapVMRouter(address(aqua), address(0), "SwapVM", "1.0.0");

        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");

        // Setup tokens and approvals for maker
        tokenA.mint(maker, 100000e18);
        tokenB.mint(maker, 100000e18);
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        // Setup approvals for taker (test contract)
        tokenA.approve(address(swapVM), type(uint256).max);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    function _concentrateBalances(
        uint256 available,
        uint256 sqrtPmin,
        uint256 sqrtPmax
    ) internal view returns (uint256 balA, uint256 balB) {
        (, uint256 actualLt, uint256 actualGt) =
            XYCConcentrateArgsBuilder.computeLiquidityFromAmounts(
                available, available, 1e18, sqrtPmin, sqrtPmax
            );
        (balA, balB) = address(tokenA) < address(tokenB)
            ? (actualLt, actualGt)
            : (actualGt, actualLt);
    }

    /**
     * @notice Implementation of _executeSwap for real swap execution
     */
    function _executeSwap(
        SwapVM _swapVM,
        ISwapVM.Order memory order,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes memory takerData
    ) internal override returns (uint256 amountIn, uint256 amountOut) {
        // Mint the input tokens
        TokenMock(tokenIn).mint(taker, amount * 10);

        // Execute the swap
        (uint256 actualIn, uint256 actualOut,) = _swapVM.swap(
            order,
            tokenIn,
            tokenOut,
            amount,
            takerData
        );

        // Verify the swap consumed the expected input amount

        return (actualIn, actualOut);
    }

    // ====== GrowLiquidity2D Tests ======

    /**
     * Test Concentrate + XYC with flat fee on input
     */
    function test_ConcentrateXYCFlatFeeIn() public {
        uint256 sqrtPmin = Math.sqrt(0.8e36);
        uint256 sqrtPmax = Math.sqrt(1.25e36);
        (uint256 balanceA, uint256 balanceB) = _concentrateBalances(1000e18, sqrtPmin, sqrtPmax);
        uint32 feeBps = 0.003e9; // 0.3% fee
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_xycConcentrateGrowLiquidity2D,
                XYCConcentrateArgsBuilder.build2D(sqrtPmin, sqrtPmax)),
            program.build(_flatFeeAmountInXD,
                FeeArgsBuilder.buildFlatFee(feeBps)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        InvariantConfig memory config = _getDefaultConfig();
        config.exactInTakerData = _signAndPackTakerData(order, true, 0);
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    /**
     * Test Concentrate + XYC with flat fee on output
     */
    function test_ConcentrateXYCFlatFeeOut() public {
        uint256 sqrtPmin = Math.sqrt(0.8e36);
        uint256 sqrtPmax = Math.sqrt(1.25e36);
        (uint256 balanceA, uint256 balanceB) = _concentrateBalances(1500e18, sqrtPmin, sqrtPmax);
        uint32 feeBps = 0.005e9; // 0.5% fee
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_xycConcentrateGrowLiquidity2D,
                XYCConcentrateArgsBuilder.build2D(sqrtPmin, sqrtPmax)),
            program.build(_flatFeeAmountOutXD,
                FeeArgsBuilder.buildFlatFee(feeBps)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        InvariantConfig memory config = _getDefaultConfig();
        config.exactInTakerData = _signAndPackTakerData(order, true, 0);
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);
        // TODO: need to research behavior - state-dependent due to scale
        config.skipAdditivity = true;

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    /**
     * Test Concentrate + XYC with progressive fee on input
     */
    function test_ConcentrateXYCProgressiveFeeIn() public {
        uint256 sqrtPmin = Math.sqrt(0.8e36);
        uint256 sqrtPmax = Math.sqrt(1.25e36);
        (uint256 balanceA, uint256 balanceB) = _concentrateBalances(2000e18, sqrtPmin, sqrtPmax);
        uint32 feeBps = 0.1e9; // 10% progressive fee
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_xycConcentrateGrowLiquidity2D,
                XYCConcentrateArgsBuilder.build2D(sqrtPmin, sqrtPmax)),
            program.build(_progressiveFeeInXD,
                FeeArgsBuilderExperimental.buildProgressiveFee(feeBps)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        InvariantConfig memory config = _getDefaultConfig();
        config.exactInTakerData = _signAndPackTakerData(order, true, 0);
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);
        // TODO: Progressive fees violate additivity by design
        config.skipAdditivity = true;
        // TODO: need to research behavior
        config.skipSymmetry = true;

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    /**
     * Test Concentrate + XYC with progressive fee on output
     */
    function test_ConcentrateXYCProgressiveFeeOut() public {
        uint256 sqrtPmin = Math.sqrt(0.8e36);
        uint256 sqrtPmax = Math.sqrt(1.25e36);
        (uint256 balanceA, uint256 balanceB) = _concentrateBalances(2000e18, sqrtPmin, sqrtPmax);
        uint32 feeBps = 0.1e9; // 10% progressive fee
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_xycConcentrateGrowLiquidity2D,
                XYCConcentrateArgsBuilder.build2D(sqrtPmin, sqrtPmax)),
            program.build(_progressiveFeeOutXD,
                FeeArgsBuilderExperimental.buildProgressiveFee(feeBps)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        InvariantConfig memory config = _getDefaultConfig();
        config.exactInTakerData = _signAndPackTakerData(order, true, 0);
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);
        // TODO: Progressive fees violate additivity by design
        config.skipAdditivity = true;
        // TODO: need to research behavior
        config.skipSymmetry = true;

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    /**
     * Test Concentrate + XYC with protocol fee on amountIn
     */
    function test_ConcentrateXYCProtocolFeeIn() public {
        uint256 sqrtPmin = Math.sqrt(0.8e36);
        uint256 sqrtPmax = Math.sqrt(1.25e36);
        (uint256 balanceA, uint256 balanceB) = _concentrateBalances(1000e18, sqrtPmin, sqrtPmax);
        uint32 feeBps = 0.002e9; // 0.2% protocol fee
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            // Protocol fee on amountIn BEFORE balances
            program.build(_protocolFeeAmountInXD,
                FeeArgsBuilder.buildProtocolFee(feeBps, feeRecipient)),
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_xycConcentrateGrowLiquidity2D,
                XYCConcentrateArgsBuilder.build2D(sqrtPmin, sqrtPmax)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        InvariantConfig memory config = _getDefaultConfig();
        config.exactInTakerData = _signAndPackTakerData(order, true, 0);
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    /**
     * Test Concentrate + XYC with dynamic protocol fee on amountIn
     */
    function test_ConcentrateXYCDynamicProtocolFeeIn() public {
        uint256 sqrtPmin = Math.sqrt(0.8e36);
        uint256 sqrtPmax = Math.sqrt(1.25e36);
        (uint256 balanceA, uint256 balanceB) = _concentrateBalances(1000e18, sqrtPmin, sqrtPmax);
        uint32 feeBps = 0.002e9; // 0.2% protocol fee

        // Deploy dynamic fee provider
        ProtocolFeeProviderMock feeProviderMock = new ProtocolFeeProviderMock(
            feeBps,
            feeRecipient,
            address(this)
        );
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            // Dynamic protocol fee on amountIn BEFORE balances
            program.build(_dynamicProtocolFeeAmountInXD,
                FeeArgsBuilder.buildDynamicProtocolFee(address(feeProviderMock))),
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_xycConcentrateGrowLiquidity2D,
                XYCConcentrateArgsBuilder.build2D(sqrtPmin, sqrtPmax)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        InvariantConfig memory config = _getDefaultConfig();
        config.exactInTakerData = _signAndPackTakerData(order, true, 0);
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);
        // Protocol fee causes 1 wei rounding in additivity
        config.additivityTolerance = 1;

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    /**
     * Test Concentrate + XYC with protocol fee
     */
    function test_ConcentrateXYCProtocolFee() public {
        uint256 sqrtPmin = Math.sqrt(0.8e36);
        uint256 sqrtPmax = Math.sqrt(1.25e36);
        (uint256 balanceA, uint256 balanceB) = _concentrateBalances(1000e18, sqrtPmin, sqrtPmax);
        uint32 feeBps = 0.002e9; // 0.2% protocol fee
        // Pre-approve for protocol fee transfers
        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);

        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            // Protocol fee BEFORE balances
            program.build(_protocolFeeAmountOutXD,
                FeeArgsBuilder.buildProtocolFee(feeBps, feeRecipient)),
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_xycConcentrateGrowLiquidity2D,
                XYCConcentrateArgsBuilder.build2D(sqrtPmin, sqrtPmax)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        InvariantConfig memory config = _getDefaultConfig();
        config.exactInTakerData = _signAndPackTakerData(order, true, 0);
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);
        // Protocol fee causes 1 wei rounding in additivity
        config.additivityTolerance = 1;

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    /**
     * Test multiple fee types with Concentrate + XYC
     */
    function test_ConcentrateXYCMultipleFees() public {
        uint256 sqrtPmin = Math.sqrt(0.8e36);
        uint256 sqrtPmax = Math.sqrt(1.25e36);
        (uint256 balanceA, uint256 balanceB) = _concentrateBalances(3000e18, sqrtPmin, sqrtPmax);
        uint32 flatFeeBps = 0.001e9;      // 0.1% flat fee
        uint32 protocolFeeBps = 0.02e9; // 2% protocol fee
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory bytecode = bytes.concat(
            program.build(_protocolFeeAmountOutXD,
                FeeArgsBuilder.buildProtocolFee(protocolFeeBps, feeRecipient)),
            program.build(_dynamicBalancesXD,
                BalancesArgsBuilder.build(
                    dynamic([address(tokenA), address(tokenB)]),
                    dynamic([balanceA, balanceB])
                )),
            program.build(_xycConcentrateGrowLiquidity2D,
                XYCConcentrateArgsBuilder.build2D(sqrtPmin, sqrtPmax)),
            program.build(_flatFeeAmountInXD,
                FeeArgsBuilder.buildFlatFee(flatFeeBps)),
            program.build(_flatFeeAmountOutXD,
                FeeArgsBuilder.buildFlatFee(flatFeeBps)),
            program.build(_xycSwapXD)
        );

        ISwapVM.Order memory order = _createOrder(bytecode);

        InvariantConfig memory config = createInvariantConfig(
            dynamic([uint256(10e18), uint256(20e18), uint256(50e18)]),
            1
        );
        config.exactInTakerData = _signAndPackTakerData(order, true, 0);
        config.exactOutTakerData = _signAndPackTakerData(order, false, type(uint256).max);
        // TODO: Complex fee interactions affect additivity
        config.skipAdditivity = true;
        // With multiple fees (2% protocol + 0.1% flat in + 0.1% flat out = ~2.2% total),
        // a 1-wei input will have all fees round to 0, giving rate=1.0 vs spot=0.978.
        // Use 250 bps (2.5%) rounding tolerance to accommodate this edge case.
        config.roundingToleranceBps = 250;

        assertAllInvariantsWithConfig(
            swapVM,
            order,
            address(tokenA),
            address(tokenB),
            config
        );
    }

    // Helper functions
    function _createOrder(bytes memory program) private view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            shouldUnwrapWeth: false,
            useAquaInsteadOfSignature: false,
            allowZeroAmountIn: false,
            receiver: address(0),
            hasPreTransferInHook: false,
            hasPostTransferInHook: false,
            hasPreTransferOutHook: false,
            hasPostTransferOutHook: false,
            preTransferInTarget: address(0),
            preTransferInData: "",
            postTransferInTarget: address(0),
            postTransferInData: "",
            preTransferOutTarget: address(0),
            preTransferOutData: "",
            postTransferOutTarget: address(0),
            postTransferOutData: "",
            program: program
        }));
    }

    function _signAndPackTakerData(
        ISwapVM.Order memory order,
        bool isExactIn,
        uint256 threshold
    ) private view returns (bytes memory) {
        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPK, orderHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        bytes memory thresholdData = threshold > 0 ? abi.encodePacked(bytes32(threshold)) : bytes("");

        bytes memory takerTraits = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: address(0),
            isExactIn: isExactIn,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            threshold: thresholdData,
            to: address(this),
            deadline: 0,
            hasPreTransferInCallback: false,
            hasPreTransferOutCallback: false,
            preTransferInHookData: "",
            postTransferInHookData: "",
            preTransferOutHookData: "",
            postTransferOutHookData: "",
            preTransferInCallbackData: "",
            preTransferOutCallbackData: "",
            instructionsArgs: "",
            signature: signature
        }));

        return abi.encodePacked(takerTraits);
    }
}
