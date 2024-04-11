// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.19;

import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {INonfungiblePositionManager} from "../interfaces/INonfungiblePositionManager.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {INonfungibleTokenPositionDescriptor} from "../interfaces/INonfungibleTokenPositionDescriptor.sol";

library PositionGetter {
    function positions(
        mapping(uint256 tokenId => INonfungiblePositionManager.Position) storage _positions,
        mapping(PoolId pooId => PoolKey) storage _poolIdToPoolKey,
        uint256 tokenId
    )
        external
        view
        returns (
            uint96 nonce,
            Currency currency0,
            Currency currency1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        INonfungiblePositionManager.Position memory position = _positions[tokenId];
        if (PoolId.unwrap(position.poolId) == 0) revert INonfungiblePositionManager.InvalidTokenID();
        PoolKey memory poolKey = _poolIdToPoolKey[position.poolId];
        return (
            position.nonce,
            poolKey.currency0,
            poolKey.currency1,
            poolKey.fee,
            position.tickLower,
            position.tickUpper,
            position.liquidity,
            position.feeGrowthInside0LastX128,
            position.feeGrowthInside1LastX128,
            position.tokensOwed0,
            position.tokensOwed1
        );
    }
}
