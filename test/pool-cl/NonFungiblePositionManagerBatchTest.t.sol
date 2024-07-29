// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {Vault} from "pancake-v4-core/src/Vault.sol";
import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";
import {TokenFixture} from "pancake-v4-core/test/helpers/TokenFixture.sol";
import {ICLPoolManager, CLPosition} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolManager} from "pancake-v4-core/src/pool-cl/CLPoolManager.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {FixedPoint96} from "pancake-v4-core/src/pool-cl/libraries/FixedPoint96.sol";
import {FixedPoint128} from "pancake-v4-core/src/pool-cl/libraries/FixedPoint128.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {TickMath} from "pancake-v4-core/src/pool-cl/libraries/TickMath.sol";
import {CLPoolManagerRouter} from "pancake-v4-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {FullMath} from "pancake-v4-core/src/pool-cl/libraries/FullMath.sol";
import {BalanceDelta} from "pancake-v4-core/src/types/BalanceDelta.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {NonfungibleTokenPositionDescriptorOffChain} from
    "../../src/pool-cl/NonfungibleTokenPositionDescriptorOffChain.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {NonfungiblePositionManager} from "../../src/pool-cl/NonfungiblePositionManager.sol";
import {INonfungiblePositionManager} from "../../src/pool-cl/interfaces/INonfungiblePositionManager.sol";
import {LiquidityAmounts} from "../../src/pool-cl/libraries/LiquidityAmounts.sol";
import {LiquidityManagement} from "../../src/pool-cl/base/LiquidityManagement.sol";

