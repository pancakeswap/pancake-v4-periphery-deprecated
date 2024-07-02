// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {IBaseMigrator} from "../../interfaces/IBaseMigrator.sol";
import {IV3NonfungiblePositionManager} from "../../interfaces/external/IV3NonfungiblePositionManager.sol";
import {INonfungiblePositionManager} from "./INonfungiblePositionManager.sol";

interface ICLMigrator is IBaseMigrator {
    function migrateFromV2(
        V2PoolParams calldata v2PoolParams,
        // exact target v4#clpool mintParams
        INonfungiblePositionManager.MintParams calldata v4MintParams,
        // extra funds to be added
        uint256 extraAmount0,
        uint256 extraAmount1
    ) external payable;

    function migrateFromV3(
        V3PoolParams calldata v3PoolParams,
        // exact target v4#clpool mintParams
        INonfungiblePositionManager.MintParams calldata v4MintParams,
        // extra funds to be added
        uint256 extraAmount0,
        uint256 extraAmount1
    ) external payable;

    /// @notice Initialize the pool state for a given pool ID.
    /// @dev Call this when the pool does not exist and is not initialized.
    /// @param poolKey The pool key
    /// @param sqrtPriceX96 The initial sqrt price of the pool
    /// @param hookData Hook data for the pool
    /// @return tick Pool tick
    function initialize(PoolKey memory poolKey, uint160 sqrtPriceX96, bytes calldata hookData)
        external
        payable
        returns (int24 tick);
}
