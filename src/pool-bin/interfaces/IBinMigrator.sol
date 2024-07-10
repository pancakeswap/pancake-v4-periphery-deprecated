// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {IBaseMigrator} from "../../interfaces/IBaseMigrator.sol";
import {IV3NonfungiblePositionManager} from "../../interfaces/external/IV3NonfungiblePositionManager.sol";

interface IBinMigrator is IBaseMigrator {
    /// @notice same fields as IBinFungiblePositionManager.AddLiquidityParams
    /// except amount0/amount1 which will be calculated by migrator
    struct V4BinPoolParams {
        PoolKey poolKey;
        // uint128 amount0;
        // uint128 amount1;
        uint128 amount0Min;
        uint128 amount1Min;
        uint256 activeIdDesired;
        uint256 idSlippage;
        int256[] deltaIds;
        uint256[] distributionX;
        uint256[] distributionY;
        address to;
        uint256 deadline;
    }

    function migrateFromV2(
        V2PoolParams calldata v2PoolParams,
        V4BinPoolParams calldata v4PoolParams,
        // extra funds to be added
        uint256 extraAmount0,
        uint256 extraAmount1
    ) external payable;

    function migrateFromV3(
        V3PoolParams calldata v3PoolParams,
        V4BinPoolParams calldata v4PoolParams,
        // extra funds to be added
        uint256 extraAmount0,
        uint256 extraAmount1
    ) external payable;

    /// @notice Initialize a new pool
    /// @dev Call this when the pool does not exist and is not initialized
    /// @param poolKey The pool key
    /// @param activeId The active id of the pool
    /// @param hookData Hook data for the pool
    function initialize(PoolKey memory poolKey, uint24 activeId, bytes calldata hookData) external payable;
}
