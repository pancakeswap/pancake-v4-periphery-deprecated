// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {BalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {ILockCallback} from "pancake-v4-core/src/interfaces/ILockCallback.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {SafeCast} from "pancake-v4-core/src/pool-bin/libraries/math/SafeCast.sol";
import {IBinQuoter} from "../interfaces/IBinQuoter.sol";
import {PathKey, PathKeyLib} from "../libraries/PathKey.sol";

contract BinQuoter is IBinQuoter, ILockCallback {
    using CurrencyLibrary for Currency;
    using SafeCast for uint128;
    using PathKeyLib for PathKey;

    IVault public immutable vault;
    IBinPoolManager public immutable binPoolManager;

    /// @dev Only this address may call this function
    modifier selfOnly() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    modifier vaultOnly() {
        if (msg.sender != address(vault)) revert NotVault();
        _;
    }

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert TransactionTooOld();
        _;
    }

    constructor(IVault _vault, IBinPoolManager _binPoolManager) {
        vault = _vault;
        binPoolManager = _binPoolManager;
    }

    function exactInputSingle(V4BinExactInputSingleParams calldata params, uint256 deadline)
        external
        payable
        override
        checkDeadline(deadline)
        returns (uint256 amountOut)
    {
        amountOut = abi.decode(
            vault.lock(abi.encode(SwapInfo(SwapType.ExactInputSingle, msg.sender, abi.encode(params)))), (uint256)
        );
    }

    function exactInput(V4BinExactInputParams calldata params, uint256 deadline)
        external
        payable
        override
        checkDeadline(deadline)
        returns (uint256 amountOut)
    {
        amountOut =
            abi.decode(vault.lock(abi.encode(SwapInfo(SwapType.ExactInput, msg.sender, abi.encode(params)))), (uint256));
    }

    function exactOutputSingle(V4BinExactOutputSingleParams calldata params, uint256 deadline)
        external
        payable
        override
        checkDeadline(deadline)
        returns (uint256 amountIn)
    {
        amountIn = abi.decode(
            vault.lock(abi.encode(SwapInfo(SwapType.ExactOutputSingle, msg.sender, abi.encode(params)))), (uint256)
        );
    }

    function exactOutput(V4BinExactOutputParams calldata params, uint256 deadline)
        external
        payable
        override
        checkDeadline(deadline)
        returns (uint256 amountIn)
    {
        amountIn = abi.decode(
            vault.lock(abi.encode(SwapInfo(SwapType.ExactOutput, msg.sender, abi.encode(params)))), (uint256)
        );
    }

    function lockAcquired(bytes calldata data) external override vaultOnly returns (bytes memory) {
        SwapInfo memory swapInfo = abi.decode(data, (SwapInfo));

        if (swapInfo.swapType == SwapType.ExactInput) {
            return abi.encode(_quoteExactInput(abi.decode(swapInfo.params, (V4BinExactInputParams))));
        } else if (swapInfo.swapType == SwapType.ExactInputSingle) {
            return abi.encode(_quoteExactInputSingle(abi.decode(swapInfo.params, (V4BinExactInputSingleParams))));
        } else if (swapInfo.swapType == SwapType.ExactOutput) {
            return abi.encode(_quoteExactOutput(abi.decode(swapInfo.params, (V4BinExactOutputParams))));
        } else if (swapInfo.swapType == SwapType.ExactOutputSingle) {
            return abi.encode(_quoteExactOutputSingle(abi.decode(swapInfo.params, (V4BinExactOutputSingleParams))));
        } else {
            revert InvalidSwapType();
        }
    }

    /// @dev quote an ExactInput swap on a pool, then revert with the result
    function _quoteExactInputSingle(V4BinExactInputSingleParams memory params) internal returns (uint256 amountOut) {
        amountOut = uint256(_swap(params.poolKey, params.swapForY, -(params.amountIn.safeInt128()), params.hookData));

        if (amountOut < params.amountOutMinimum) revert TooLittleReceived();
    }

    struct V4BinExactInputState {
        uint256 pathLength;
        PoolKey poolKey;
        bool swapForY;
        uint128 amountOut;
    }

    /// @notice Perform a swap with `amountIn` in and ensure at least `amountOutMinimum` out
    function _quoteExactInput(V4BinExactInputParams memory params) internal returns (uint256 amountOut) {
        V4BinExactInputState memory state;
        state.pathLength = params.path.length;

        for (uint256 i = 0; i < state.pathLength; i++) {
            (state.poolKey, state.swapForY) = params.path[i].getPoolAndSwapDirection(params.currencyIn);

            state.amountOut =
                _swap(state.poolKey, state.swapForY, -(params.amountIn.safeInt128()), params.path[i].hookData);

            params.amountIn = state.amountOut;
            params.currencyIn = params.path[i].intermediateCurrency;
        }

        if (state.amountOut < params.amountOutMinimum) revert TooLittleReceived();
        return uint256(state.amountOut);
    }

    /// @notice Perform a swap that ensure at least `amountOut` tokens with `amountInMaximum` tokens
    function _quoteExactOutputSingle(V4BinExactOutputSingleParams memory params) internal returns (uint256 amountIn) {
        amountIn = uint256(_swap(params.poolKey, params.swapForY, params.amountOut.safeInt128(), params.hookData));

        if (amountIn > params.amountInMaximum) revert TooMuchRequested();
    }

    struct V4BinExactOutputState {
        uint256 pathLength;
        PoolKey poolKey;
        bool swapForY;
        uint128 amountIn;
    }

    /// @notice Perform a swap that ensure at least `amountOut` tokens with `amountInMaximum` tokens
    function _quoteExactOutput(V4BinExactOutputParams memory params) internal returns (uint256 amountIn) {
        V4BinExactOutputState memory state;
        state.pathLength = params.path.length;

        /// @dev Iterate backward from last path to first path
        for (uint256 i = state.pathLength; i > 0;) {
            // Step 1: Find out poolKey and how much amountIn required to get amountOut
            (state.poolKey, state.swapForY) = params.path[i - 1].getPoolAndSwapDirection(params.currencyOut);

            state.amountIn =
                _swap(state.poolKey, !state.swapForY, params.amountOut.safeInt128(), params.path[i - 1].hookData);

            params.amountOut = state.amountIn;
            params.currencyOut = params.path[i - 1].intermediateCurrency;

            unchecked {
                --i;
            }
        }

        if (state.amountIn > params.amountInMaximum) revert TooMuchRequested();
        amountIn = uint256(state.amountIn);
    }

    /// @dev Execute a swap and return the amounts delta, as well as relevant pool state
    /// @notice if amountSpecified > 0, the swap is exactInput, otherwise exactOutput
    function _swap(PoolKey memory poolKey, bool swapForY, int128 amountSpecified, bytes memory hookData)
        private
        returns (uint128 reciprocalAmount)
    {
        BalanceDelta delta = binPoolManager.swap(poolKey, swapForY, amountSpecified, hookData);

        if (swapForY) {
            /// @dev amountSpecified < 0 indicate exactInput, so reciprocal token is token1 and positive
            ///      amountSpecified > 0 indicate exactOutput, so reciprocal token is token0 but is negative
            reciprocalAmount = amountSpecified < 0 ? uint128(delta.amount1()) : uint128(-delta.amount0());
        } else {
            reciprocalAmount = amountSpecified < 0 ? uint128(delta.amount0()) : uint128(-delta.amount1());
        }
    }
}
