// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2025 Degensoft Ltd

import { Test } from "forge-std/Test.sol";
import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";

import { SwapVM, ISwapVM } from "../src/SwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { Controls, ControlsArgsBuilder } from "../src/instructions/Controls.sol";
import { Balances, BalancesArgsBuilder } from "../src/instructions/Balances.sol";
import { LimitSwap, LimitSwapArgsBuilder } from "../src/instructions/LimitSwap.sol";
import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";

// Mock NFT token for gating
contract MockNFT is ERC721 {
    uint256 private _tokenIdCounter;

    constructor(string memory name, string memory symbol) ERC721(name, symbol) {}

    function mint(address to) external returns (uint256) {
        uint256 tokenId = _tokenIdCounter++;
        _safeMint(to, tokenId);
        return tokenId;
    }
}

contract ControlsTest is Test, OpcodesDebug {
    using ProgramBuilder for Program;

    constructor() OpcodesDebug(address(0)) {}

    SwapVMRouter public swapVM;
    TokenMock public tokenA;
    TokenMock public tokenB;
    MockNFT public nftGate;

    address public maker;
    uint256 public makerPrivateKey;
    address public taker;

    function setUp() public {
        // Setup maker and taker
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);
        taker = address(0x7777);

        // Deploy SwapVM router
        swapVM = new SwapVMRouter(address(0), "SwapVM", "1.0.0");

        // Deploy mock tokens
        tokenA = new TokenMock("Token A", "TKA");
        tokenB = new TokenMock("Token B", "TKB");
        nftGate = new MockNFT("NFT Gate", "NFTG");

        // Setup initial balances
        tokenA.mint(maker, 1000e18);
        tokenB.mint(taker, 1000e18);

        // Approve SwapVM to spend tokens
        vm.prank(maker);
        tokenA.approve(address(swapVM), type(uint256).max);
        vm.prank(taker);
        tokenB.approve(address(swapVM), type(uint256).max);
    }

    function test_DeadlineControl() public {
        // Set deadline to 100 seconds from now
        uint40 deadline = uint40(block.timestamp + 100);

        // Prepare balances arguments (1:1 swap ratio)
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        uint256[] memory balances = new uint256[](2);
        balances[0] = 100e18;  // 100 tokenA available
        balances[1] = 100e18;  // 100 tokenB available

        // Build program with deadline check, balance setup, and limit swap
        Program memory p = ProgramBuilder.init(_opcodes());
        bytes memory programBytes = bytes.concat(
            p.build(Controls._deadline, ControlsArgsBuilder.buildDeadline(deadline)),
            p.build(Balances._staticBalancesXD, BalancesArgsBuilder.build(tokens, balances)),
            p.build(LimitSwap._limitSwap1D, LimitSwapArgsBuilder.build(address(tokenB), address(tokenA)))
        );

        // Create order
        ISwapVM.Order memory order = MakerTraitsLib.build(MakerTraitsLib.Args({
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
            program: programBytes
        }));

        // Sign order
        bytes32 orderHash = swapVM.hash(order);
        bytes memory signature = _signOrder(orderHash, makerPrivateKey);

        // Create taker data for partial fill
        bytes memory takerData = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            threshold: abi.encodePacked(uint256(25e18)), // Expect at least 25 tokenA
            to: address(0),
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

        // Test 1: Execute swap before deadline (should succeed)
        vm.prank(taker);
        (uint256 amountIn1, uint256 amountOut1, ) = swapVM.swap(
            order,
            address(tokenB), // tokenIn
            address(tokenA), // tokenOut
            80e18,           // amount
            takerData
        );

        // Verify first swap succeeded
        assertEq(amountIn1, 80e18, "First swap: incorrect amountIn");
        assertEq(amountOut1, 80e18, "First swap: incorrect amountOut");

        // Try to execute after deadline (should revert)
        vm.warp(block.timestamp + 101); // Move time forward to exceed deadline

        vm.prank(taker);
        vm.expectRevert(
            abi.encodeWithSelector(
                Controls.DeadlineReached.selector,
                taker,
                deadline
            )
        );
        swapVM.swap(
            order,
            address(tokenB),
            address(tokenA),
            20e18,
            takerData
        );

        // Verify final balances
        assertEq(tokenA.balanceOf(maker), 1000e18 - 80e18, "Maker should have sent 80 tokenA");
        assertEq(tokenB.balanceOf(maker), 80e18, "Maker should have received 80 tokenB");
        assertEq(tokenA.balanceOf(taker), 80e18, "Taker should have received 80 tokenA");
        assertEq(tokenB.balanceOf(taker), 1000e18 - 80e18, "Taker should have sent 80 tokenB");
    }

    function test_DeadlineAlreadyPassed() public {
        // Set deadline to a time in the past
        uint40 deadline = uint40(block.timestamp - 1);

        // Prepare balances arguments (1:1 swap ratio)
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        uint256[] memory balances = new uint256[](2);
        balances[0] = 100e18;  // 100 tokenA available
        balances[1] = 100e18;  // 100 tokenB available

        // Build program with deadline check, balance setup, and limit swap
        Program memory p = ProgramBuilder.init(_opcodes());
        bytes memory programBytes = bytes.concat(
            p.build(Controls._deadline, ControlsArgsBuilder.buildDeadline(deadline)),
            p.build(Balances._staticBalancesXD, BalancesArgsBuilder.build(tokens, balances)),
            p.build(LimitSwap._limitSwap1D, LimitSwapArgsBuilder.build(address(tokenB), address(tokenA)))
        );

        // Create order
        ISwapVM.Order memory order = MakerTraitsLib.build(MakerTraitsLib.Args({
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
            program: programBytes
        }));

        // Sign order
        bytes32 orderHash = swapVM.hash(order);
        bytes memory signature = _signOrder(orderHash, makerPrivateKey);

        // Create taker data
        bytes memory takerData = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            threshold: abi.encodePacked(uint256(50e18)),
            to: address(0),
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

        // Should revert immediately because deadline has already passed
        vm.prank(taker);
        vm.expectRevert(
            abi.encodeWithSelector(
                Controls.DeadlineReached.selector,
                taker,
                deadline
            )
        );
        swapVM.swap(
            order,
            address(tokenB),
            address(tokenA),
            50e18,
            takerData
        );
    }

    function test_OnlyTakerTokenBalanceNonZero_Success() public {
        // Mint NFT to taker so they can pass the gate check
        nftGate.mint(taker);

        // Prepare balances arguments (1:1 swap ratio)
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        uint256[] memory balances = new uint256[](2);
        balances[0] = 100e18;  // 100 tokenA available
        balances[1] = 100e18;  // 100 tokenB available

        // Build program with NFT gate check, balance setup, and limit swap
        Program memory p = ProgramBuilder.init(_opcodes());
        bytes memory programBytes = bytes.concat(
            p.build(Controls._onlyTakerTokenBalanceNonZero, ControlsArgsBuilder.buildTakerTokenBalanceNonZero(address(nftGate))),
            p.build(Balances._staticBalancesXD, BalancesArgsBuilder.build(tokens, balances)),
            p.build(LimitSwap._limitSwap1D, LimitSwapArgsBuilder.build(address(tokenB), address(tokenA)))
        );

        // Create order
        ISwapVM.Order memory order = MakerTraitsLib.build(MakerTraitsLib.Args({
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
            program: programBytes
        }));

        // Sign order
        bytes32 orderHash = swapVM.hash(order);
        bytes memory signature = _signOrder(orderHash, makerPrivateKey);

        // Create taker data
        bytes memory takerData = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            threshold: abi.encodePacked(uint256(50e18)),
            to: address(0),
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

        // Execute swap - should succeed because taker has the NFT
        vm.prank(taker);
        (uint256 amountIn, uint256 amountOut, ) = swapVM.swap(
            order,
            address(tokenB), // tokenIn
            address(tokenA), // tokenOut
            50e18,           // amount
            takerData
        );

        // Verify swap succeeded
        assertEq(amountIn, 50e18, "Incorrect amountIn");
        assertEq(amountOut, 50e18, "Incorrect amountOut");

        // Verify token balances
        assertEq(tokenA.balanceOf(maker), 1000e18 - 50e18, "Maker should have sent 50 tokenA");
        assertEq(tokenB.balanceOf(maker), 50e18, "Maker should have received 50 tokenB");
        assertEq(tokenA.balanceOf(taker), 50e18, "Taker should have received 50 tokenA");
        assertEq(tokenB.balanceOf(taker), 1000e18 - 50e18, "Taker should have sent 50 tokenB");

        // Verify NFT balance unchanged
        assertEq(nftGate.balanceOf(taker), 1, "Taker should still have the NFT");
    }

    function test_OnlyTakerTokenBalanceNonZero_Fail() public {
        // DO NOT mint NFT to taker - they should fail the gate check

        // Prepare balances arguments (1:1 swap ratio)
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        uint256[] memory balances = new uint256[](2);
        balances[0] = 100e18;  // 100 tokenA available
        balances[1] = 100e18;  // 100 tokenB available

        // Build program with NFT gate check, balance setup, and limit swap
        Program memory p = ProgramBuilder.init(_opcodes());
        bytes memory programBytes = bytes.concat(
            p.build(Controls._onlyTakerTokenBalanceNonZero, ControlsArgsBuilder.buildTakerTokenBalanceNonZero(address(nftGate))),
            p.build(Balances._staticBalancesXD, BalancesArgsBuilder.build(tokens, balances)),
            p.build(LimitSwap._limitSwap1D, LimitSwapArgsBuilder.build(address(tokenB), address(tokenA)))
        );

        // Create order
        ISwapVM.Order memory order = MakerTraitsLib.build(MakerTraitsLib.Args({
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
            program: programBytes
        }));

        // Sign order
        bytes32 orderHash = swapVM.hash(order);
        bytes memory signature = _signOrder(orderHash, makerPrivateKey);

        // Create taker data
        bytes memory takerData = TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: true,
            shouldUnwrapWeth: false,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            threshold: abi.encodePacked(uint256(50e18)),
            to: address(0),
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

        // Execute swap - should fail because taker doesn't have the NFT
        vm.prank(taker);
        vm.expectRevert(
            abi.encodeWithSelector(
                Controls.TakerTokenBalanceIsZero.selector,
                taker,
                address(nftGate)
            )
        );
        swapVM.swap(
            order,
            address(tokenB), // tokenIn
            address(tokenA), // tokenOut
            50e18,           // amount
            takerData
        );

        // Verify NFT balance is zero
        assertEq(nftGate.balanceOf(taker), 0, "Taker should not have the NFT");

        // Verify no tokens were transferred
        assertEq(tokenA.balanceOf(maker), 1000e18, "Maker should still have all tokenA");
        assertEq(tokenB.balanceOf(maker), 0, "Maker should have no tokenB");
        assertEq(tokenA.balanceOf(taker), 0, "Taker should have no tokenA");
        assertEq(tokenB.balanceOf(taker), 1000e18, "Taker should still have all tokenB");
    }

    function _signOrder(bytes32 orderHash, uint256 privateKey) private pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, orderHash);
        return abi.encodePacked(r, s, v);
    }
}
