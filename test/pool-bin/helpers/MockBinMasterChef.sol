// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {PoolId} from "pancake-v4-core/src/types/PoolId.sol";
import {IBinMasterChefV4} from "../../../src/pool-bin/interfaces/IBinMasterChefV4.sol";

contract MockBinMasterChef is IBinMasterChefV4 {
    event OnDeposit(PoolId id, address user, uint256[] binIds, uint256[] amounts);
    event OnWithdraw(PoolId id, address user, uint256[] binIds, uint256[] amounts);
    event OnAfterTokenTransfer(PoolId id, address from, address to, uint256 binId, uint256 amount);

    function onDeposit(PoolId id, address user, uint256[] memory binIds, uint256[] memory amounts) external override {
        emit OnDeposit(id, user, binIds, amounts);
    }

    function onWithdraw(PoolId id, address user, uint256[] memory binIds, uint256[] memory amounts) external override {
        emit OnWithdraw(id, user, binIds, amounts);
    }

    function onAfterTokenTransfer(PoolId id, address from, address to, uint256 binId, uint256 amount)
        external
        override
    {
        emit OnAfterTokenTransfer(id, from, to, binId, amount);
    }
}
