// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {PathKey} from "../libraries/PathKey.sol";

/// @title BinQuoter Interface
/// @notice Supports quoting the delta amounts from exact input or exact output swaps.
/// @notice For each pool also tells you the number of initialized ticks loaded and the sqrt price of the pool after the swap.
/// @dev These functions are not marked view because they rely on calling non-view functions and reverting
/// to compute the result. They are also not gas efficient and should not be called on-chain.
interface IBinQuoter {
    error TooLittleReceived();
    error TooMuchRequested();
    error TransactionTooOld();
    error NotSelf();
    error NotVault();
    error InvalidSwapType();

    enum SwapType {
        ExactInput,
        ExactInputSingle,
        ExactOutput,
        ExactOutputSingle
    }

    struct SwapInfo {
        SwapType swapType;
        address msgSender;
        bytes params;
    }

    struct V4BinExactInputSingleParams {
        PoolKey poolKey;
        bool swapForY;
        address recipient;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }

    struct V4BinExactInputParams {
        Currency currencyIn;
        PathKey[] path;
        address recipient;
        uint128 amountIn;
        uint128 amountOutMinimum;
    }

    struct V4BinExactOutputSingleParams {
        PoolKey poolKey;
        bool swapForY;
        address recipient;
        uint128 amountOut;
        uint128 amountInMaximum;
        bytes hookData;
    }

    struct V4BinExactOutputParams {
        Currency currencyOut;
        PathKey[] path;
        address recipient;
        uint128 amountOut;
        uint128 amountInMaximum;
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of another token
    /// @param params The parameters necessary for the swap, encoded as `V4BinExactInputSingleParams` in calldata
    /// @return amountOut The amount of the received token
    function exactInputSingle(V4BinExactInputSingleParams calldata params, uint256 deadline)
        external
        payable
        returns (uint256 amountOut);

    // / @notice Swaps `amountIn` of one token for as much as possible of another along the specified path
    // / @param params The parameters necessary for the multi-hop swap, encoded as `V4BinExactInputParams` in calldata
    // / @return amountOut The amount of the received token
    function exactInput(V4BinExactInputParams calldata params, uint256 deadline)
        external
        payable
        returns (uint256 amountOut);

    /// @notice Swaps as little as possible of one token for `amountOut` of another token
    /// @param params The parameters necessary for the swap, encoded as `ExactOutputSingleParams` in calldata
    /// @return amountIn The amount of the input token
    function exactOutputSingle(V4BinExactOutputSingleParams calldata params, uint256 deadline)
        external
        payable
        returns (uint256 amountIn);

    /// @notice Swaps as little as possible of one token for `amountOut` of another along the specified path (reversed)
    /// @param params The parameters necessary for the multi-hop swap, encoded as `ExactOutputParams` in calldata
    /// @return amountIn The amount of the input token
    function exactOutput(V4BinExactOutputParams calldata params, uint256 deadline)
        external
        payable
        returns (uint256 amountIn);
}