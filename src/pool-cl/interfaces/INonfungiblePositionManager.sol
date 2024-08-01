// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {ILockCallback} from "pancake-v4-core/src/interfaces/ILockCallback.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {PoolId} from "pancake-v4-core/src/types/PoolId.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";

import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {IERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import {IERC721Permit} from "./IERC721Permit.sol";
import {ICLPeripheryImmutableState} from "./ICLPeripheryImmutableState.sol";
import {IPeripheryPayments} from "../../interfaces/IPeripheryPayments.sol";
import {IMulticall} from "../../interfaces/IMulticall.sol";

/// @title Non-fungible token for positions
/// @notice Wraps PancakeSwap V4 positions in a non-fungible token interface which allows for them to be transferred
/// and authorized.
interface INonfungiblePositionManager is
    IPeripheryPayments,
    ILockCallback,
    ICLPeripheryImmutableState,
    IERC721Metadata,
    IERC721Enumerable,
    IERC721Permit,
    IMulticall
{
    error NotOwnerOrOperator();
    error InvalidLiquidityDecreaseAmount();
    error NonEmptyPosition();
    error InvalidTokenID();
    error InvalidMaxCollectAmount();

    error OnlyVaultCaller();
    error InvalidCalldataType();

    error NonexistentToken();

    enum CallbackDataType {
        Mint,
        IncreaseLiquidity,
        DecreaseLiquidity,
        Collect,
        Burn,
        BatchModifyLiquidity,
        CloseCurrency
    }

    struct CallbackData {
        CallbackDataType callbackDataType;
        bytes params;
    }

    /// @notice Emitted when liquidity is increased for a position NFT
    /// @dev Also emitted when a token is minted
    /// @param tokenId The ID of the token for which liquidity was increased
    /// @param liquidity The amount by which liquidity for the NFT position was increased
    /// @param amount0 The amount of token0 that was paid for the increase in liquidity
    /// @param amount1 The amount of token1 that was paid for the increase in liquidity
    event IncreaseLiquidity(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    /// @notice Emitted when liquidity is decreased for a position NFT
    /// @param tokenId The ID of the token for which liquidity was decreased
    /// @param liquidity The amount by which liquidity for the NFT position was decreased
    /// @param amount0 The amount of token0 that was accounted for the decrease in liquidity
    /// @param amount1 The amount of token1 that was accounted for the decrease in liquidity
    event DecreaseLiquidity(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    /// @notice Emitted when tokens are collected for a position NFT
    /// @dev The amounts reported may not be exactly equivalent to the amounts transferred, due to rounding behavior
    /// @param tokenId The ID of the token for which underlying tokens were collected
    /// @param recipient The address of the account that received the collected tokens
    /// @param amount0 The amount of token0 owed to the position that was collected
    /// @param amount1 The amount of token1 owed to the position that was collected
    event Collect(uint256 indexed tokenId, address recipient, uint256 amount0, uint256 amount1);

    /// @dev details about the pancake position
    struct Position {
        // the nonce for permits
        uint96 nonce;
        // TODO: confirm if this is still needed
        // the address that is approved for spending this token
        address operator;
        // the hashed poolKey of the pool with which this token is connected
        PoolId poolId;
        // the tick range of the position
        int24 tickLower;
        int24 tickUpper;
        // the liquidity of the position
        uint128 liquidity;
        // the fee growth of the aggregate position as of the last action on the individual position
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        // how many uncollected tokens are owed to the position, as of the last computation
        uint128 tokensOwed0;
        uint128 tokensOwed1;
        bytes32 salt;
    }

    /// @notice Returns the position information associated with a given token ID.
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            PoolId poolId,
            Currency currency0,
            Currency currency1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1,
            bytes32 salt
        );

    /// @notice Initialize the pool state for a given pool ID.
    /// @dev Call this when the pool does not exist and is not initialized.
    /// @param poolKey The pool key
    /// @param sqrtPriceX96 The initial sqrt price of the pool
    /// @param hookData Hook data for the pool
    /// @return tick Pool tick
    function initialize(PoolKey memory poolKey, uint160 sqrtPriceX96, bytes calldata hookData)
        external
        payable
        returns (int24 tick);

    struct MintParams {
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        bytes32 salt;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
    }

    /// @notice Batches many liquidity modification calls to pool manager
    /// @param payload is an encoding of actions, and parameters for those actions
    /// @dev The payload is a byte array that represents the encoded form of the CallbackData struct
    /// for example to mint a position the payload would be:
    /// bytes[] memory payloadArray = new bytes[](1);
    /// bytes memory mintData = abi.encode(INonfungiblePositionManager.CallbackData(
    ///     INonfungiblePositionManager.CallbackDataType.Mint, abi.encode(INonfungiblePositionManager.MintParams({...}))
    /// ))
    /// payloadArray[0] = mintData;
    /// bytes memory payload = abi.encode(payloadArray);
    /// @param deadline is the deadline for the batched actions to be executed
    /// @return returnData is the endocing of each actions return information
    function modifyLiquidities(bytes calldata payload, uint256 deadline) external payable returns (bytes[] memory);

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    /// @notice Burns a token ID, which deletes it from the NFT contract. The token must have 0 liquidity and all tokens
    /// must be collected first.
    /// @param tokenId The ID of the token that is being burned
    function burn(uint256 tokenId) external payable;
}
