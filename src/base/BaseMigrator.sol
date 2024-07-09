// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeTransferLib, ERC20} from "solmate/utils/SafeTransferLib.sol";
import {IPancakePair} from "../interfaces/external/IPancakePair.sol";
import {IV3NonfungiblePositionManager} from "../interfaces/external/IV3NonfungiblePositionManager.sol";
import {IWETH9} from "../interfaces/external/IWETH9.sol";
import {PeripheryImmutableState} from "./PeripheryImmutableState.sol";
import {Multicall} from "./Multicall.sol";
import {SelfPermit} from "./SelfPermit.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {IBaseMigrator} from "../interfaces/IBaseMigrator.sol";

contract BaseMigrator is IBaseMigrator, PeripheryImmutableState, Multicall, SelfPermit {
    constructor(address _WETH9) PeripheryImmutableState(_WETH9) {}

    function withdrawLiquidityFromV2(V2PoolParams calldata v2PoolParams)
        internal
        returns (uint256 amount0Received, uint256 amount1Received)
    {
        // burn v2 liquidity to this address
        IPancakePair(v2PoolParams.pair).transferFrom(msg.sender, v2PoolParams.pair, v2PoolParams.migrateAmount);
        (amount0Received, amount1Received) = IPancakePair(v2PoolParams.pair).burn(address(this));

        // same price slippage check as v3
        if (amount0Received < v2PoolParams.amount0Min || amount1Received < v2PoolParams.amount1Min) {
            revert INSUFFICIENT_AMOUNTS_RECEIVED();
        }

        /// @notice the order may mismatch with v4 pool when WETH is invovled
        /// the following check makes sure that the output always match the order of v4 pool
        if (IPancakePair(v2PoolParams.pair).token1() == WETH9) {
            (amount0Received, amount1Received) = (amount1Received, amount0Received);
        }
    }

    function withdrawLiquidityFromV3(V3PoolParams calldata v3PoolParams)
        internal
        returns (uint256 amount0Received, uint256 amount1Received)
    {
        IV3NonfungiblePositionManager nfp = IV3NonfungiblePositionManager(v3PoolParams.nfp);
        uint256 tokenId = v3PoolParams.tokenId;
        ///@dev make sure the caller is the owner of the token
        /// otherwise once the token is approved to migrator, anyone can steal money through this function
        if (msg.sender != nfp.ownerOf(tokenId)) {
            revert NOT_TOKEN_OWNER();
        }

        /// @notice decrease liquidity from v3#nfp, make sure migrator has been approved
        IV3NonfungiblePositionManager.DecreaseLiquidityParams memory decreaseLiquidityParams =
        IV3NonfungiblePositionManager.DecreaseLiquidityParams({
            tokenId: tokenId,
            liquidity: v3PoolParams.liquidity,
            amount0Min: v3PoolParams.amount0Min,
            amount1Min: v3PoolParams.amount1Min,
            deadline: v3PoolParams.deadline
        });
        (amount0Received, amount1Received) = nfp.decreaseLiquidity(decreaseLiquidityParams);

        /// @notice collect tokens from v3#nfp (including fee if necessary)
        IV3NonfungiblePositionManager.CollectParams memory collectParams = IV3NonfungiblePositionManager.CollectParams({
            tokenId: tokenId,
            recipient: address(this),
            amount0Max: v3PoolParams.collectFee ? type(uint128).max : SafeCast.toUint128(amount0Received),
            amount1Max: v3PoolParams.collectFee ? type(uint128).max : SafeCast.toUint128(amount1Received)
        });
        (amount0Received, amount1Received) = nfp.collect(collectParams);

        /// @notice the order may mismatch with v4 pool when WETH is invovled
        /// the following check makes sure that the output always match the order of v4 pool
        (,,, address token1,,,,,,,,) = nfp.positions(tokenId);
        if (token1 == WETH9) {
            (amount0Received, amount1Received) = (amount1Received, amount0Received);
        }
    }

    /// @dev receive extra tokens from user if necessary and normalize all the WETH to native ETH
    function batchAndNormalizeTokens(Currency currency0, Currency currency1, uint256 extraAmount0, uint256 extraAmount1)
        internal
    {
        ERC20 token0 = ERC20(Currency.unwrap(currency0));
        ERC20 token1 = ERC20(Currency.unwrap(currency1));

        if (extraAmount0 > 0) {
            if (currency0.isNative() && msg.value == 0) {
                // we assume that user wants to send WETH
                SafeTransferLib.safeTransferFrom(ERC20(WETH9), msg.sender, address(this), extraAmount0);
            } else if (!currency0.isNative()) {
                SafeTransferLib.safeTransferFrom(token0, msg.sender, address(this), extraAmount0);
            }
        }

        /// @dev token1 cant be NATIVE
        if (extraAmount1 > 0) {
            SafeTransferLib.safeTransferFrom(token1, msg.sender, address(this), extraAmount1);
        }

        if (extraAmount0 != 0 || extraAmount1 != 0) {
            emit MoreFundsAdded(address(token0), address(token1), extraAmount0, extraAmount1);
        }

        // even if user sends native ETH, we still need to unwrap the part from source pool
        if (currency0.isNative()) {
            uint256 wethBalance = ERC20(WETH9).balanceOf(address(this));
            if (wethBalance > 0) IWETH9(WETH9).withdraw(wethBalance);
        }
    }

    function approveMaxIfNeeded(Currency currency, address to, uint256 amount) internal {
        ERC20 token = ERC20(Currency.unwrap(currency));
        if (token.allowance(address(this), to) >= amount) {
            return;
        }
        SafeTransferLib.safeApprove(token, to, type(uint256).max);
    }
}
