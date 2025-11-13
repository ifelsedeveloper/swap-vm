// SPDX-License-Identifier: LicenseRef-Degensoft-ARSL-1.0-Audit

pragma solidity ^0.8.0;

import { MakerTraits } from "../libs/MakerTraits.sol";

interface ISwapVM {
    struct Order {
        address maker;
        MakerTraits traits;
        bytes data;
    }

    /// @dev EIP-712 typed data hash of the off-chain signed order
    ///      or keccak256(abi.encode(order)) for Aqua shipped strategy.
    function hash(Order calldata order) external view returns (bytes32);

    function quote(
        Order calldata order,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes calldata takerTraitsAndData
    ) external view returns (uint256 amountIn, uint256 amountOut, bytes32 orderHash);

    function swap(
        Order calldata order,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bytes calldata takerTraitsAndData
    ) external returns (uint256 amountIn, uint256 amountOut, bytes32 orderHash);
}
