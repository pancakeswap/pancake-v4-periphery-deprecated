// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {BaseMigrator, IV3NonfungiblePositionManager} from "../base/BaseMigrator.sol";
import {IBinMigrator, PoolKey} from "./interfaces/IBinMigrator.sol";
import {IBinFungiblePositionManager} from "./interfaces/IBinFungiblePositionManager.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract BinMigrator is IBinMigrator, BaseMigrator {
    IBinFungiblePositionManager public immutable binFungiblePositionManager;

    constructor(address _WETH9, address _binFungiblePositionManager) BaseMigrator(_WETH9) {
        binFungiblePositionManager = IBinFungiblePositionManager(_binFungiblePositionManager);
    }

    function migrateFromV2(
        V2PoolParams calldata v2PoolParams,
        V4BinPoolParams calldata v4MintParams,
        uint256 extraAmount0,
        uint256 extraAmount1
    ) external payable override {
        (uint256 amount0Received, uint256 amount1Received) = withdrawLiquidityFromV2(v2PoolParams);

        /// @notice if user mannually specify the price range, they might need to send extra token
        batchAndNormalizeTokens(
            v4MintParams.poolKey.currency0, v4MintParams.poolKey.currency1, extraAmount0, extraAmount1
        );

        uint256 amount0Input = amount0Received + extraAmount0;
        uint256 amount1Input = amount1Received + extraAmount1;
        IBinFungiblePositionManager.AddLiquidityParams memory addLiquidityParams = IBinFungiblePositionManager
            .AddLiquidityParams({
            poolKey: v4MintParams.poolKey,
            amount0: SafeCast.toUint128(amount0Input),
            amount1: SafeCast.toUint128(amount1Input),
            amount0Min: v4MintParams.amount0Min,
            amount1Min: v4MintParams.amount1Min,
            activeIdDesired: v4MintParams.activeIdDesired,
            idSlippage: v4MintParams.idSlippage,
            deltaIds: v4MintParams.deltaIds,
            distributionX: v4MintParams.distributionX,
            distributionY: v4MintParams.distributionY,
            to: v4MintParams.to,
            deadline: v4MintParams.deadline
        });
        (uint256 amount0Consumed, uint256 amount1Consumed,,) = _addLiquidityToTargetPool(addLiquidityParams);

        // refund if necessary, ETH is supported by CurrencyLib
        unchecked {
            if (amount0Input > amount0Consumed) {
                v4MintParams.poolKey.currency0.transfer(v4MintParams.to, amount0Input - amount0Consumed);
            }
            if (amount1Input > amount1Consumed) {
                v4MintParams.poolKey.currency1.transfer(v4MintParams.to, amount1Input - amount1Consumed);
            }
        }
    }

    function migrateFromV3(
        V3PoolParams calldata v3PoolParams,
        V4BinPoolParams calldata v4MintParams,
        uint256 extraAmount0,
        uint256 extraAmount1
    ) external payable override {
        (uint256 amount0Received, uint256 amount1Received) = withdrawLiquidityFromV3(v3PoolParams);

        /// @notice if user mannually specify the price range, they need to send extra token
        batchAndNormalizeTokens(
            v4MintParams.poolKey.currency0, v4MintParams.poolKey.currency1, extraAmount0, extraAmount1
        );

        uint256 amount0Input = amount0Received + extraAmount0;
        uint256 amount1Input = amount1Received + extraAmount1;
        IBinFungiblePositionManager.AddLiquidityParams memory addLiquidityParams = IBinFungiblePositionManager
            .AddLiquidityParams({
            poolKey: v4MintParams.poolKey,
            amount0: SafeCast.toUint128(amount0Input),
            amount1: SafeCast.toUint128(amount1Input),
            amount0Min: v4MintParams.amount0Min,
            amount1Min: v4MintParams.amount1Min,
            activeIdDesired: v4MintParams.activeIdDesired,
            idSlippage: v4MintParams.idSlippage,
            deltaIds: v4MintParams.deltaIds,
            distributionX: v4MintParams.distributionX,
            distributionY: v4MintParams.distributionY,
            to: v4MintParams.to,
            deadline: v4MintParams.deadline
        });
        (uint256 amount0Consumed, uint256 amount1Consumed,,) = _addLiquidityToTargetPool(addLiquidityParams);

        // refund if necessary, ETH is supported by CurrencyLib
        unchecked {
            if (amount0Input > amount0Consumed) {
                v4MintParams.poolKey.currency0.transfer(v4MintParams.to, amount0Input - amount0Consumed);
            }
            if (amount1Input > amount1Consumed) {
                v4MintParams.poolKey.currency1.transfer(v4MintParams.to, amount1Input - amount1Consumed);
            }
        }
    }

    function _addLiquidityToTargetPool(IBinFungiblePositionManager.AddLiquidityParams memory params)
        internal
        returns (
            uint128 amount0Consumed,
            uint128 amount1Consumed,
            uint256[] memory tokenIds,
            uint256[] memory liquidityMinted
        )
    {
        /// @dev currency1 cant be NATIVE
        bool nativePair = params.poolKey.currency0.isNative();
        if (!nativePair) {
            approveMaxIfNeeded(params.poolKey.currency0, address(binFungiblePositionManager), params.amount0);
        }
        approveMaxIfNeeded(params.poolKey.currency1, address(binFungiblePositionManager), params.amount1);

        (amount0Consumed, amount1Consumed, tokenIds, liquidityMinted) =
            binFungiblePositionManager.addLiquidity{value: nativePair ? params.amount0 : 0}(params);

        // receive surplus ETH from positionManager
        if (nativePair && params.amount0 > amount0Consumed) {
            binFungiblePositionManager.refundETH();
        }
    }

    /// @notice Planned to be batched with migration operations through multicall to save gas
    function initialize(PoolKey memory poolKey, uint24 activeId, bytes calldata hookData) external payable override {
        return binFungiblePositionManager.initialize(poolKey, activeId, hookData);
    }

    receive() external payable {
        if (msg.sender != address(binFungiblePositionManager) && msg.sender != WETH9) {
            revert INVALID_ETHER_SENDER();
        }
    }
}
