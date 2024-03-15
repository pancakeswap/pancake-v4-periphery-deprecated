// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {PoolId} from "pancake-v4-core/src/types/PoolId.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";

import {ICLMasterChefV4} from "../../../src/pool-cl/interfaces/ICLMasterChefV4.sol";
import {INonfungiblePositionManager} from "../../../src/pool-cl/interfaces/INonfungiblePositionManager.sol";

contract MockCLMasterChef is ICLMasterChefV4 {
    uint256 public counter = 0;

    function onPositionUpdate(
        uint256 tokenId,
        INonfungiblePositionManager.Position calldata positionTokenInfo,
        address owner
    ) external {
        counter++;

        require(INonfungiblePositionManager(msg.sender).ownerOf(tokenId) == owner);

        // compare each field
        (
            uint96 nonce,
            address operator,
            ,
            ,
            ,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = INonfungiblePositionManager(msg.sender).positions(tokenId);

        require(nonce == positionTokenInfo.nonce);
        require(operator == positionTokenInfo.operator);
        require(tickLower == positionTokenInfo.tickLower);
        require(tickUpper == positionTokenInfo.tickUpper);
        require(liquidity == positionTokenInfo.liquidity);
        require(feeGrowthInside0LastX128 == positionTokenInfo.feeGrowthInside0LastX128);
        require(feeGrowthInside1LastX128 == positionTokenInfo.feeGrowthInside1LastX128);
        require(tokensOwed0 == positionTokenInfo.tokensOwed0);
        require(tokensOwed1 == positionTokenInfo.tokensOwed1);
    }
}
