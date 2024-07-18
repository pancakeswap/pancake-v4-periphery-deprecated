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
import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
import {SelfPermitERC721} from "./SelfPermitERC721.sol";
import {IBaseMigrator} from "../interfaces/IBaseMigrator.sol";

contract BaseMigrator is IBaseMigrator, PeripheryImmutableState, Multicall, SelfPermit, SelfPermitERC721 {
    constructor(address _WETH9) PeripheryImmutableState(_WETH9) {}

    /// @notice refund native ETH to caller
    /// This is useful when the caller sends more ETH then he specifies in arguments
    function refundETH() external payable override {
        if (address(this).balance > 0) CurrencyLibrary.NATIVE.transfer(msg.sender, address(this).balance);
    }

    /// @notice compare if tokens from v2 pair are the same as token0/token1. Revert with
    /// `TOKEN_NOT_MATCH` if tokens does not match
    /// @param v2Pair the address of v2 pair
    /// @param token0 token0 of v4 poolKey
    /// @param token1 token1 of v4 poolKey
    /// @return shouldReversePair if the order of tokens from v2 pair is different from v4 pair (only when WETH is involved)
    function checkTokensOrderAndMatchFromV2(address v2Pair, Currency token0, Currency token1)
        internal
        view
        returns (bool shouldReversePair)
    {
        address token0V2 = IPancakePair(v2Pair).token0();
        address token1V2 = IPancakePair(v2Pair).token1();
        return _checkIfTokenPairMatchAndOrder(token0V2, token1V2, token0, token1);
    }

    /// @notice compare if tokens from v3 pool are the same as token0/token1. Revert with
    /// `TOKEN_NOT_MATCH` if tokens does not match
    /// @param nfp the address of v3#nfp
    /// @param tokenId the tokenId of v3 pool
    /// @param token0 token0 of v4 poolKey
    /// @param token1 token1 of v4 poolKey
    /// @return shouldReversePair if the order of tokens from v3 pool is different from v4 pair (only when WETH is involved)
    function checkTokensOrderAndMatchFromV3(address nfp, uint256 tokenId, Currency token0, Currency token1)
        internal
        view
        returns (bool shouldReversePair)
    {
        (,, address token0V3, address token1V3,,,,,,,,) = IV3NonfungiblePositionManager(nfp).positions(tokenId);
        return _checkIfTokenPairMatchAndOrder(token0V3, token1V3, token0, token1);
    }

    /// @notice withdraw liquidity from v2 pool (fee will always be included)
    /// It may revert if amount0/amount1 received is less than expected
    /// @param v2PoolParams the parameters to withdraw liquidity from v2 pool
    /// @param shouldReversePair if the order of tokens from v2 pair is different from v4 pair (only when WETH is involved)
    /// @return amount0Received the actual amount of token0 received (in order of v4 pool)
    /// @return amount1Received the actual amount of token1 received (in order of v4 pool)
    function withdrawLiquidityFromV2(V2PoolParams calldata v2PoolParams, bool shouldReversePair)
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
        if (shouldReversePair) {
            (amount0Received, amount1Received) = (amount1Received, amount0Received);
        }
    }

    /// @notice withdraw liquidity from v3 pool and collect fee if specified in `v3PoolParams`
    /// It may revert if the caller is not the owner of the token or amount0/amount1 received is less than expected
    /// @param v3PoolParams the parameters to withdraw liquidity from v3 pool
    /// @param shouldReversePair if the order of tokens from v3 pool is different from v4 pair (only when WETH is involved)
    /// @return amount0Received the actual amount of token0 received (in order of v4 pool)
    /// @return amount1Received the actual amount of token1 received (in order of v4 pool)
    function withdrawLiquidityFromV3(V3PoolParams calldata v3PoolParams, bool shouldReversePair)
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
        if (shouldReversePair) {
            (amount0Received, amount1Received) = (amount1Received, amount0Received);
        }
    }

    /// @notice receive extra tokens from user if specifies in arguments and normalize all the WETH to native ETH
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
            emit ExtraFundsAdded(address(token0), address(token1), extraAmount0, extraAmount1);
        }

        // even if user sends native ETH, we still need to unwrap the part from source pool
        if (currency0.isNative()) {
            uint256 wethBalance = ERC20(WETH9).balanceOf(address(this));
            if (wethBalance > 0) IWETH9(WETH9).withdraw(wethBalance);
        }
    }

    /// @notice approve the maximum amount of token if the current allowance is insufficient for following operations
    function approveMaxIfNeeded(Currency currency, address to, uint256 amount) internal {
        ERC20 token = ERC20(Currency.unwrap(currency));
        if (token.allowance(address(this), to) >= amount) {
            return;
        }
        SafeTransferLib.safeApprove(token, to, type(uint256).max);
    }

    /// @notice Check and revert if tokens from both v2/v3 and v4 pair does not match
    ///         Return true if match but v2v3Token1 is WETH which should be ETH in v4 pair
    /// @param v2v3Token0 token0 from v2/v3 pair
    /// @param v2v3Token1 token1 from v2/v3 pair
    /// @param v4Token0 token0 from v4 pair
    /// @param v4Token1 token1 from v4 pair
    /// @return shouldReversePair if the order of tokens from v2/v3 pair is different from v4 pair (only when WETH is involved)
    function _checkIfTokenPairMatchAndOrder(
        address v2v3Token0,
        address v2v3Token1,
        Currency v4Token0,
        Currency v4Token1
    ) private view returns (bool shouldReversePair) {
        if (v4Token0.isNative() && v2v3Token0 == WETH9) {
            if (Currency.unwrap(v4Token1) != v2v3Token1) {
                revert TOKEN_NOT_MATCH();
            }
        } else if (v4Token0.isNative() && v2v3Token1 == WETH9) {
            if (Currency.unwrap(v4Token1) != v2v3Token0) {
                revert TOKEN_NOT_MATCH();
            }
            shouldReversePair = true;
        } else {
            /// @dev the order of token0 and token1 is always sorted
            /// v2: https://github.com/pancakeswap/pancake-swap-core-v2/blob/38aad83854a46a82ea0e31988ff3cddb2bffb71a/contracts/PancakeFactory.sol#L27
            /// v3: https://github.com/pancakeswap/pancake-v3-contracts/blob/5cc479f0c5a98966c74d94700057b8c3ca629afd/projects/v3-core/contracts/PancakeV3Factory.sol#L66
            if (Currency.unwrap(v4Token0) != v2v3Token0 || Currency.unwrap(v4Token1) != v2v3Token1) {
                revert TOKEN_NOT_MATCH();
            }
        }
    }
}
