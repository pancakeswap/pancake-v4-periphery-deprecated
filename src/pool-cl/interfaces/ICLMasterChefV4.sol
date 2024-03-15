// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {INonfungiblePositionManager} from "./INonfungiblePositionManager.sol";

interface ICLMasterChefV4 {
    function onPositionUpdate(
        uint256 tokenId,
        INonfungiblePositionManager.Position calldata positionTokenInfo,
        address owner
    ) external;
}
