// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.24;

import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {ILockCallback} from "pancake-v4-core/src/interfaces/ILockCallback.sol";
import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "pancake-v4-core/src/interfaces/IPoolManager.sol";

/// @title IQuoter Interface
/// @notice Supports quoting the delta amounts from exact input or exact output swaps.
/// @dev These functions are not marked view because they rely on calling non-view functions and reverting
/// to compute the result. They are also not gas efficient and should not be called on-chain.
interface IQuoter is ILockCallback {
    error InvalidLockAcquiredSender();
    error InsufficientAmountOut();
    error LockFailure();
    error NotSelf();
    error UnexpectedRevertBytes(bytes revertData);

    struct PathKey {
        Currency intermediateCurrency;
        uint24 fee;
        IHooks hooks;
        IPoolManager poolManager;
        bytes hookData;
        bytes32 parameters;
    }

    struct QuoteExactParams {
        Currency exactCurrency;
        PathKey[] path;
        uint128 exactAmount;
    }

    function _quoteExactInput(QuoteExactParams memory params) external returns (bytes memory);

    function _quoteExactOutput(QuoteExactParams memory params) external returns (bytes memory);
}
