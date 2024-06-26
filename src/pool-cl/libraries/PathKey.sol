//SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.24;

import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "pancake-v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import "pancake-v4-core/src/libraries/SafeCast.sol";

struct PathKey {
    Currency intermediateCurrency;
    uint24 fee;
    int24 tickSpacing;
    IHooks hooks;
    IPoolManager poolManager;
    bytes hookData;
    bytes32 parameters;
}

library PathKeyLib {
    using SafeCast for int24;

    function getPoolAndSwapDirection(PathKey memory params, Currency currencyIn)
        internal
        pure
        returns (PoolKey memory poolKey, bool zeroForOne)
    {
        (Currency currency0, Currency currency1) = currencyIn < params.intermediateCurrency
            ? (currencyIn, params.intermediateCurrency)
            : (params.intermediateCurrency, currencyIn);

        zeroForOne = currencyIn == currency0;
        poolKey = PoolKey(currency0, currency1, params.hooks, params.poolManager, params.fee, params.parameters);
    }
}
