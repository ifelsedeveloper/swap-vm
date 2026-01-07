// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity 0.8.30;

import { Test } from "forge-std/Test.sol";
import { TokenMock } from "@1inch/solidity-utils/contracts/mocks/TokenMock.sol";
import { Aqua } from "@1inch/aqua/src/Aqua.sol";

import { dynamic } from "./utils/Dynamic.sol";

import { ISwapVM } from "../src/interfaces/ISwapVM.sol";
import { SwapVMRouter } from "../src/routers/SwapVMRouter.sol";
import { MakerTraitsLib } from "../src/libs/MakerTraits.sol";
import { TakerTraitsLib } from "../src/libs/TakerTraits.sol";
import { OpcodesDebug } from "../src/opcodes/OpcodesDebug.sol";
import { Balances, BalancesArgsBuilder } from "../src/instructions/Balances.sol";
import { XYCSwap } from "../src/instructions/XYCSwap.sol";

import { Program, ProgramBuilder } from "./utils/ProgramBuilder.sol";
import { WETHMock } from "./mocks/WETHMock.sol";

contract UnwrapWethTest is Test, OpcodesDebug {
    using ProgramBuilder for Program;

    constructor() OpcodesDebug(address(new Aqua())) {}

    SwapVMRouter public swapVM;
    WETHMock public weth;
    TokenMock public tokenB;

    address public maker;
    uint256 public makerPrivateKey;
    address public taker = makeAddr("taker");

    function setUp() public {
        makerPrivateKey = 0x1234;
        maker = vm.addr(makerPrivateKey);

        swapVM = new SwapVMRouter(address(0), "SwapVM", "1.0.0");
        weth = new WETHMock();
        tokenB = new TokenMock("Token B", "TKB");

        tokenB.mint(maker, 1_000_000e18);
        tokenB.mint(taker, 1_000_000e18);

        vm.prank(maker);
        tokenB.approve(address(swapVM), type(uint256).max);
        vm.prank(maker);
        weth.approve(address(swapVM), type(uint256).max);

        vm.prank(taker);
        tokenB.approve(address(swapVM), type(uint256).max);
        vm.prank(taker);
        weth.approve(address(swapVM), type(uint256).max);
    }

    function _buildOrder(
        bool makerUnwrapWeth,
        address tokenA,
        address tokenC
    ) internal view returns (ISwapVM.Order memory order, bytes memory signature) {
        Program memory program = ProgramBuilder.init(_opcodes());
        bytes memory programBytes = bytes.concat(
            program.build(Balances._dynamicBalancesXD, BalancesArgsBuilder.build(
                dynamic([tokenA, tokenC]),
                dynamic([uint256(1000e18), uint256(1000e18)])
            )),
            program.build(XYCSwap._xycSwapXD)
        );

        order = MakerTraitsLib.build(MakerTraitsLib.Args({
            maker: maker,
            shouldUnwrapWeth: makerUnwrapWeth,
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

        bytes32 orderHash = swapVM.hash(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, orderHash);
        signature = abi.encodePacked(r, s, v);
    }

    function _buildTakerData(bool isExactIn, bool takerUnwrapWeth, bytes memory signature) internal view returns (bytes memory) {
        return TakerTraitsLib.build(TakerTraitsLib.Args({
            taker: taker,
            isExactIn: isExactIn,
            shouldUnwrapWeth: takerUnwrapWeth,
            isStrictThresholdAmount: false,
            isFirstTransferFromTaker: false,
            useTransferFromAndAquaPush: false,
            threshold: "",
            to: taker,
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
    }

    function _prepareWeth(address user, uint256 amount) internal {
        vm.deal(user, amount);
        vm.prank(user);
        weth.deposit{value: amount}();
    }

    function _selectTokens(bool makerUnwrapWeth, bool takerUnwrapWeth) internal view returns (address tokenIn, address tokenOut) {
        tokenIn = makerUnwrapWeth ? address(weth) : address(tokenB);
        tokenOut = takerUnwrapWeth ? address(weth) : address(tokenB);
        if (!makerUnwrapWeth && !takerUnwrapWeth) {
            tokenOut = address(weth);
        }
    }

    function test_MakerShouldUnwrapWeth_SendsEthToMaker() public {
        uint256 amountIn = 10e18;
        _prepareWeth(taker, amountIn);

        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder(true, address(weth), address(tokenB));
        bytes memory takerData = _buildTakerData(true, false, signature);

        vm.deal(maker, 0);
        uint256 makerEthBefore = maker.balance;

        vm.prank(taker);
        swapVM.swap(order, address(weth), address(tokenB), amountIn, takerData);

        assertEq(maker.balance - makerEthBefore, amountIn, "Maker should receive ETH");
        assertEq(weth.balanceOf(maker), 0, "Maker should not receive WETH");
    }

    function test_TakerShouldUnwrapWeth_SendsEthToTaker() public {
        uint256 amountIn = 10e18;
        _prepareWeth(maker, 1000e18);

        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder(false, address(tokenB), address(weth));
        bytes memory takerData = _buildTakerData(true, true, signature);

        vm.deal(taker, 0);
        uint256 takerEthBefore = taker.balance;

        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(order, address(tokenB), address(weth), amountIn, takerData);

        assertEq(taker.balance - takerEthBefore, amountOut, "Taker should receive ETH");
        assertEq(weth.balanceOf(taker), 0, "Taker should not receive WETH");
    }

    function test_UnwrapWeth_Flags(bool makerUnwrapWeth, bool takerUnwrapWeth, uint128 rawAmountIn) public {
        vm.assume(!(makerUnwrapWeth && takerUnwrapWeth));
        uint256 amountIn = bound(uint256(rawAmountIn), 1e6, 100e18);

        (address tokenIn, address tokenOut) = _selectTokens(makerUnwrapWeth, takerUnwrapWeth);
        vm.assume(tokenIn != tokenOut);

        if (tokenIn == address(weth)) {
            _prepareWeth(taker, amountIn);
        } else {
            vm.deal(taker, 0);
        }

        if (tokenOut == address(weth)) {
            _prepareWeth(maker, 1000e18);
        } else {
            vm.deal(maker, 0);
        }

        (ISwapVM.Order memory order, bytes memory signature) = _buildOrder(makerUnwrapWeth, tokenIn, tokenOut);
        bytes memory takerData = _buildTakerData(true, takerUnwrapWeth, signature);

        uint256 makerEthBefore = maker.balance;
        uint256 takerEthBefore = taker.balance;
        uint256 makerWethBefore = weth.balanceOf(maker);
        uint256 takerWethBefore = weth.balanceOf(taker);

        vm.prank(taker);
        (, uint256 amountOut,) = swapVM.swap(order, tokenIn, tokenOut, amountIn, takerData);

        if (makerUnwrapWeth) {
            assertEq(maker.balance - makerEthBefore, amountIn, "Maker should receive ETH");
            assertEq(weth.balanceOf(maker), makerWethBefore, "Maker WETH should not increase");
        } else {
            assertEq(maker.balance - makerEthBefore, 0, "Maker should not receive ETH");
        }

        if (tokenIn == address(weth)) {
            assertEq(takerWethBefore - weth.balanceOf(taker), amountIn, "Taker should spend WETH");
        }

        if (takerUnwrapWeth) {
            assertEq(taker.balance - takerEthBefore, amountOut, "Taker should receive ETH");
            assertEq(weth.balanceOf(taker), takerWethBefore, "Taker WETH should not increase");
        } else if (tokenOut == address(weth)) {
            assertEq(weth.balanceOf(taker) - takerWethBefore, amountOut, "Taker should receive WETH");
            assertEq(taker.balance - takerEthBefore, 0, "Taker should not receive ETH");
        } else {
            assertEq(taker.balance - takerEthBefore, 0, "Taker should not receive ETH");
        }
    }
}
