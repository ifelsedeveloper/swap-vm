// SPDX-License-Identifier: LicenseRef-Degensoft-SwapVM-1.1
pragma solidity ^0.8.27;

/// @custom:license-url https://github.com/1inch/swap-vm/blob/main/LICENSES/SwapVM-1.1.txt
/// @custom:copyright © 2026 Degensoft Ltd

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { SafeERC20, IERC20, IWETH } from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";
import { OnlyWethReceiver } from "@1inch/solidity-utils/contracts/mixins/OnlyWethReceiver.sol";

import { ISwapVM } from "../../interfaces/ISwapVM.sol";
import { MakerTraits } from "../../libs/MakerTraits.sol";
import { InvalidateTokenOutExternal } from "../../instructions/Invalidators.sol";
import { RouterOrderHasher } from "./RouterOrderHasher.sol";

/// @notice Terms committed in the escrow's CREATE2 address; all times are absolute Unix timestamps.
/// @dev Does not contain an EIP-712 hash, so authentication for refunds survives chain ID changes.
struct NativeOrder {
    address maker;
    MakerTraits traits;
    bytes32 dataHash;
    uint256 amount;
    uint40 expiration;
    uint40 publicCancellation;
    uint40 rescueAfter;
}

/// @notice Holds a single native ETH sell order as WETH, without changing the SwapVM router.
/// @dev The exact WETH allowance is also the order's lifecycle state: fills consume it and cancellation
/// permanently zeros it. Only the factory can approve, once when deploying the clone.
/// @custom:security-contact security@1inch.io
contract NativeOrderEscrow is OnlyWethReceiver, RouterOrderHasher, IERC1271 {
    using Clones for address;
    using SafeERC20 for IERC20;
    using SafeERC20 for IWETH;

    error InvalidCaller();
    error InvalidOrder();
    error InvalidTime();
    error OrderClosed();
    error NativeTokenSendingFailure();

    event NativeOrderCancelled(bytes32 indexed orderHash, uint256 refund, uint256 reward);
    event FundsRescued(address indexed token, uint256 amount);

    /// @dev Public cancellation reward: base fee * gas budget * 110%, capped by rewardLimit and WETH left.
    uint256 private constant _PUBLIC_CANCEL_GAS_COST = 120_000;

    address public immutable FACTORY = msg.sender;
    IWETH public immutable WETH;
    address private immutable _IMPLEMENTATION = address(this);
    IERC20 private immutable _ACCESS_TOKEN;

    constructor(ISwapVM router, IWETH weth, IERC20 accessToken)
        OnlyWethReceiver(address(weth))
        RouterOrderHasher(router)
    {
        WETH = weth;
        _ACCESS_TOKEN = accessToken;
    }

    modifier onlyMaker(NativeOrder calldata order) {
        require(msg.sender == order.maker, InvalidCaller());
        _validateOrder(order);
        _;
    }

    /// @notice Wraps the initial deposit and approves exactly that amount for the router.
    function depositAndApprove() external payable {
        require(msg.sender == FACTORY, InvalidCaller());
        WETH.safeDeposit(msg.value);
        WETH.forceApprove(address(ROUTER), msg.value);
    }

    /// @notice The signature is abi.encode(NativeOrder); the program is supplied only once, to the router.
    function isValidSignature(bytes32 orderHash, bytes calldata signature) external view returns (bytes4) {
        if (signature.length != 7 * 32) return bytes4(0);
        NativeOrder memory order = abi.decode(signature, (NativeOrder));
        if (
            !_isValidOrder(order) || block.timestamp >= order.expiration ||
            _hashOrder(address(this), order.traits, order.dataHash) != orderHash ||
            WETH.allowance(address(this), address(ROUTER)) == 0
        ) return bytes4(0);
        return IERC1271.isValidSignature.selector;
    }

    /// @notice Permanently closes the order and returns all remaining WETH and forced ETH as native ETH.
    /// @dev May also sweep donations after a full fill or an earlier cancellation. No resolver reward.
    function cancel(NativeOrder calldata order) external onlyMaker(order) {
        _cancel(order, 0);
    }

    /// @notice An access-token holder may close an expired, abandoned order for a capped reward.
    /// @dev Fully filled or already cancelled orders cannot earn another reward. Forced ETH is refunded
    /// entirely to the maker and never increases the reward budget.
    function publicCancel(NativeOrder calldata order, uint256 rewardLimit) external {
        _validateOrder(order);
        require(block.timestamp >= order.publicCancellation, InvalidTime());
        require(_ACCESS_TOKEN.balanceOf(msg.sender) > 0, InvalidCaller());
        uint256 allowance = WETH.allowance(address(this), address(ROUTER));
        require(allowance > 0, OrderClosed());
        uint256 reward = Math.min(
            Math.min(rewardLimit, Math.min(allowance, WETH.balanceOf(address(this)))),
            block.basefee * _PUBLIC_CANCEL_GAS_COST * 110 / 100
        );
        _cancel(order, reward);
    }

    /// @notice Recovers stray tokens after the factory's rescue delay; zero token means native ETH.
    /// @dev Rescuing WETH also closes the order, so replacement WETH cannot revive it.
    function rescueFunds(NativeOrder calldata order, address token, uint256 amount) external onlyMaker(order) {
        require(block.timestamp >= order.rescueAfter, InvalidTime());
        if (token == address(WETH)) _closeOrder(order);
        if (token == address(0)) _ethTransfer(order.maker, amount);
        else IERC20(token).safeTransfer(order.maker, amount);
        emit FundsRescued(token, amount);
    }

    function _cancel(NativeOrder calldata order, uint256 reward) private {
        bytes32 orderHash = _closeOrder(order);
        WETH.safeWithdraw(WETH.balanceOf(address(this)));
        // Pay the reward first, so a maker callback cannot rescue the resolver's reserved ETH.
        _ethTransfer(msg.sender, reward);
        uint256 refund = address(this).balance;
        _ethTransfer(order.maker, refund);
        emit NativeOrderCancelled(orderHash, refund, reward);
    }

    function _closeOrder(NativeOrder calldata order) private returns (bytes32 orderHash) {
        WETH.forceApprove(address(ROUTER), 0);
        orderHash = _hashOrder(address(this), order.traits, order.dataHash);
        // Makes quotes using InvalidateTokenOut reflect cancellation as well.
        InvalidateTokenOutExternal(address(ROUTER)).invalidateTokenOut(orderHash, address(WETH));
    }

    function _validateOrder(NativeOrder memory order) private view {
        require(_isValidOrder(order), InvalidOrder());
    }

    function _isValidOrder(NativeOrder memory order) private view returns (bool) {
        return _IMPLEMENTATION.predictDeterministicAddress(keccak256(abi.encode(order)), FACTORY) == address(this);
    }

    function _ethTransfer(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool success,) = to.call{ value: amount }("");
        require(success, NativeTokenSendingFailure());
    }
}
