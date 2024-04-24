// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {IPeripheryImmutableState} from "../interfaces/IPeripheryImmutableState.sol";
import {IAllowanceTransfer} from "../interfaces/IAllowanceTransfer.sol";

abstract contract PeripheryImmutableState is IPeripheryImmutableState {
    address public immutable WETH9;
    IAllowanceTransfer public immutable PERMIT2;

    constructor(address _WETH9, address _PERMIT2) {
        WETH9 = _WETH9;
        PERMIT2 = IAllowanceTransfer(_PERMIT2);
    }
}
