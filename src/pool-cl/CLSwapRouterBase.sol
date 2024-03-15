// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {CurrencyLibrary, Currency} from "pancake-v4-core/src/types/Currency.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {TickMath} from "pancake-v4-core/src/pool-cl/libraries/TickMath.sol";

import {ICLSwapRouterBase} from "./interfaces/ICLSwapRouterBase.sol";
import {SwapRouterBase} from "../SwapRouterBase.sol";

abstract contract CLSwapRouterBase is SwapRouterBase, ICLSwapRouterBase {
    using CurrencyLibrary for Currency;

    ICLPoolManager public immutable poolManager;

    constructor(ICLPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    function _v4CLSwapExactInputSingle(
        V4CLExactInputSingleParams memory params,
        address msgSender,
        bool settle,
        bool take
    ) internal returns (uint256 amountOut) {
        amountOut = uint128(
            -_swapExactPrivate(
                params.poolKey,
                params.zeroForOne,
                int256(int128(params.amountIn)),
                params.sqrtPriceLimitX96,
                msgSender,
                params.recipient,
                settle,
                take,
                params.hookData
            )
        );
        if (amountOut < params.amountOutMinimum) revert TooLittleReceived();
    }

    struct V4CLExactInputState {
        uint256 pathLength;
        uint128 amountOut;
        PoolKey poolKey;
        bool zeroForOne;
    }

    function _v4CLSwapExactInput(V4CLExactInputParams memory params, address msgSender, bool settle, bool take)
        internal
        returns (uint256)
    {
        unchecked {
            V4CLExactInputState memory state;
            state.pathLength = params.path.length;

            for (uint256 i = 0; i < state.pathLength; i++) {
                (state.poolKey, state.zeroForOne) = _getPoolAndSwapDirection(params.path[i], params.currencyIn);
                state.amountOut = uint128(
                    -_swapExactPrivate(
                        state.poolKey,
                        state.zeroForOne,
                        int256(int128(params.amountIn)),
                        0,
                        msgSender,
                        params.recipient,
                        i == 0 && settle,
                        i == state.pathLength - 1 && take,
                        params.path[i].hookData
                    )
                );

                params.amountIn = state.amountOut;
                params.currencyIn = params.path[i].intermediateCurrency;
            }

            if (state.amountOut < params.amountOutMinimum) revert TooLittleReceived();

            return state.amountOut;
        }
    }

    function _v4CLSwapExactOutputSingle(
        V4CLExactOutputSingleParams memory params,
        address msgSender,
        bool settle,
        bool take
    ) internal returns (uint256 amountIn) {
        amountIn = uint128(
            _swapExactPrivate(
                params.poolKey,
                params.zeroForOne,
                -int256(int128(params.amountOut)),
                params.sqrtPriceLimitX96,
                msgSender,
                params.recipient,
                settle,
                take,
                params.hookData
            )
        );
        if (amountIn > params.amountInMaximum) revert TooMuchRequested();
    }

    struct V4CLExactOutputState {
        uint256 pathLength;
        uint128 amountIn;
        PoolKey poolKey;
        bool oneForZero;
    }

    function _v4CLSwapExactOutput(V4CLExactOutputParams memory params, address msgSender, bool settle, bool take)
        internal
        returns (uint256)
    {
        unchecked {
            V4CLExactOutputState memory state;
            state.pathLength = params.path.length;

            for (uint256 i = state.pathLength; i > 0; i--) {
                (state.poolKey, state.oneForZero) = _getPoolAndSwapDirection(params.path[i - 1], params.currencyOut);
                state.amountIn = uint128(
                    _swapExactPrivate(
                        state.poolKey,
                        !state.oneForZero,
                        -int256(int128(params.amountOut)),
                        0,
                        msgSender,
                        params.recipient,
                        i == 1 && settle,
                        i == state.pathLength && take,
                        params.path[i - 1].hookData
                    )
                );

                params.amountOut = state.amountIn;
                params.currencyOut = params.path[i - 1].intermediateCurrency;
            }
            if (state.amountIn > params.amountInMaximum) revert TooMuchRequested();

            return state.amountIn;
        }
    }

    function _swapExactPrivate(
        PoolKey memory poolKey,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        address msgSender,
        address recipient,
        bool settle,
        bool take,
        bytes memory hookData
    ) private returns (int128 reciprocalAmount) {
        BalanceDelta delta = poolManager.swap(
            poolKey,
            ICLPoolManager.SwapParams(
                zeroForOne,
                amountSpecified,
                sqrtPriceLimitX96 == 0
                    ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                    : sqrtPriceLimitX96
            ),
            hookData
        );

        if (zeroForOne) {
            reciprocalAmount = amountSpecified > 0 ? delta.amount1() : delta.amount0();
            if (settle) _payAndSettle(poolKey.currency0, msgSender, delta.amount0());
            if (take) vault.take(poolKey.currency1, recipient, uint128(-delta.amount1()));
        } else {
            reciprocalAmount = amountSpecified > 0 ? delta.amount0() : delta.amount1();
            if (settle) _payAndSettle(poolKey.currency1, msgSender, delta.amount1());
            if (take) vault.take(poolKey.currency0, recipient, uint128(-delta.amount0()));
        }
    }
}
