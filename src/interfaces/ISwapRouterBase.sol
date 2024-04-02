// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "pancake-v4-core/src/interfaces/IPoolManager.sol";

interface ISwapRouterBase {
    error DeadlineExceeded(uint256, uint256);

    error InvalidSwapType();

    /// @notice throw when output token traders receive less than the expected amount
    error TooLittleReceived();

    /// @notice throw when input token pool requests more than traders allowed amount
    error TooMuchRequested();

    struct PathKey {
        Currency intermediateCurrency;
        uint24 fee;
        IHooks hooks;
        bytes hookData;
        IPoolManager poolManager;
        bytes32 parameters;
    }
}
