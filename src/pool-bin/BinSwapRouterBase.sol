// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {BalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {SwapRouterBase} from "../SwapRouterBase.sol";
import {IBinSwapRouterBase} from "./interfaces/IBinSwapRouterBase.sol";

abstract contract BinSwapRouterBase is SwapRouterBase, IBinSwapRouterBase {
    using CurrencyLibrary for Currency;

    IBinPoolManager public immutable binPoolManager;

    constructor(IBinPoolManager _binPoolManager) {
        binPoolManager = _binPoolManager;
    }

    /// @notice Perform a swap with `amountIn` in and ensure at least `amountOutMinimum` out
    function _v4BinSwapExactInputSingle(
        V4BinExactInputSingleParams memory params,
        V4SettlementParams memory settlementParams
    ) internal returns (uint256 amountOut) {
        amountOut = uint256(
            _swapExactPrivate(
                params.poolKey,
                params.swapForY,
                settlementParams.payer,
                params.recipient,
                params.amountIn,
                settlementParams.settle,
                settlementParams.take,
                params.hookData
            )
        );

        if (amountOut < params.amountOutMinimum) revert TooLittleReceived();
    }

    struct V4BinExactInputState {
        uint256 pathLength;
        PoolKey poolKey;
        bool swapForY;
        uint128 amountOut;
    }

    /// @notice Perform a swap with `amountIn` in and ensure at least `amountOutMinimum` out
    function _v4BinSwapExactInput(V4BinExactInputParams memory params, V4SettlementParams memory settlementParams)
        internal
        returns (uint256 amountOut)
    {
        V4BinExactInputState memory state;
        state.pathLength = params.path.length;

        for (uint256 i = 0; i < state.pathLength;) {
            (state.poolKey, state.swapForY) = _getPoolAndSwapDirection(params.path[i], params.currencyIn);

            state.amountOut = _swapExactPrivate(
                state.poolKey,
                state.swapForY,
                settlementParams.payer,
                params.recipient,
                params.amountIn,
                i == 0 && settlementParams.settle, // only settle at first iteration AND settle = true
                i == state.pathLength - 1 && settlementParams.take, // only take at last iteration AND take = true
                params.path[i].hookData
            );

            params.amountIn = state.amountOut;
            params.currencyIn = params.path[i].intermediateCurrency;

            unchecked {
                ++i;
            }
        }

        if (state.amountOut < params.amountOutMinimum) revert TooLittleReceived();
        return uint256(state.amountOut);
    }

    /// @notice Perform a swap that ensure at least `amountOut` tokens with `amountInMaximum` tokens
    function _v4BinSwapExactOutputSingle(
        V4BinExactOutputSingleParams memory params,
        V4SettlementParams memory settlementParams
    ) internal returns (uint256 amountIn) {
        (uint128 amtIn,,) = binPoolManager.getSwapIn(params.poolKey, params.swapForY, params.amountOut);

        if (amtIn > params.amountInMaximum) revert TooMuchRequested();

        uint128 amountOutReal = _swapExactPrivate(
            params.poolKey,
            params.swapForY,
            settlementParams.payer,
            params.recipient,
            amtIn,
            settlementParams.settle,
            settlementParams.take,
            params.hookData
        );

        if (amountOutReal < params.amountOut) revert TooLittleReceived();

        amountIn = uint256(amtIn);
    }

    struct V4BinExactOutputState {
        uint256 pathLength;
        PoolKey poolKey;
        bool swapForY;
        uint128 amountIn;
        uint128 amountOut;
    }

    /// @notice Perform a swap that ensure at least `amountOut` tokens with `amountInMaximum` tokens
    function _v4BinSwapExactOutput(V4BinExactOutputParams memory params, V4SettlementParams memory settlementParams)
        internal
        returns (uint256 amountIn)
    {
        V4BinExactOutputState memory state;
        state.pathLength = params.path.length;

        /// @dev Iterate backward from last path to first path
        for (uint256 i = state.pathLength; i > 0;) {
            // Step 1: Find out poolKey and how much amountIn required to get amountOut
            (state.poolKey, state.swapForY) = _getPoolAndSwapDirection(params.path[i - 1], params.currencyOut);
            (state.amountIn,,) = binPoolManager.getSwapIn(state.poolKey, state.swapForY, params.amountOut);

            // Step 2: Perform the swap, will revert if user do not give approval or not enough amountIn balance
            state.amountOut = _swapExactPrivate(
                state.poolKey,
                !state.swapForY,
                settlementParams.payer,
                params.recipient,
                state.amountIn,
                i == 1 && settlementParams.settle, // only settle at first swap AND settle = true
                i == state.pathLength && settlementParams.take, // only take at last iteration AND take = true
                params.path[i - 1].hookData
            );

            /// @dev only check amountOut for the last path since thats what the user cares
            if (i == state.pathLength) {
                if (state.amountOut < params.amountOut) revert TooLittleReceived();
            }

            params.amountOut = state.amountIn;
            params.currencyOut = params.path[i - 1].intermediateCurrency;

            unchecked {
                --i;
            }
        }

        if (state.amountIn > params.amountInMaximum) revert TooMuchRequested();
        amountIn = uint256(state.amountIn);
    }

    function _swapExactPrivate(
        PoolKey memory poolKey,
        bool swapForY,
        address payer,
        address recipient,
        uint128 amountIn,
        bool settle,
        bool take,
        bytes memory hookData
    ) private returns (uint128 amountOut) {
        BalanceDelta delta = binPoolManager.swap(poolKey, swapForY, amountIn, hookData);

        if (swapForY) {
            if (settle) _payAndSettle(poolKey.currency0, payer, -delta.amount0());
            if (take) vault.take(poolKey.currency1, recipient, uint128(delta.amount1()));
        } else {
            if (settle) _payAndSettle(poolKey.currency1, payer, -delta.amount1());
            if (take) vault.take(poolKey.currency0, recipient, uint128(delta.amount0()));
        }

        amountOut = swapForY ? uint128(delta.amount1()) : uint128(delta.amount0());
    }
}
