// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { IERC20, IWETH } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

import { ISwapVM } from "../../interfaces/ISwapVM.sol";
import { IMakerHooks } from "../../interfaces/IMakerHooks.sol";
import { NativeOrder, NativeOrderEscrow } from "./NativeOrderEscrow.sol";
import { RouterOrderHasher } from "./RouterOrderHasher.sol";

/// @notice Deploys a deterministic WETH escrow for each maker-funded native ETH order.
/// @dev Depositing ETH authenticates the maker; takers use the returned NativeOrder as the ERC-1271
/// signature and submit the same SwapVM order with maker replaced by the escrow address.
/// @custom:security-contact security@1inch.io
contract NativeOrderEscrowFactory is RouterOrderHasher {
    using Clones for address;
    using SafeCast for uint256;

    error NativeOrderZeroDeposit();
    error NativeOrderOnlyMakerCanCreate();
    error NativeOrderAquaNotSupported();
    error NativeOrderExplicitReceiverRequired();
    error NativeOrderExplicitHookTargetRequired();
    error NativeOrderInvalidTokens();
    error NativeOrderInvalidTime();

    event NativeOrderCreated(
        address indexed escrow,
        bytes32 indexed filledOrderHash,
        NativeOrder nativeOrder,
        ISwapVM.Order filledOrder
    );

    IWETH public immutable WETH;
    address public immutable ESCROW_IMPLEMENTATION;
    uint32 public immutable RESCUE_DELAY;

    constructor(ISwapVM router, IWETH weth, IERC20 accessToken, uint32 rescueDelay) RouterOrderHasher(router) {
        WETH = weth;
        RESCUE_DELAY = rescueDelay;
        ESCROW_IMPLEMENTATION = address(new NativeOrderEscrow(router, weth, accessToken));
    }

    /// @param makerOrder Original order, with maker = msg.sender and an explicit receiver and hook targets.
    /// @param expiration Absolute timestamp bounding fills, independently of the program's Deadline.
    /// @param publicCancellation Absolute timestamp at or after expiration when resolver cancellation opens.
    function create(ISwapVM.Order calldata makerOrder, uint40 expiration, uint40 publicCancellation)
        external payable
        returns (address escrow, bytes32 filledOrderHash, NativeOrder memory nativeOrder)
    {
        require(msg.value > 0, NativeOrderZeroDeposit());
        require(makerOrder.maker == msg.sender, NativeOrderOnlyMakerCanCreate());
        require(!makerOrder.traits.useAquaInsteadOfSignature(), NativeOrderAquaNotSupported());
        require(expiration > block.timestamp && publicCancellation >= expiration, NativeOrderInvalidTime());

        (address tokenA, address tokenB) = makerOrder.traits.tokens(makerOrder.data);
        require(
            makerOrder.data.length >= 40 && tokenA < tokenB && (tokenA == address(WETH) || tokenB == address(WETH)),
            NativeOrderInvalidTokens()
        );

        nativeOrder = NativeOrder({
            maker: msg.sender,
            traits: makerOrder.traits,
            dataHash: keccak256(makerOrder.data),
            amount: msg.value,
            expiration: expiration,
            publicCancellation: publicCancellation,
            rescueAfter: (block.timestamp + RESCUE_DELAY).toUint40()
        });
        escrow = ESCROW_IMPLEMENTATION.cloneDeterministic(keccak256(abi.encode(nativeOrder)));
        address receiver = makerOrder.traits.receiver(escrow);
        require(receiver != escrow && receiver != address(this), NativeOrderExplicitReceiverRequired());
        _validateHooks(makerOrder, escrow);
        NativeOrderEscrow(payable(escrow)).depositAndApprove{ value: msg.value }();

        filledOrderHash = _hashOrder(escrow, makerOrder.traits, nativeOrder.dataHash);
        emit NativeOrderCreated(
            escrow, filledOrderHash, nativeOrder,
            ISwapVM.Order({ maker: escrow, traits: makerOrder.traits, data: makerOrder.data })
        );
    }

    function addressOfEscrow(NativeOrder calldata order) external view returns (address) {
        return ESCROW_IMPLEMENTATION.predictDeterministicAddress(keccak256(abi.encode(order)));
    }

    /// @dev An implicit hook would target the escrow after replacing maker, which cannot execute hooks.
    function _validateHooks(ISwapVM.Order calldata order, address escrow) private pure {
        if (order.traits.hasPreTransferInHook()) {
            (IMakerHooks target,) = order.traits.preTransferInHook(escrow, order.data);
            require(address(target) != escrow, NativeOrderExplicitHookTargetRequired());
        }
        if (order.traits.hasPostTransferInHook()) {
            (IMakerHooks target,) = order.traits.postTransferInHook(escrow, order.data);
            require(address(target) != escrow, NativeOrderExplicitHookTargetRequired());
        }
        if (order.traits.hasPreTransferOutHook()) {
            (IMakerHooks target,) = order.traits.preTransferOutHook(escrow, order.data);
            require(address(target) != escrow, NativeOrderExplicitHookTargetRequired());
        }
        if (order.traits.hasPostTransferOutHook()) {
            (IMakerHooks target,) = order.traits.postTransferOutHook(escrow, order.data);
            require(address(target) != escrow, NativeOrderExplicitHookTargetRequired());
        }
    }
}
