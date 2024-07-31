// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {FullMath} from "pancake-v4-core/src/pool-cl/libraries/FullMath.sol";
import {CLPosition} from "pancake-v4-core/src/pool-cl/libraries/CLPosition.sol";
import {BalanceDelta, toBalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {FixedPoint128} from "pancake-v4-core/src/pool-cl/libraries/FixedPoint128.sol";
import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";

import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";
import {INonfungibleTokenPositionDescriptor} from "./interfaces/INonfungibleTokenPositionDescriptor.sol";
import {ERC721Permit} from "./base/ERC721Permit.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {PeripheryValidation} from "../base/PeripheryValidation.sol";
import {SelfPermit} from "../base/SelfPermit.sol";
import {LiquidityManagement} from "./base/LiquidityManagement.sol";
import {CLPeripheryImmutableState} from "./base/CLPeripheryImmutableState.sol";
import {Multicall} from "../base/Multicall.sol";

/// @title NFT positions
/// @notice Wraps Pancake V4 positions in the ERC721 non-fungible token interface
contract NonfungiblePositionManager is
    INonfungiblePositionManager,
    ERC721Permit,
    PeripheryValidation,
    LiquidityManagement,
    SelfPermit,
    Multicall
{
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    /// @dev The ID of the next token that will be minted. Skips 0
    uint256 private _nextId = 1;

    /// @dev Pool keys by poolIds, so we don't save the same poolKey multiple times
    mapping(PoolId pooId => PoolKey) private _poolIdToPoolKey;

    /// @dev The token ID position data
    mapping(uint256 tokenId => Position) private _positions;

    /// @dev The address of the token descriptor contract, which handles generating token URIs for position tokens
    address private immutable _tokenDescriptor;

    constructor(IVault _vault, ICLPoolManager _poolManager, address _tokenDescriptor_, address _WETH9)
        CLPeripheryImmutableState(_vault, _poolManager, _WETH9)
        ERC721Permit("Pancake V4 Positions NFT-V1", "PCS-V4-POS", "1")
    {
        _tokenDescriptor = _tokenDescriptor_;
    }

    /// @inheritdoc INonfungiblePositionManager
    function positions(uint256 tokenId)
        external
        view
        override
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
        )
    {
        Position memory position = _positions[tokenId];
        if (PoolId.unwrap(position.poolId) == 0) revert InvalidTokenID();
        PoolKey memory poolKey = _poolIdToPoolKey[position.poolId];
        return (
            position.nonce,
            position.operator,
            position.poolId,
            poolKey.currency0,
            poolKey.currency1,
            poolKey.fee,
            position.tickLower,
            position.tickUpper,
            position.liquidity,
            position.feeGrowthInside0LastX128,
            position.feeGrowthInside1LastX128,
            position.tokensOwed0,
            position.tokensOwed1,
            position.salt
        );
    }

    /// @inheritdoc INonfungiblePositionManager
    function initialize(PoolKey memory poolKey, uint160 sqrtPriceX96, bytes calldata hookData)
        external
        payable
        override
        returns (int24 tick)
    {
        (tick) = poolManager.initialize(poolKey, sqrtPriceX96, hookData);
    }

    /// @inheritdoc INonfungiblePositionManager
    function modifyLiquidities(bytes calldata lockData, uint256 deadline)
        external
        payable
        checkDeadline(deadline)
        returns (bytes[] memory)
    {
        return abi.decode(vault.lock(abi.encode(msg.sender, lockData)), (bytes[]));
    }

    /// @inheritdoc INonfungiblePositionManager
    function burn(uint256 tokenId) external payable override {
        _handleBurn(tokenId, msg.sender);
    }

    function lockAcquired(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(vault)) {
            revert OnlyVaultCaller();
        }

        (address sender, bytes memory lockData) = abi.decode(rawData, (address, bytes));
        bytes[] memory params = abi.decode(lockData, (bytes[]));
        return _dispatch(params, sender);
    }

    function _dispatch(bytes[] memory params, address sender) internal returns (bytes memory returnDataArrayBytes) {
        uint256 length = params.length;
        bytes[] memory returnData = new bytes[](length);
        // In order to save gas, we will set the settle flag to true if only one liquidity modification
        bool shouldSettle = length == 1;
        for (uint256 i; i < length; i++) {
            CallbackData memory data = abi.decode(params[i], (CallbackData));
            returnData[i] = _handleSingleAction(data, sender, shouldSettle);
        }

        return abi.encode(returnData);
    }

    function _handleSingleAction(CallbackData memory data, address sender, bool shouldSettle)
        internal
        returns (bytes memory)
    {
        if (data.callbackDataType == CallbackDataType.Mint) {
            return _handleMint(data, sender, shouldSettle);
        } else if (data.callbackDataType == CallbackDataType.IncreaseLiquidity) {
            return _handleIncreaseLiquidity(data, sender, shouldSettle);
        } else if (data.callbackDataType == CallbackDataType.DecreaseLiquidity) {
            return _handleDecreaseLiquidity(data, sender, shouldSettle);
        } else if (data.callbackDataType == CallbackDataType.Collect) {
            return _handleCollect(data, sender, shouldSettle);
        } else if (data.callbackDataType == CallbackDataType.CloseCurrency) {
            return _close(data.params, sender);
        } else if (data.callbackDataType == CallbackDataType.Burn) {
            uint256 tokenId = abi.decode(data.params, (uint256));
            return _handleBurn(tokenId, sender);
        } else {
            revert InvalidCalldataType();
        }
    }

    function _handleMint(CallbackData memory data, address sender, bool shouldSettle) internal returns (bytes memory) {
        INonfungiblePositionManager.MintParams memory params =
            abi.decode(data.params, (INonfungiblePositionManager.MintParams));
        PoolKey memory poolKey = params.poolKey;
        PoolId poolId = poolKey.toId();
        int24 tickLower = params.tickLower;
        int24 tickUpper = params.tickUpper;
        (uint128 liquidity, BalanceDelta delta) = addLiquidity(
            AddLiquidityParams({
                poolKey: poolKey,
                tickLower: tickLower,
                tickUpper: tickUpper,
                salt: params.salt,
                amount0Desired: params.amount0Desired,
                amount1Desired: params.amount1Desired,
                amount0Min: params.amount0Min,
                amount1Min: params.amount1Min
            })
        );

        uint256 tokenId = _nextId++;
        _mint(params.recipient, tokenId);

        CLPosition.Info memory positionInfo =
            poolManager.getPosition(poolId, address(this), tickLower, tickUpper, params.salt);
        _positions[tokenId] = Position({
            nonce: 0,
            operator: address(0),
            poolId: poolId,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            feeGrowthInside0LastX128: positionInfo.feeGrowthInside0LastX128,
            feeGrowthInside1LastX128: positionInfo.feeGrowthInside1LastX128,
            tokensOwed0: 0,
            tokensOwed1: 0,
            salt: params.salt
        });
        if (address(_poolIdToPoolKey[poolId].poolManager) == address(0)) {
            _poolIdToPoolKey[poolId] = poolKey;
        }

        if (shouldSettle) {
            settleDeltas(sender, poolKey, delta);
        }
        uint128 amount0 = uint128(-delta.amount0());
        uint128 amount1 = uint128(-delta.amount1());

        emit IncreaseLiquidity(tokenId, liquidity, amount0, amount1);

        return abi.encode(tokenId, liquidity, amount0, amount1);
    }

    function _handleIncreaseLiquidity(CallbackData memory data, address sender, bool shouldSettle)
        internal
        returns (bytes memory)
    {
        IncreaseLiquidityParams memory params = abi.decode(data.params, (IncreaseLiquidityParams));
        Position storage nftPosition = _positions[params.tokenId];
        PoolId poolId = nftPosition.poolId;
        uint128 existingLiquility = nftPosition.liquidity;
        int24 tickLower = nftPosition.tickLower;
        int24 tickUpper = nftPosition.tickUpper;
        bytes32 salt = nftPosition.salt;
        PoolKey memory poolKey = _poolIdToPoolKey[poolId];

        (uint128 liquidity, BalanceDelta delta) = addLiquidity(
            AddLiquidityParams({
                poolKey: poolKey,
                tickLower: tickLower,
                tickUpper: tickUpper,
                salt: salt,
                amount0Desired: params.amount0Desired,
                amount1Desired: params.amount1Desired,
                amount0Min: params.amount0Min,
                amount1Min: params.amount1Min
            })
        );

        CLPosition.Info memory poolManagerPositionInfo =
            poolManager.getPosition(poolId, address(this), tickLower, tickUpper, salt);

        /// @dev This can be overflow in following cases:
        /// 1. feeGrowthInside0LastX128 is overflow
        /// 2. when we add liquidity to a empty position:
        ///     poolManagerPositionInfo.feeGrowthInside0LastX128 = 0
        ///     however nftPosition.feeGrowthInside0LastX128 could be greater than 0
        ///     because clPoolManager will reset ticks if liquidity is back to 0
        ///     but feeGrowthInside0LastX128 will not be reset
        ///     that's won't cause any issue because existingLiquility = 0
        ///     unchecked is needed to avoid overflow error
        unchecked {
            nftPosition.tokensOwed0 += uint128(
                FullMath.mulDiv(
                    poolManagerPositionInfo.feeGrowthInside0LastX128 - nftPosition.feeGrowthInside0LastX128,
                    existingLiquility,
                    FixedPoint128.Q128
                )
            );
            nftPosition.tokensOwed1 += uint128(
                FullMath.mulDiv(
                    poolManagerPositionInfo.feeGrowthInside1LastX128 - nftPosition.feeGrowthInside1LastX128,
                    existingLiquility,
                    FixedPoint128.Q128
                )
            );
        }

        nftPosition.feeGrowthInside0LastX128 = poolManagerPositionInfo.feeGrowthInside0LastX128;
        nftPosition.feeGrowthInside1LastX128 = poolManagerPositionInfo.feeGrowthInside1LastX128;
        nftPosition.liquidity += liquidity;

        if (shouldSettle) {
            settleDeltas(sender, poolKey, delta);
        }

        uint128 amount0 = uint128(-delta.amount0());
        uint128 amount1 = uint128(-delta.amount1());
        emit IncreaseLiquidity(params.tokenId, liquidity, amount0, amount1);

        return abi.encode(liquidity, amount0, amount1);
    }

    function _handleDecreaseLiquidity(CallbackData memory data, address sender, bool shouldSettle)
        internal
        returns (bytes memory)
    {
        DecreaseLiquidityParams memory params = abi.decode(data.params, (DecreaseLiquidityParams));
        if (params.liquidity == 0) {
            revert InvalidLiquidityDecreaseAmount();
        }
        _checkAuthorizedForToken(sender, params.tokenId);
        Position storage nftPosition = _positions[params.tokenId];
        PoolId poolId = nftPosition.poolId;
        uint128 liquidity = nftPosition.liquidity;
        int24 tickLower = nftPosition.tickLower;
        int24 tickUpper = nftPosition.tickUpper;
        bytes32 salt = nftPosition.salt;
        PoolKey memory poolKey = _poolIdToPoolKey[poolId];

        if (liquidity < params.liquidity) {
            revert InvalidLiquidityDecreaseAmount();
        }

        BalanceDelta delta = removeLiquidity(
            RemoveLiquidityParams({
                poolKey: poolKey,
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidity: params.liquidity,
                amount0Min: params.amount0Min,
                amount1Min: params.amount1Min,
                salt: salt
            })
        );

        CLPosition.Info memory poolManagerPositionInfo =
            poolManager.getPosition(poolId, address(this), tickLower, tickUpper, salt);

        /// @dev This can be overflow in following cases:
        /// 1. feeGrowthInside0LastX128 is overflow
        /// 2. when we add liquidity to a empty position:
        ///     poolManagerPositionInfo.feeGrowthInside0LastX128 = 0
        ///     however nftPosition.feeGrowthInside0LastX128 could be greater than 0
        ///     because clPoolManager will reset ticks if liquidity is back to 0
        ///     but feeGrowthInside0LastX128 will not be reset
        ///     that's won't cause any issue because existingLiquility = 0
        ///     unchecked is needed to avoid overflow error
        unchecked {
            nftPosition.tokensOwed0 += uint128(
                FullMath.mulDiv(
                    poolManagerPositionInfo.feeGrowthInside0LastX128 - nftPosition.feeGrowthInside0LastX128,
                    liquidity,
                    FixedPoint128.Q128
                )
            );

            nftPosition.tokensOwed1 += uint128(
                FullMath.mulDiv(
                    poolManagerPositionInfo.feeGrowthInside1LastX128 - nftPosition.feeGrowthInside1LastX128,
                    liquidity,
                    FixedPoint128.Q128
                )
            );
        }

        nftPosition.feeGrowthInside0LastX128 = poolManagerPositionInfo.feeGrowthInside0LastX128;
        nftPosition.feeGrowthInside1LastX128 = poolManagerPositionInfo.feeGrowthInside1LastX128;
        unchecked {
            nftPosition.liquidity -= params.liquidity;
        }

        if (shouldSettle) {
            settleDeltas(sender, poolKey, delta);
        }

        emit DecreaseLiquidity(params.tokenId, params.liquidity, uint128(delta.amount0()), uint128(delta.amount1()));

        return abi.encode(delta.amount0(), delta.amount1());
    }

    function _handleCollect(CallbackData memory data, address sender, bool shouldTake)
        internal
        returns (bytes memory)
    {
        CollectParams memory params = abi.decode(data.params, (CollectParams));
        if (params.amount0Max == 0 && params.amount1Max == 0) {
            revert InvalidMaxCollectAmount();
        }
        _checkAuthorizedForToken(sender, params.tokenId);
        params.recipient = params.recipient == address(0) ? address(sender) : params.recipient;
        Position storage nftPosition = _positions[params.tokenId];
        Position memory nftPositionCache = _positions[params.tokenId];
        PoolId poolId = nftPositionCache.poolId;
        bytes32 salt = nftPositionCache.salt;
        PoolKey memory poolKey = _poolIdToPoolKey[poolId];

        uint128 tokensOwed0 = nftPositionCache.tokensOwed0;
        uint128 tokensOwed1 = nftPositionCache.tokensOwed1;

        if (nftPositionCache.liquidity > 0) {
            mintAccumulatedPositionFee(poolKey, nftPositionCache.tickLower, nftPositionCache.tickUpper, salt);

            CLPosition.Info memory poolManagerPositionInfo = poolManager.getPosition(
                poolId, address(this), nftPositionCache.tickLower, nftPositionCache.tickUpper, salt
            );

            /// @dev This can be overflow in following cases:
            /// 1. feeGrowthInside0LastX128 is overflow
            /// 2. when we add liquidity to a empty position:
            ///     poolManagerPositionInfo.feeGrowthInside0LastX128 = 0
            ///     however nftPosition.feeGrowthInside0LastX128 could be greater than 0
            ///     because clPoolManager will reset ticks if liquidity is back to 0
            ///     but feeGrowthInside0LastX128 will not be reset
            ///     that's won't cause any issue because existingLiquility = 0
            ///     unchecked is needed to avoid overflow error
            unchecked {
                tokensOwed0 += uint128(
                    FullMath.mulDiv(
                        poolManagerPositionInfo.feeGrowthInside0LastX128 - nftPositionCache.feeGrowthInside0LastX128,
                        nftPositionCache.liquidity,
                        FixedPoint128.Q128
                    )
                );
                tokensOwed1 += uint128(
                    FullMath.mulDiv(
                        poolManagerPositionInfo.feeGrowthInside1LastX128 - nftPositionCache.feeGrowthInside1LastX128,
                        nftPositionCache.liquidity,
                        FixedPoint128.Q128
                    )
                );
            }

            nftPosition.feeGrowthInside0LastX128 = poolManagerPositionInfo.feeGrowthInside0LastX128;
            nftPosition.feeGrowthInside1LastX128 = poolManagerPositionInfo.feeGrowthInside1LastX128;
        }

        (uint128 amount0Collect, uint128 amount1Collect) = (
            params.amount0Max > tokensOwed0 ? tokensOwed0 : params.amount0Max,
            params.amount1Max > tokensOwed1 ? tokensOwed1 : params.amount1Max
        );

        // update position
        nftPosition.tokensOwed0 = tokensOwed0 - amount0Collect;
        nftPosition.tokensOwed1 = tokensOwed1 - amount1Collect;

        /// @dev due to rounding down calculation in FullMath, some wei might be loss if the fee is too small
        /// if that happen we need to ignore the loss part and take the rest of the fee otherwise it will revert whole tx
        uint128 actualFee0Left = uint128(vault.balanceOf(address(this), poolKey.currency0));
        uint128 actualFee1Left = uint128(vault.balanceOf(address(this), poolKey.currency1));
        (amount0Collect, amount1Collect) = (
            actualFee0Left > amount0Collect ? amount0Collect : actualFee0Left,
            actualFee1Left > amount1Collect ? amount1Collect : actualFee1Left
        );

        // cash out from vault
        burnAndTake(poolKey.currency0, params.recipient, amount0Collect, shouldTake);
        burnAndTake(poolKey.currency1, params.recipient, amount1Collect, shouldTake);

        emit Collect(params.tokenId, params.recipient, amount0Collect, amount1Collect);

        return abi.encode(amount0Collect, amount1Collect);
    }

    function _handleBurn(uint256 tokenId, address sender) internal returns (bytes memory) {
        _checkAuthorizedForToken(sender, tokenId);
        Position storage position = _positions[tokenId];
        if (position.liquidity > 0 || position.tokensOwed0 > 0 || position.tokensOwed1 > 0) {
            revert NonEmptyPosition();
        }

        delete _positions[tokenId];
        _burn(tokenId);

        return abi.encode(tokenId);
    }

    /// @param params is an encoding of the Currency to close
    /// @param sender is the msg.sender encoded by the `modifyLiquidities` function before the `lockAcquired`.
    /// @return an encoding of int256 the balance of the currency being settled by this call
    function _close(bytes memory params, address sender) internal returns (bytes memory) {
        (Currency currency) = abi.decode(params, (Currency));
        // this address has applied all deltas on behalf of the user/owner
        // it is safe to close this entire delta because of slippage checks throughout the batched calls.
        int256 currencyDelta = vault.currencyDelta(address(this), currency);

        settleOrTake(currency, sender, int128(currencyDelta));
        // if there are native tokens left over after settling, return to sender
        if (address(this).balance > 0 && currency.isNative()) {
            CurrencyLibrary.NATIVE.transfer(sender, address(this).balance);
        }

        return abi.encode(currencyDelta);
    }

    function tokenURI(uint256 tokenId) public view override(ERC721, IERC721Metadata) returns (string memory) {
        if (!_exists(tokenId)) {
            revert NonexistentToken();
        }

        return INonfungibleTokenPositionDescriptor(_tokenDescriptor).tokenURI(this, tokenId);
    }

    // TODO: double check when update solidity version & oz version
    // Different oz version might have different inner implementation for approving part
    function _getAndIncrementNonce(uint256 tokenId) internal override returns (uint256) {
        return uint256(_positions[tokenId].nonce++);
    }

    /// @inheritdoc IERC721
    function getApproved(uint256 tokenId) public view override(ERC721, IERC721) returns (address) {
        if (!_exists(tokenId)) {
            revert NonexistentToken();
        }

        return _positions[tokenId].operator;
    }

    function _checkAuthorizedForToken(address sender, uint256 tokenId) internal view {
        if (!_isApprovedOrOwner(sender, tokenId)) {
            revert NotOwnerOrOperator();
        }
    }

    /// @dev Overrides _approve to use the operator in the position, which is packed with the position permit nonce
    function _approve(address to, uint256 tokenId) internal override(ERC721) {
        _positions[tokenId].operator = to;
        emit Approval(ownerOf(tokenId), to, tokenId);
    }

    function _transfer(address from, address to, uint256 tokenId) internal override(ERC721) {
        // Clear approvals from the previous owner
        _positions[tokenId].operator = address(0);
        super._transfer(from, to, tokenId);
    }
}
