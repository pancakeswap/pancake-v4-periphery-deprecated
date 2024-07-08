// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {IPeripheryImmutableState} from "./IPeripheryImmutableState.sol";
import {IMulticall} from "./IMulticall.sol";
import {ISelfPermit} from "./ISelfPermit.sol";

interface IBaseMigrator is IPeripheryImmutableState, IMulticall, ISelfPermit {
    event MoreFundsAdded(address currency0, address currency1, uint256 extraAmount0, uint256 extraAmount1);

    struct V2PoolParams {
        // the PancakeSwap v2-compatible pair
        address pair;
        // the amount of v2 lp token to be withdrawn
        uint256 migrateAmount;
        // the amount of token0 and token1 to be received after burning must be no less than these
        uint256 amount0Min;
        uint256 amount1Min;
    }

    struct V3PoolParams {
        // the PancakeSwap v3-compatible NFP
        address nfp;
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        // decide whether to collect fee
        bool collectFee;
    }
}