contract NonFungiblePositionManagerBatchTest is TokenFixture, Test, GasSnapshot {
    using PoolIdLibrary for PoolKey;
    using Strings for uint256;

    event IncreaseLiquidity(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event DecreaseLiquidity(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Collect(uint256 indexed tokenId, address recipient, uint256 amount0, uint256 amount1);

    IVault public vault;
    ICLPoolManager public poolManager;
    CLPoolManagerRouter public router;
    NonfungiblePositionManager public nonfungiblePoolManager;

    function setUp() public {
        vault = new Vault();
        poolManager = new CLPoolManager(vault, 3000);
        vault.registerApp(address(poolManager));

        initializeTokens();

        router = new CLPoolManagerRouter(vault, poolManager);
        IERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
        NonfungibleTokenPositionDescriptorOffChain NFTPositionDescriptorContract =
            new NonfungibleTokenPositionDescriptorOffChain();
        ProxyAdmin proxyAdminContract = new ProxyAdmin();

        string memory baseTokenURI = string.concat("https://nft.pancakeswap.com/v4/", block.chainid.toString(), "/");
        TransparentUpgradeableProxy NFTDescriptorProxy = new TransparentUpgradeableProxy(
            address(NFTPositionDescriptorContract),
            address(proxyAdminContract),
            abi.encodeCall(NonfungibleTokenPositionDescriptorOffChain.initialize, (baseTokenURI))
        );

        nonfungiblePoolManager =
            new NonfungiblePositionManager(vault, poolManager, address(NFTDescriptorProxy), address(0));
        vm.label(Currency.unwrap(currency0), "currency0");
        vm.label(Currency.unwrap(currency1), "currency1");

        IERC20(Currency.unwrap(currency0)).approve(address(nonfungiblePoolManager), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(nonfungiblePoolManager), type(uint256).max);
    }

    function testBatchMint() external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        {
            INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
                poolKey: key,
                tickLower: 46053,
                tickUpper: 46055,
                salt: bytes32(0),
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: makeAddr("someone"),
                deadline: type(uint256).max
            });

            uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
            nonfungiblePoolManager.initialize(key, sqrtPriceX96, new bytes(0));

            // generate modifyLiquidities data
            bytes memory mintData = abi.encode(
                INonfungiblePositionManager.CallbackData(
                    address(this), INonfungiblePositionManager.CallbackDataType.Mint, abi.encode(mintParams)
                )
            );
            bytes[] memory data = new bytes[](3);
            data[0] = mintData;
            // set current close data
            data[1] = abi.encode(
                INonfungiblePositionManager.CallbackData(
                    address(this), INonfungiblePositionManager.CallbackDataType.CloseCurrency, abi.encode(currency0)
                )
            );
            data[2] = abi.encode(
                INonfungiblePositionManager.CallbackData(
                    address(this), INonfungiblePositionManager.CallbackDataType.CloseCurrency, abi.encode(currency1)
                )
            );
            snapStart("NonFungiblePositionManagerBatch#mint");
            nonfungiblePoolManager.modifyLiquidities(abi.encode(data), block.timestamp + 100);
            snapEnd();
        }

        {
            (
                uint96 nonce,
                address operator,
                PoolId poolId,
                Currency _currency0,
                Currency _currency1,
                uint24 fee,
                int24 tickLower,
                int24 tickUpper,
                uint128 liquidity,
                uint256 feeGrowthInside0LastX128,
                uint256 feeGrowthInside1LastX128,
                uint128 tokensOwed0,
                uint128 tokensOwed1,
                bytes32 salt
            ) = nonfungiblePoolManager.positions(1);
            assertEq(nonce, 0, "Unexpected nonce");
            assertEq(operator, address(0), "Unexpected operator");
            assertEq(PoolId.unwrap(poolId), PoolId.unwrap(key.toId()), "Unexpected poolId");
            assertEq(Currency.unwrap(_currency0), Currency.unwrap(currency0), "Unexpected currency0");
            assertEq(Currency.unwrap(_currency1), Currency.unwrap(currency1), "Unexpected currency1");
            assertEq(fee, 3000, "Unexpected fee");
            assertEq(tickLower, 46053, "Unexpected tickLower");
            assertEq(tickUpper, 46055, "Unexpected tickUpper");
            assertEq(liquidity, 1991375027067913587988, "Unexpected liquidity");
            assertEq(feeGrowthInside0LastX128, 0, "Unexpected feeGrowthInside0LastX128");
            assertEq(feeGrowthInside1LastX128, 0, "Unexpected feeGrowthInside1LastX128");
            assertEq(tokensOwed0, 0, "Unexpected tokensOwed0");
            assertEq(tokensOwed1, 0, "Unexpected tokensOwed1");
            assertEq(salt, bytes32(0), "Unexpected salt");
            string memory expectTokenURI =
                string.concat("https://nft.pancakeswap.com/v4/", block.chainid.toString(), "/1");
            string memory realTokenURI = nonfungiblePoolManager.tokenURI(1);
            assertEq(expectTokenURI, realTokenURI, "Unexpected tokenURI");
        }
    }

    function testBatchMintWithoutCloseCurrency() external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        {
            INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
                poolKey: key,
                tickLower: 46053,
                tickUpper: 46055,
                salt: bytes32(0),
                amount0Desired: 1 ether,
                amount1Desired: 1 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: makeAddr("someone"),
                deadline: type(uint256).max
            });

            uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);

            nonfungiblePoolManager.initialize(key, sqrtPriceX96, new bytes(0));

            // generate modifyLiquidities data
            bytes memory mintData = abi.encode(
                INonfungiblePositionManager.CallbackData(
                    address(this), INonfungiblePositionManager.CallbackDataType.Mint, abi.encode(mintParams)
                )
            );
            bytes[] memory data = new bytes[](1);
            data[0] = mintData;

            snapStart("NonFungiblePositionManagerBatch#mintWithoutCloseCurrency");
            nonfungiblePoolManager.modifyLiquidities(abi.encode(data), block.timestamp + 100);
            snapEnd();
        }

        {
            (
                uint96 nonce,
                address operator,
                PoolId poolId,
                Currency _currency0,
                Currency _currency1,
                uint24 fee,
                int24 tickLower,
                int24 tickUpper,
                uint128 liquidity,
                uint256 feeGrowthInside0LastX128,
                uint256 feeGrowthInside1LastX128,
                uint128 tokensOwed0,
                uint128 tokensOwed1,
                bytes32 salt
            ) = nonfungiblePoolManager.positions(1);
            assertEq(nonce, 0, "Unexpected nonce");
            assertEq(operator, address(0), "Unexpected operator");
            assertEq(PoolId.unwrap(poolId), PoolId.unwrap(key.toId()), "Unexpected poolId");
            assertEq(Currency.unwrap(_currency0), Currency.unwrap(currency0), "Unexpected currency0");
            assertEq(Currency.unwrap(_currency1), Currency.unwrap(currency1), "Unexpected currency1");
            assertEq(fee, 3000, "Unexpected fee");
            assertEq(tickLower, 46053, "Unexpected tickLower");
            assertEq(tickUpper, 46055, "Unexpected tickUpper");
            assertEq(liquidity, 1991375027067913587988, "Unexpected liquidity");
            assertEq(feeGrowthInside0LastX128, 0, "Unexpected feeGrowthInside0LastX128");
            assertEq(feeGrowthInside1LastX128, 0, "Unexpected feeGrowthInside1LastX128");
            assertEq(tokensOwed0, 0, "Unexpected tokensOwed0");
            assertEq(tokensOwed1, 0, "Unexpected tokensOwed1");
            assertEq(salt, bytes32(0), "Unexpected salt");
            string memory expectTokenURI =
                string.concat("https://nft.pancakeswap.com/v4/", block.chainid.toString(), "/1");
            string memory realTokenURI = nonfungiblePoolManager.tokenURI(1);
            assertEq(expectTokenURI, realTokenURI, "Unexpected tokenURI");
        }
    }

    function testBatchMintAndIncreaseLiquidity() external {
        bytes32 salt = keccak256("salt");
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: key,
            tickLower: 46053,
            tickUpper: 46055,
            salt: salt,
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: type(uint256).max
        });

        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(key, sqrtPriceX96, new bytes(0));

        // generate multicall data
        bytes[] memory data = new bytes[](4);
        data[0] = abi.encode(
            INonfungiblePositionManager.CallbackData(
                address(this), INonfungiblePositionManager.CallbackDataType.Mint, abi.encode(mintParams)
            )
        );

        INonfungiblePositionManager.IncreaseLiquidityParams memory increaseParams = INonfungiblePositionManager
            .IncreaseLiquidityParams({
            tokenId: 1,
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            deadline: type(uint256).max
        });
        data[1] = abi.encode(
            INonfungiblePositionManager.CallbackData(
                address(this),
                INonfungiblePositionManager.CallbackDataType.IncreaseLiquidity,
                abi.encode(increaseParams)
            )
        );

        // set currency close data
        data[2] = abi.encode(
            INonfungiblePositionManager.CallbackData(
                address(this), INonfungiblePositionManager.CallbackDataType.CloseCurrency, abi.encode(currency0)
            )
        );
        data[3] = abi.encode(
            INonfungiblePositionManager.CallbackData(
                address(this), INonfungiblePositionManager.CallbackDataType.CloseCurrency, abi.encode(currency1)
            )
        );

        // batch mint and increase liquidity
        snapStart("NonFungiblePositionManagerBatch#BatchMintAndIncreaseLiquidity");
        nonfungiblePoolManager.modifyLiquidities(abi.encode(data), block.timestamp + 100);
        snapEnd();

        {
            (
                ,
                ,
                ,
                ,
                ,
                ,
                ,
                ,
                uint128 _liquidity,
                uint256 feeGrowthInside0LastX128,
                uint256 feeGrowthInside1LastX128,
                uint128 tokensOwed0,
                uint128 tokensOwed1,
            ) = nonfungiblePoolManager.positions(1);

            uint128 liquidityExpected = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96, TickMath.getSqrtRatioAtTick(46053), TickMath.getSqrtRatioAtTick(46055), 1 ether, 1 ether
            );

            assertEq(_liquidity, 1991375027067913587988 + liquidityExpected, "Unexpected liquidity");
            assertEq(feeGrowthInside0LastX128, 0, "Unexpected feeGrowthInside0LastX128");
            assertEq(feeGrowthInside1LastX128, 0, "Unexpected feeGrowthInside1LastX128");
            assertEq(tokensOwed0, 0, "Unexpected feesOwed0");
            assertEq(tokensOwed1, 0, "Unexpected feesOwed1");
        }
        assertEq(poolManager.getLiquidity(key.toId()), 2 * 1991375027067913587988, "Unexpected liquidity for the pool");
        assertEq(
            poolManager.getLiquidity(key.toId(), address(nonfungiblePoolManager), 46053, 46055, salt),
            1991375027067913587988 * 2,
            "Unexpected liquidity for current position"
        );

        assertEq(
            nonfungiblePoolManager.balanceOf(address(this)), 1, "Unexpected balance of the position owner after mint"
        );

        assertEq(nonfungiblePoolManager.ownerOf(1), address(this), "Unexpected owner of the position");

        {
            (
                ,
                ,
                ,
                ,
                ,
                ,
                ,
                ,
                uint128 _liquidity,
                uint256 feeGrowthInside0LastX128,
                uint256 feeGrowthInside1LastX128,
                uint128 tokensOwed0,
                uint128 tokensOwed1,
            ) = nonfungiblePoolManager.positions(1);
            assertEq(_liquidity, 1991375027067913587988 * 2, "Unexpected liquidity");
            assertEq(feeGrowthInside0LastX128, 0, "Unexpected feeGrowthInside0LastX128");
            assertEq(feeGrowthInside1LastX128, 0, "Unexpected feeGrowthInside1LastX128");
            assertEq(tokensOwed0, 0, "Unexpected tokensOwed0");
            assertEq(tokensOwed1, 0, "Unexpected tokensOwed1");
        }
    }

    function testBatchMintIncreaseAndDecreaseLiquidity(bytes32 salt) external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: key,
            tickLower: 46053,
            tickUpper: 46055,
            salt: salt,
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: type(uint256).max
        });

        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(key, sqrtPriceX96, new bytes(0));
        // nonfungiblePoolManager.mint(mintParams);

        // generate multicall data
        bytes[] memory data = new bytes[](5);
        data[0] = abi.encode(
            INonfungiblePositionManager.CallbackData(
                address(this), INonfungiblePositionManager.CallbackDataType.Mint, abi.encode(mintParams)
            )
        );

        INonfungiblePositionManager.IncreaseLiquidityParams memory increaseParams = INonfungiblePositionManager
            .IncreaseLiquidityParams({
            tokenId: 1,
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            deadline: type(uint256).max
        });
        data[1] = abi.encode(
            INonfungiblePositionManager.CallbackData(
                address(this),
                INonfungiblePositionManager.CallbackDataType.IncreaseLiquidity,
                abi.encode(increaseParams)
            )
        );

        INonfungiblePositionManager.DecreaseLiquidityParams memory decreaseParams = INonfungiblePositionManager
            .DecreaseLiquidityParams({
            tokenId: 1,
            liquidity: 1991375027067913587988 + 1991375027067913587987,
            amount0Min: 0,
            amount1Min: 0,
            deadline: type(uint256).max
        });

        data[2] = abi.encode(
            INonfungiblePositionManager.CallbackData(
                address(this),
                INonfungiblePositionManager.CallbackDataType.DecreaseLiquidity,
                abi.encode(decreaseParams)
            )
        );

        // set currency close data
        data[3] = abi.encode(
            INonfungiblePositionManager.CallbackData(
                address(this), INonfungiblePositionManager.CallbackDataType.CloseCurrency, abi.encode(currency0)
            )
        );
        data[4] = abi.encode(
            INonfungiblePositionManager.CallbackData(
                address(this), INonfungiblePositionManager.CallbackDataType.CloseCurrency, abi.encode(currency1)
            )
        );

        // batch mint and increase liquidity, then decrease liquidity
        snapStart("NonFungiblePositionManagerBatch#batchMintIncreaseAndDecreaseLiquidity");
        nonfungiblePoolManager.modifyLiquidities(abi.encode(data), block.timestamp + 100);
        snapEnd();

        {
            (
                ,
                ,
                ,
                ,
                ,
                ,
                ,
                ,
                uint128 _liquidity,
                uint256 feeGrowthInside0LastX128,
                uint256 feeGrowthInside1LastX128,
                uint128 tokensOwed0,
                uint128 tokensOwed1,
            ) = nonfungiblePoolManager.positions(1);

            assertEq(_liquidity, 1, "Unexpected liquidity");
            assertEq(feeGrowthInside0LastX128, 0, "Unexpected feeGrowthInside0LastX128");
            assertEq(feeGrowthInside1LastX128, 0, "Unexpected feeGrowthInside1LastX128");
            assertEq(tokensOwed0, 0, "Unexpected feesOwed0");
            assertEq(tokensOwed1, 0, "Unexpected feesOwed1");
        }
    }

    function testBatchIncreaseLiquidityWithoutCloseCurrency() external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: key,
            tickLower: 46053,
            tickUpper: 46055,
            salt: bytes32(0),
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: type(uint256).max
        });

        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(key, sqrtPriceX96, new bytes(0));
        nonfungiblePoolManager.mint(mintParams);

        // generate modifyLiquidities data
        INonfungiblePositionManager.IncreaseLiquidityParams memory increaseParams = INonfungiblePositionManager
            .IncreaseLiquidityParams({
            tokenId: 1,
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            deadline: type(uint256).max
        });
        bytes memory increaseData = abi.encode(
            INonfungiblePositionManager.CallbackData(
                address(this),
                INonfungiblePositionManager.CallbackDataType.IncreaseLiquidity,
                abi.encode(increaseParams)
            )
        );
        bytes[] memory data = new bytes[](1);
        data[0] = increaseData;

        snapStart("NonFungiblePositionManagerBatch#increaseLiquidityWithoutCloseCurrency");
        nonfungiblePoolManager.modifyLiquidities(abi.encode(data), block.timestamp + 100);
        snapEnd();
    }

    function testBatchIncreaseLiquidity() external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: key,
            tickLower: 46053,
            tickUpper: 46055,
            salt: bytes32(0),
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: type(uint256).max
        });

        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(key, sqrtPriceX96, new bytes(0));
        nonfungiblePoolManager.mint(mintParams);

        // generate modifyLiquidities data
        INonfungiblePositionManager.IncreaseLiquidityParams memory increaseParams = INonfungiblePositionManager
            .IncreaseLiquidityParams({
            tokenId: 1,
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            deadline: type(uint256).max
        });
        bytes memory increaseData = abi.encode(
            INonfungiblePositionManager.CallbackData(
                address(this),
                INonfungiblePositionManager.CallbackDataType.IncreaseLiquidity,
                abi.encode(increaseParams)
            )
        );
        bytes[] memory data = new bytes[](3);
        data[0] = increaseData;
        // set current close data
        data[1] = abi.encode(
            INonfungiblePositionManager.CallbackData(
                address(this), INonfungiblePositionManager.CallbackDataType.CloseCurrency, abi.encode(currency0)
            )
        );
        data[2] = abi.encode(
            INonfungiblePositionManager.CallbackData(
                address(this), INonfungiblePositionManager.CallbackDataType.CloseCurrency, abi.encode(currency1)
            )
        );

        snapStart("NonFungiblePositionManagerBatch#increaseLiquidity");
        nonfungiblePoolManager.modifyLiquidities(abi.encode(data), block.timestamp + 100);
        snapEnd();
    }

    function testBatchDecreaseLiquidityWithoutCloseCurrency() external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: key,
            tickLower: 46053,
            tickUpper: 46055,
            salt: bytes32(0),
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: type(uint256).max
        });

        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(key, sqrtPriceX96, new bytes(0));

        nonfungiblePoolManager.mint(mintParams);

        // generate modifyLiquidities data
        INonfungiblePositionManager.DecreaseLiquidityParams memory decreaseParams = INonfungiblePositionManager
            .DecreaseLiquidityParams({
            tokenId: 1,
            liquidity: 1991375027067913587988,
            amount0Min: 0,
            amount1Min: 0,
            deadline: type(uint256).max
        });
        bytes memory decreaseData = abi.encode(
            INonfungiblePositionManager.CallbackData(
                address(this),
                INonfungiblePositionManager.CallbackDataType.DecreaseLiquidity,
                abi.encode(decreaseParams)
            )
        );
        bytes[] memory data = new bytes[](1);
        data[0] = decreaseData;

        snapStart("NonFungiblePositionManagerBatch#decreaseLiquidityWithoutCloseCurrency");
        nonfungiblePoolManager.modifyLiquidities(abi.encode(data), block.timestamp + 100);
        snapEnd();
    }

    function testBatchDecreaseLiquidity() external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: key,
            tickLower: 46053,
            tickUpper: 46055,
            salt: bytes32(0),
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: type(uint256).max
        });

        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(key, sqrtPriceX96, new bytes(0));

        nonfungiblePoolManager.mint(mintParams);

        // generate modifyLiquidities data
        INonfungiblePositionManager.DecreaseLiquidityParams memory decreaseParams = INonfungiblePositionManager
            .DecreaseLiquidityParams({
            tokenId: 1,
            liquidity: 1991375027067913587988,
            amount0Min: 0,
            amount1Min: 0,
            deadline: type(uint256).max
        });
        bytes memory decreaseData = abi.encode(
            INonfungiblePositionManager.CallbackData(
                address(this),
                INonfungiblePositionManager.CallbackDataType.DecreaseLiquidity,
                abi.encode(decreaseParams)
            )
        );
        bytes[] memory data = new bytes[](3);
        data[0] = decreaseData;

        // set current close data
        data[1] = abi.encode(
            INonfungiblePositionManager.CallbackData(
                address(this), INonfungiblePositionManager.CallbackDataType.CloseCurrency, abi.encode(currency0)
            )
        );
        data[2] = abi.encode(
            INonfungiblePositionManager.CallbackData(
                address(this), INonfungiblePositionManager.CallbackDataType.CloseCurrency, abi.encode(currency1)
            )
        );

        snapStart("NonFungiblePositionManagerBatch#decreaseLiquidity");
        nonfungiblePoolManager.modifyLiquidities(abi.encode(data), block.timestamp + 100);
        snapEnd();
    }

    function testBatchCollectWithoutCloseCurrency() external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: key,
            tickLower: 46053,
            tickUpper: 46055,
            salt: bytes32(0),
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: type(uint256).max
        });

        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(key, sqrtPriceX96, new bytes(0));

        nonfungiblePoolManager.mint(mintParams);
        // make the LPing balance of the position non-zero
        router.donate(key, 1 ether, 1 ether, "");

        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: 1,
            recipient: address(this),
            amount0Max: 999999999999999999,
            amount1Max: 999999999999999999
        });
        // generate modifyLiquidities data
        bytes memory collectData = abi.encode(
            INonfungiblePositionManager.CallbackData(
                address(this), INonfungiblePositionManager.CallbackDataType.Collect, abi.encode(collectParams)
            )
        );
        bytes[] memory data = new bytes[](1);
        data[0] = collectData;
        snapStart("NonFungiblePositionManagerBatch#collectWithoutCloseCurrency");
        nonfungiblePoolManager.modifyLiquidities(abi.encode(data), block.timestamp + 100);
        snapEnd();
    }

    function testBatchCollect() external {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            // 0 ~ 15  hookRegistrationMap = nil
            // 16 ~ 24 tickSpacing = 1
            parameters: bytes32(uint256(0x10000))
        });

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            poolKey: key,
            tickLower: 46053,
            tickUpper: 46055,
            salt: bytes32(0),
            amount0Desired: 1 ether,
            amount1Desired: 1 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: type(uint256).max
        });

        uint160 sqrtPriceX96 = uint160(10 * FixedPoint96.Q96);
        poolManager.initialize(key, sqrtPriceX96, new bytes(0));

        nonfungiblePoolManager.mint(mintParams);
        // make the LPing balance of the position non-zero
        router.donate(key, 1 ether, 1 ether, "");

        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: 1,
            recipient: address(this),
            amount0Max: 999999999999999999,
            amount1Max: 999999999999999999
        });
        // generate modifyLiquidities data
        bytes memory collectData = abi.encode(
            INonfungiblePositionManager.CallbackData(
                address(this), INonfungiblePositionManager.CallbackDataType.Collect, abi.encode(collectParams)
            )
        );
        bytes[] memory data = new bytes[](3);
        data[0] = collectData;
        // set current close data
        data[1] = abi.encode(
            INonfungiblePositionManager.CallbackData(
                address(this), INonfungiblePositionManager.CallbackDataType.CloseCurrency, abi.encode(currency0)
            )
        );
        data[2] = abi.encode(
            INonfungiblePositionManager.CallbackData(
                address(this), INonfungiblePositionManager.CallbackDataType.CloseCurrency, abi.encode(currency1)
            )
        );
        snapStart("NonFungiblePositionManagerBatch#collect");
        nonfungiblePoolManager.modifyLiquidities(abi.encode(data), block.timestamp + 100);
        snapEnd();
    }
}
