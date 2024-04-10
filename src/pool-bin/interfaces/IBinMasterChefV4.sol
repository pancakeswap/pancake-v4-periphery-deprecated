// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.0;

import {PoolId} from "pancake-v4-core/src/types/PoolId.sol";

interface IBinMasterChefV4 {
    /// @notice If pool has farming incentives, update user's farming details for the pool
    /// @dev Called by BinFungiblePositionManager at the end of deposit
    function onDeposit(PoolId id, address user, uint256[] memory binIds, uint256[] memory amounts) external;

    /// @notice If pool has farming incentives, update user's farming details for the pool
    /// @dev Called by BinFungiblePositionManager at the end of withdrawal
    function onWithdraw(PoolId id, address user, uint256[] memory binIds, uint256[] memory amounts) external;

    /// @dev Called by BinFungiblePositionManager after token transfer
    function onAfterTokenTransfer(PoolId id, address from, address to, uint256 binId, uint256 amount) external;
}
