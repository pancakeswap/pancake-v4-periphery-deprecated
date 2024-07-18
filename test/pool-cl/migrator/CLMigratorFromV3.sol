// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {OldVersionHelper} from "../../helpers/OldVersionHelper.sol";
import {IPancakePair} from "../../../src/interfaces/external/IPancakePair.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CLMigrator} from "../../../src/pool-cl/CLMigrator.sol";
import {ICLMigrator, IBaseMigrator} from "../../../src/pool-cl/interfaces/ICLMigrator.sol";
import {NonfungiblePositionManager} from "../../../src/pool-cl/NonfungiblePositionManager.sol";
import {Vault} from "pancake-v4-core/src/Vault.sol";
import {CLPoolManager} from "pancake-v4-core/src/pool-cl/CLPoolManager.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {CLPoolParametersHelper} from "pancake-v4-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {IPoolManager} from "pancake-v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {IV3NonfungiblePositionManager} from "../../../src/interfaces/external/IV3NonfungiblePositionManager.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IPancakeV3LikePairFactory {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
}

abstract contract CLMigratorFromV3 is OldVersionHelper, GasSnapshot {
    using CLPoolParametersHelper for bytes32;
    using PoolIdLibrary for PoolKey;

    uint160 public constant INIT_SQRT_PRICE = 79228162514264337593543950336;

    WETH weth;
    MockERC20 token0;
    MockERC20 token1;

    Vault vault;
    CLPoolManager poolManager;
    NonfungiblePositionManager nonfungiblePoolManager;
    ICLMigrator migrator;
    PoolKey poolKey;
    PoolKey poolKeyWithoutNativeToken;

    IPancakeV3LikePairFactory v3Factory;
    IV3NonfungiblePositionManager v3Nfpm;

    function _getDeployerBytecodePath() internal pure virtual returns (string memory);
    function _getFactoryBytecodePath() internal pure virtual returns (string memory);
    function _getNfpmBytecodePath() internal pure virtual returns (string memory);

    function _getContractName() internal pure virtual returns (string memory);

    function setUp() public {
        weth = new WETH();
        token0 = new MockERC20("Token0", "TKN0", 18);
        token1 = new MockERC20("Token1", "TKN1", 18);
        (token0, token1) = token0 < token1 ? (token0, token1) : (token1, token0);

        // init v4 nfpm & migrator
        vault = new Vault();
        poolManager = new CLPoolManager(vault, 3000);
        vault.registerApp(address(poolManager));
        nonfungiblePoolManager = new NonfungiblePositionManager(vault, poolManager, address(0), address(weth));
        migrator = new CLMigrator(address(weth), address(nonfungiblePoolManager));

        poolKey = PoolKey({
            // WETH after migration will be native token
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token0)),
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: 0,
            parameters: bytes32(0).setTickSpacing(10)
        });

        poolKeyWithoutNativeToken = poolKey;
        poolKeyWithoutNativeToken.currency0 = Currency.wrap(address(token0));
        poolKeyWithoutNativeToken.currency1 = Currency.wrap(address(token1));

        // make sure the contract has enough balance
        // WETH: 100 ether
        // Token: 100 ether
        // ETH: 90 ether
        deal(address(this), 1000 ether);
        weth.deposit{value: 100 ether}();
        token0.mint(address(this), 100 ether);
        token1.mint(address(this), 100 ether);

        // pcs v3
        if (bytes(_getDeployerBytecodePath()).length != 0) {
            address deployer = createContractThroughBytecode(_getDeployerBytecodePath());
            v3Factory = IPancakeV3LikePairFactory(
                createContractThroughBytecode(_getFactoryBytecodePath(), toBytes32(address(deployer)))
            );
            (bool success,) = deployer.call(abi.encodeWithSignature("setFactoryAddress(address)", address(v3Factory)));
            require(success, "setFactoryAddress failed");
            v3Nfpm = IV3NonfungiblePositionManager(
                createContractThroughBytecode(
                    _getNfpmBytecodePath(),
                    toBytes32(deployer),
                    toBytes32(address(v3Factory)),
                    toBytes32(address(weth)),
                    0
                )
            );
        } else {
            v3Factory = IPancakeV3LikePairFactory(createContractThroughBytecode(_getFactoryBytecodePath()));

            v3Nfpm = IV3NonfungiblePositionManager(
                createContractThroughBytecode(
                    _getNfpmBytecodePath(), toBytes32(address(v3Factory)), toBytes32(address(weth)), 0
                )
            );
        }

        // make sure v3Nfpm has allowance
        weth.approve(address(v3Nfpm), type(uint256).max);
        token0.approve(address(v3Nfpm), type(uint256).max);
        token1.approve(address(v3Nfpm), type(uint256).max);
    }

    function testMigrateFromV3IncludingInit() public {
        // 1. mint some liquidity to the v3 pool
        _mintV3Liquidity(address(weth), address(token0));
        assertEq(v3Nfpm.ownerOf(1), address(this));
        (,,,,,,, uint128 liquidityFromV3Before,,,,) = v3Nfpm.positions(1);
        assertGt(liquidityFromV3Before, 0);

        // 2. make sure migrator can transfer user's v3 lp token
        v3Nfpm.approve(address(migrator), 1);

        IBaseMigrator.V3PoolParams memory v3PoolParams = IBaseMigrator.V3PoolParams({
            nfp: address(v3Nfpm),
            tokenId: 1,
            liquidity: liquidityFromV3Before,
            amount0Min: 9.9 ether,
            amount1Min: 9.9 ether,
            collectFee: false,
            deadline: block.timestamp + 100
        });

        ICLMigrator.V4CLPoolParams memory v4MintParams = ICLMigrator.V4CLPoolParams({
            poolKey: poolKey,
            tickLower: -100,
            tickUpper: 100,
            salt: bytes32(0),
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp + 100
        });

        // 3. multicall, combine initialize and migrateFromV3
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(migrator.initialize.selector, poolKey, INIT_SQRT_PRICE, bytes(""));
        data[1] = abi.encodeWithSelector(migrator.migrateFromV3.selector, v3PoolParams, v4MintParams, 0, 0);
        snapStart(string(abi.encodePacked(_getContractName(), "#testMigrateFromV3IncludingInit")));
        migrator.multicall(data);
        snapEnd();

        // necessary checks
        // v3 liqudity should be 0
        (,,,,,,, uint128 liquidityFromV3After,,,,) = v3Nfpm.positions(1);
        assertEq(liquidityFromV3After, 0);

        // make sure liuqidty is minted to the correct pool
        assertEq(nonfungiblePoolManager.ownerOf(1), address(this));
        (
            ,
            ,
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
        ) = nonfungiblePoolManager.positions(1);

        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(poolKey.toId()));
        assertEq(Currency.unwrap(currency0), address(0));
        assertEq(Currency.unwrap(currency1), address(token0));
        assertEq(fee, 0);
        assertEq(tickLower, -100);
        assertEq(tickUpper, 100);
        assertEq(liquidity, 2005104164790028032677);
        assertEq(feeGrowthInside0LastX128, 0);
        assertEq(feeGrowthInside1LastX128, 0);
        assertEq(tokensOwed0, 0);
        assertEq(tokensOwed1, 0);
        assertEq(salt, bytes32(0));
        assertApproxEqAbs(address(vault).balance, 10 ether, 0.000001 ether);
        assertApproxEqAbs(token0.balanceOf(address(vault)), 10 ether, 0.000001 ether);
    }

    function testMigrateFromV3TokenMismatch() public {
        // 1. mint some liquidity to the v3 pool
        _mintV3Liquidity(address(weth), address(token0));
        assertEq(v3Nfpm.ownerOf(1), address(this));
        (,,,,,,, uint128 liquidityFromV3Before,,,,) = v3Nfpm.positions(1);

        // 2. make sure migrator can transfer user's v3 lp token
        v3Nfpm.approve(address(migrator), 1);

        IBaseMigrator.V3PoolParams memory v3PoolParams = IBaseMigrator.V3PoolParams({
            nfp: address(v3Nfpm),
            tokenId: 1,
            liquidity: liquidityFromV3Before,
            amount0Min: 9.9 ether,
            amount1Min: 9.9 ether,
            collectFee: false,
            deadline: block.timestamp + 100
        });

        // v3 weth, token0
        // v4 ETH, token1
        PoolKey memory poolKeyMismatch = poolKey;
        poolKeyMismatch.currency1 = Currency.wrap(address(token1));
        ICLMigrator.V4CLPoolParams memory v4MintParams = ICLMigrator.V4CLPoolParams({
            poolKey: poolKeyMismatch,
            tickLower: -100,
            tickUpper: 100,
            salt: bytes32(0),
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp + 100
        });

        // 3. multicall, combine initialize and migrateFromV3
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(migrator.initialize.selector, poolKey, INIT_SQRT_PRICE, bytes(""));
        data[1] = abi.encodeWithSelector(migrator.migrateFromV3.selector, v3PoolParams, v4MintParams, 0, 0);
        vm.expectRevert();
        migrator.multicall(data);

        {
            // v3 weth, token0
            // v4 token0, token1
            poolKeyMismatch.currency0 = Currency.wrap(address(token0));
            poolKeyMismatch.currency1 = Currency.wrap(address(token1));
            v4MintParams.poolKey = poolKeyMismatch;
            data = new bytes[](2);
            data[0] = abi.encodeWithSelector(migrator.initialize.selector, poolKey, INIT_SQRT_PRICE, bytes(""));
            data[1] = abi.encodeWithSelector(migrator.migrateFromV3.selector, v3PoolParams, v4MintParams, 0, 0);
            vm.expectRevert();
            migrator.multicall(data);
        }
    }

    function testMigrateFromV3WithoutInit() public {
        // 1. mint some liquidity to the v3 pool
        _mintV3Liquidity(address(weth), address(token0));
        assertEq(v3Nfpm.ownerOf(1), address(this));
        (,,,,,,, uint128 liquidityFromV3Before,,,,) = v3Nfpm.positions(1);
        assertGt(liquidityFromV3Before, 0);

        // 2. make sure migrator can transfer user's v3 lp token
        v3Nfpm.approve(address(migrator), 1);

        // 3. init the pool
        nonfungiblePoolManager.initialize(poolKey, INIT_SQRT_PRICE, bytes(""));

        IBaseMigrator.V3PoolParams memory v3PoolParams = IBaseMigrator.V3PoolParams({
            nfp: address(v3Nfpm),
            tokenId: 1,
            liquidity: liquidityFromV3Before,
            amount0Min: 9.9 ether,
            amount1Min: 9.9 ether,
            collectFee: false,
            deadline: block.timestamp + 100
        });

        ICLMigrator.V4CLPoolParams memory v4MintParams = ICLMigrator.V4CLPoolParams({
            poolKey: poolKey,
            tickLower: -100,
            tickUpper: 100,
            salt: bytes32(0),
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp + 100
        });

        // 4. migrateFromV3 directly given pool has been initialized
        snapStart(string(abi.encodePacked(_getContractName(), "#testMigrateFromV3WithoutInit")));
        migrator.migrateFromV3(v3PoolParams, v4MintParams, 0, 0);
        snapEnd();

        // necessary checks
        // v3 liqudity should be 0
        (,,,,,,, uint128 liquidityFromV3After,,,,) = v3Nfpm.positions(1);
        assertEq(liquidityFromV3After, 0);

        // make sure liuqidty is minted to the correct pool
        assertEq(nonfungiblePoolManager.ownerOf(1), address(this));
        (
            ,
            ,
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
        ) = nonfungiblePoolManager.positions(1);

        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(poolKey.toId()));
        assertEq(Currency.unwrap(currency0), address(0));
        assertEq(Currency.unwrap(currency1), address(token0));
        assertEq(fee, 0);
        assertEq(tickLower, -100);
        assertEq(tickUpper, 100);
        assertEq(liquidity, 2005104164790028032677);
        assertEq(feeGrowthInside0LastX128, 0);
        assertEq(feeGrowthInside1LastX128, 0);
        assertEq(tokensOwed0, 0);
        assertEq(tokensOwed1, 0);
        assertEq(salt, bytes32(0));
        assertApproxEqAbs(address(vault).balance, 10 ether, 0.000001 ether);
        assertApproxEqAbs(token0.balanceOf(address(vault)), 10 ether, 0.000001 ether);
    }

    function testMigrateFromV3WithoutNativeToken() public {
        // 1. mint some liquidity to the v3 pool
        _mintV3Liquidity(address(token0), address(token1));

        assertEq(v3Nfpm.ownerOf(1), address(this));
        (,,,,,,, uint128 liquidityFromV3Before,,,,) = v3Nfpm.positions(1);
        assertGt(liquidityFromV3Before, 0);

        // 2. make sure migrator can transfer user's v3 lp token
        v3Nfpm.approve(address(migrator), 1);

        // 3. initialize the pool
        migrator.initialize(poolKeyWithoutNativeToken, INIT_SQRT_PRICE, bytes(""));

        IBaseMigrator.V3PoolParams memory v3PoolParams = IBaseMigrator.V3PoolParams({
            nfp: address(v3Nfpm),
            tokenId: 1,
            liquidity: liquidityFromV3Before,
            amount0Min: 9.9 ether,
            amount1Min: 9.9 ether,
            collectFee: false,
            deadline: block.timestamp + 100
        });

        ICLMigrator.V4CLPoolParams memory v4MintParams = ICLMigrator.V4CLPoolParams({
            poolKey: poolKeyWithoutNativeToken,
            tickLower: -100,
            tickUpper: 100,
            salt: bytes32(0),
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp + 100
        });

        // 4. migrate from v3 to v4
        snapStart(string(abi.encodePacked(_getContractName(), "#testMigrateFromV3WithoutNativeToken")));
        migrator.migrateFromV3(v3PoolParams, v4MintParams, 0, 0);
        snapEnd();

        // necessary checks
        // v3 liqudity should be 0
        (,,,,,,, uint128 liquidityFromV3After,,,,) = v3Nfpm.positions(1);
        assertEq(liquidityFromV3After, 0);

        // make sure liuqidty is minted to the correct pool
        assertEq(nonfungiblePoolManager.ownerOf(1), address(this));
        (
            ,
            ,
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
        ) = nonfungiblePoolManager.positions(1);

        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(poolKeyWithoutNativeToken.toId()));
        assertEq(Currency.unwrap(currency0), address(token0));
        assertEq(Currency.unwrap(currency1), address(token1));
        assertEq(fee, 0);
        assertEq(tickLower, -100);
        assertEq(tickUpper, 100);
        assertEq(liquidity, 2005104164790028032677);
        assertEq(feeGrowthInside0LastX128, 0);
        assertEq(feeGrowthInside1LastX128, 0);
        assertEq(tokensOwed0, 0);
        assertEq(tokensOwed1, 0);
        assertEq(salt, bytes32(0));
        assertApproxEqAbs(token0.balanceOf(address(vault)), 10 ether, 0.000001 ether);
        assertApproxEqAbs(token1.balanceOf(address(vault)), 10 ether, 0.000001 ether);
    }

    function testMigrateFromV3AddExtraAmount() public {
        // 1. mint some liquidity to the v3 pool
        _mintV3Liquidity(address(weth), address(token0));
        assertEq(v3Nfpm.ownerOf(1), address(this));
        (,,,,,,, uint128 liquidityFromV3Before,,,,) = v3Nfpm.positions(1);
        assertGt(liquidityFromV3Before, 0);

        // 2. make sure migrator can transfer user's v3 lp token
        v3Nfpm.approve(address(migrator), 1);

        // 3. init the pool
        nonfungiblePoolManager.initialize(poolKey, INIT_SQRT_PRICE, bytes(""));

        IBaseMigrator.V3PoolParams memory v3PoolParams = IBaseMigrator.V3PoolParams({
            nfp: address(v3Nfpm),
            tokenId: 1,
            liquidity: liquidityFromV3Before,
            amount0Min: 9.9 ether,
            amount1Min: 9.9 ether,
            collectFee: false,
            deadline: block.timestamp + 100
        });

        ICLMigrator.V4CLPoolParams memory v4MintParams = ICLMigrator.V4CLPoolParams({
            poolKey: poolKey,
            tickLower: -100,
            tickUpper: 100,
            salt: bytes32(0),
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp + 100
        });

        uint256 balance0Before = address(this).balance;
        uint256 balance1Before = token0.balanceOf(address(this));

        IERC20(address(token0)).approve(address(migrator), 20 ether);
        // 4. migrate from v3 to v4
        migrator.migrateFromV3{value: 20 ether}(v3PoolParams, v4MintParams, 20 ether, 20 ether);

        // necessary checks
        // consumed extra 20 ether from user
        assertApproxEqAbs(balance0Before - address(this).balance, 20 ether, 0.000001 ether);
        assertEq(balance1Before - token0.balanceOf(address(this)), 20 ether);
        // WETH balance unchanged
        assertEq(weth.balanceOf(address(this)), 90 ether);

        // v3 liqudity should be 0
        (,,,,,,, uint128 liquidityFromV3After,,,,) = v3Nfpm.positions(1);
        assertEq(liquidityFromV3After, 0);

        // make sure liuqidty is minted to the correct pool
        assertEq(nonfungiblePoolManager.ownerOf(1), address(this));
        (
            ,
            ,
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
        ) = nonfungiblePoolManager.positions(1);

        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(poolKey.toId()));
        assertEq(Currency.unwrap(currency0), address(0));
        assertEq(Currency.unwrap(currency1), address(token0));
        assertEq(fee, 0);
        assertEq(tickLower, -100);
        assertEq(tickUpper, 100);
        // liquidity is 3 times of the original
        assertApproxEqAbs(liquidity, 2005104164790028032677 * 3, 0.000001 ether);
        assertEq(feeGrowthInside0LastX128, 0);
        assertEq(feeGrowthInside1LastX128, 0);
        assertEq(tokensOwed0, 0);
        assertEq(tokensOwed1, 0);
        assertEq(salt, bytes32(0));
        assertApproxEqAbs(address(vault).balance, 30 ether, 0.000001 ether);
        assertApproxEqAbs(token0.balanceOf(address(vault)), 30 ether, 0.000001 ether);
    }

    function testMigrateFromV3AddExtraAmountThroughWETH() public {
        // 1. mint some liquidity to the v3 pool
        _mintV3Liquidity(address(weth), address(token0));
        assertEq(v3Nfpm.ownerOf(1), address(this));
        (,,,,,,, uint128 liquidityFromV3Before,,,,) = v3Nfpm.positions(1);
        assertGt(liquidityFromV3Before, 0);

        // 2. make sure migrator can transfer user's v3 lp token
        v3Nfpm.approve(address(migrator), 1);

        // 3. init the pool
        nonfungiblePoolManager.initialize(poolKey, INIT_SQRT_PRICE, bytes(""));

        IBaseMigrator.V3PoolParams memory v3PoolParams = IBaseMigrator.V3PoolParams({
            nfp: address(v3Nfpm),
            tokenId: 1,
            liquidity: liquidityFromV3Before,
            amount0Min: 9.9 ether,
            amount1Min: 9.9 ether,
            collectFee: false,
            deadline: block.timestamp + 100
        });

        ICLMigrator.V4CLPoolParams memory v4MintParams = ICLMigrator.V4CLPoolParams({
            poolKey: poolKey,
            tickLower: -100,
            tickUpper: 100,
            salt: bytes32(0),
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp + 100
        });

        uint256 balance0Before = address(this).balance;
        uint256 balance1Before = token0.balanceOf(address(this));

        weth.approve(address(migrator), 20 ether);
        IERC20(address(token0)).approve(address(migrator), 20 ether);
        // 4. migrate from v3 to v4, not sending ETH denotes pay by WETH
        migrator.migrateFromV3(v3PoolParams, v4MintParams, 20 ether, 20 ether);

        // necessary checks
        // consumed extra 20 ether from user
        // native token balance unchanged
        assertApproxEqAbs(balance0Before - address(this).balance, 0 ether, 0.000001 ether);
        assertEq(balance1Before - token0.balanceOf(address(this)), 20 ether);
        // consumed 20 ether WETH
        assertEq(weth.balanceOf(address(this)), 70 ether);

        // v3 liqudity should be 0
        (,,,,,,, uint128 liquidityFromV3After,,,,) = v3Nfpm.positions(1);
        assertEq(liquidityFromV3After, 0);

        // make sure liuqidty is minted to the correct pool
        assertEq(nonfungiblePoolManager.ownerOf(1), address(this));
        (
            ,
            ,
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
        ) = nonfungiblePoolManager.positions(1);

        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(poolKey.toId()));
        assertEq(Currency.unwrap(currency0), address(0));
        assertEq(Currency.unwrap(currency1), address(token0));
        assertEq(fee, 0);
        assertEq(tickLower, -100);
        assertEq(tickUpper, 100);
        // liquidity is 3 times of the original
        assertApproxEqAbs(liquidity, 2005104164790028032677 * 3, 0.000001 ether);
        assertEq(feeGrowthInside0LastX128, 0);
        assertEq(feeGrowthInside1LastX128, 0);
        assertEq(tokensOwed0, 0);
        assertEq(tokensOwed1, 0);
        assertEq(salt, bytes32(0));
        assertApproxEqAbs(address(vault).balance, 30 ether, 0.000001 ether);
        assertApproxEqAbs(token0.balanceOf(address(vault)), 30 ether, 0.000001 ether);
    }

    function testMigrateFromV3Refund() public {
        // 1. mint some liquidity to the v3 pool
        // 10 ether WETH, 5 ether token0
        _mintV3Liquidity(address(weth), address(token0), 10 ether, 5 ether);
        assertEq(v3Nfpm.ownerOf(1), address(this));
        (,,,,,,, uint128 liquidityFromV3Before,,,,) = v3Nfpm.positions(1);
        assertGt(liquidityFromV3Before, 0);

        // 2. make sure migrator can transfer user's v3 lp token
        v3Nfpm.approve(address(migrator), 1);

        // 3. init the pool
        nonfungiblePoolManager.initialize(poolKey, INIT_SQRT_PRICE, bytes(""));

        IBaseMigrator.V3PoolParams memory v3PoolParams = IBaseMigrator.V3PoolParams({
            nfp: address(v3Nfpm),
            tokenId: 1,
            liquidity: liquidityFromV3Before,
            amount0Min: 0,
            amount1Min: 0,
            collectFee: false,
            deadline: block.timestamp + 100
        });

        ICLMigrator.V4CLPoolParams memory v4MintParams = ICLMigrator.V4CLPoolParams({
            poolKey: poolKey,
            tickLower: -100,
            tickUpper: 100,
            salt: bytes32(0),
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp + 100
        });

        uint256 balance0Before = address(this).balance;
        uint256 balance1Before = token0.balanceOf(address(this));

        // 4. migrate from v3 to v4, not sending ETH denotes pay by WETH
        migrator.migrateFromV3(v3PoolParams, v4MintParams, 0, 0);

        // necessary checks
        // refund 5 ether in the form of native token
        assertApproxEqAbs(address(this).balance - balance0Before, 5.0 ether, 0.1 ether);
        assertEq(balance1Before - token0.balanceOf(address(this)), 0 ether);
        // WETH balance unchanged
        assertApproxEqAbs(weth.balanceOf(address(this)), 90 ether, 0.1 ether);

        // v3 liqudity should be 0
        (,,,,,,, uint128 liquidityFromV3After,,,,) = v3Nfpm.positions(1);
        assertEq(liquidityFromV3After, 0);

        // make sure liuqidty is minted to the correct pool
        assertEq(nonfungiblePoolManager.ownerOf(1), address(this));
        (
            ,
            ,
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
        ) = nonfungiblePoolManager.positions(1);

        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(poolKey.toId()));
        assertEq(Currency.unwrap(currency0), address(0));
        assertEq(Currency.unwrap(currency1), address(token0));
        assertEq(fee, 0);
        assertEq(tickLower, -100);
        assertEq(tickUpper, 100);
        // liquidity is half of the original
        assertApproxEqAbs(liquidity * 2, 2005104164790028032677, 0.1 ether);
        assertEq(feeGrowthInside0LastX128, 0);
        assertEq(feeGrowthInside1LastX128, 0);
        assertEq(tokensOwed0, 0);
        assertEq(tokensOwed1, 0);
        assertEq(salt, bytes32(0));
        assertApproxEqAbs(address(vault).balance, 5 ether, 0.1 ether);
        assertApproxEqAbs(token0.balanceOf(address(vault)), 5 ether, 0.1 ether);
    }

    function testMigrateFromV3RefundNonNativeToken() public {
        // 1. mint some liquidity to the v3 pool
        // 10 ether token0, 5 ether token1
        _mintV3Liquidity(address(token0), address(token1), 10 ether, 5 ether);
        assertEq(v3Nfpm.ownerOf(1), address(this));
        (,,,,,,, uint128 liquidityFromV3Before,,,,) = v3Nfpm.positions(1);
        assertGt(liquidityFromV3Before, 0);

        // 2. make sure migrator can transfer user's v3 lp token
        v3Nfpm.approve(address(migrator), 1);

        // 3. init the pool
        nonfungiblePoolManager.initialize(poolKeyWithoutNativeToken, INIT_SQRT_PRICE, bytes(""));

        IBaseMigrator.V3PoolParams memory v3PoolParams = IBaseMigrator.V3PoolParams({
            nfp: address(v3Nfpm),
            tokenId: 1,
            liquidity: liquidityFromV3Before,
            amount0Min: 0,
            amount1Min: 0,
            collectFee: false,
            deadline: block.timestamp + 100
        });

        ICLMigrator.V4CLPoolParams memory v4MintParams = ICLMigrator.V4CLPoolParams({
            poolKey: poolKeyWithoutNativeToken,
            tickLower: -100,
            tickUpper: 100,
            salt: bytes32(0),
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp + 100
        });

        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 balance1Before = token1.balanceOf(address(this));

        // 4. migrate from v3 to v4
        migrator.migrateFromV3(v3PoolParams, v4MintParams, 0, 0);

        // necessary checks

        // refund 5 ether of token0
        assertApproxEqAbs(token0.balanceOf(address(this)) - balance0Before, 5 ether, 0.1 ether);
        assertEq(balance1Before - token1.balanceOf(address(this)), 0 ether);
        // WETH balance unchanged
        assertEq(weth.balanceOf(address(this)), 100 ether);

        // v3 liqudity should be 0
        (,,,,,,, uint128 liquidityFromV3After,,,,) = v3Nfpm.positions(1);
        assertEq(liquidityFromV3After, 0);

        // make sure liuqidty is minted to the correct pool
        assertEq(nonfungiblePoolManager.ownerOf(1), address(this));
        (
            ,
            ,
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
        ) = nonfungiblePoolManager.positions(1);

        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(poolKeyWithoutNativeToken.toId()));
        assertEq(Currency.unwrap(currency0), address(token0));
        assertEq(Currency.unwrap(currency1), address(token1));
        assertEq(fee, 0);
        assertEq(tickLower, -100);
        assertEq(tickUpper, 100);
        // liquidity is half of the original
        assertApproxEqAbs(liquidity * 2, 2005104164790028032677, 0.1 ether);
        assertEq(feeGrowthInside0LastX128, 0);
        assertEq(feeGrowthInside1LastX128, 0);
        assertEq(tokensOwed0, 0);
        assertEq(tokensOwed1, 0);
        assertEq(salt, bytes32(0));
        assertApproxEqAbs(token0.balanceOf(address(vault)), 5 ether, 0.1 ether);
        assertApproxEqAbs(token1.balanceOf(address(vault)), 5 ether, 0.1 ether);
    }

    function testMigrateFromV3FromNonOwner() public {
        // 1. mint some liquidity to the v3 pool
        _mintV3Liquidity(address(weth), address(token0));
        assertEq(v3Nfpm.ownerOf(1), address(this));
        (,,,,,,, uint128 liquidityFromV3Before,,,,) = v3Nfpm.positions(1);
        assertGt(liquidityFromV3Before, 0);

        // 2. make sure migrator can transfer user's v3 lp token
        v3Nfpm.approve(address(migrator), 1);

        // 3. init the pool
        nonfungiblePoolManager.initialize(poolKey, INIT_SQRT_PRICE, bytes(""));

        IBaseMigrator.V3PoolParams memory v3PoolParams = IBaseMigrator.V3PoolParams({
            nfp: address(v3Nfpm),
            tokenId: 1,
            // half of the liquidity
            liquidity: liquidityFromV3Before / 2,
            amount0Min: 9.9 ether / 2,
            amount1Min: 9.9 ether / 2,
            collectFee: false,
            deadline: block.timestamp + 100
        });

        ICLMigrator.V4CLPoolParams memory v4MintParams = ICLMigrator.V4CLPoolParams({
            poolKey: poolKey,
            tickLower: -100,
            tickUpper: 100,
            salt: bytes32(0),
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp + 100
        });

        // 4. migrate half
        migrator.migrateFromV3(v3PoolParams, v4MintParams, 0, 0);

        // make sure there are still liquidity left in v3 position token
        (,,,,,,, uint128 liquidityFromV3After,,,,) = v3Nfpm.positions(1);
        assertEq(liquidityFromV3After, liquidityFromV3Before - liquidityFromV3Before / 2);

        // 5. make sure non-owner can't migrate the rest
        vm.expectRevert(IBaseMigrator.NOT_TOKEN_OWNER.selector);
        vm.prank(makeAddr("someone"));
        migrator.migrateFromV3(v3PoolParams, v4MintParams, 0, 0);
    }

    function testMigrateFromV3ThroughOffchainSign() public {
        // 1. mint some liquidity to the v3 pool
        _mintV3Liquidity(address(weth), address(token0));
        assertEq(v3Nfpm.ownerOf(1), address(this));
        (uint96 nonce,,,,,,, uint128 liquidityFromV3Before,,,,) = v3Nfpm.positions(1);
        assertGt(liquidityFromV3Before, 0);

        // 2. make sure migrator can transfer user's v3 lp token through offchain sign
        // v3Nfpm.approve(address(migrator), 1);
        (address userAddr, uint256 userPrivateKey) = makeAddrAndKey("user");

        // 2.a transfer the lp token to the user
        v3Nfpm.transferFrom(address(this), userAddr, 1);

        uint256 ddl = block.timestamp + 100;
        // 2.b prepare the hash
        bytes32 structHash = keccak256(abi.encode(v3Nfpm.PERMIT_TYPEHASH(), address(migrator), 1, nonce, ddl));
        bytes32 hash = keccak256(abi.encodePacked("\x19\x01", v3Nfpm.DOMAIN_SEPARATOR(), structHash));

        // 2.c generate the signature
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, hash);

        IBaseMigrator.V3PoolParams memory v3PoolParams = IBaseMigrator.V3PoolParams({
            nfp: address(v3Nfpm),
            tokenId: 1,
            liquidity: liquidityFromV3Before,
            amount0Min: 9.9 ether,
            amount1Min: 9.9 ether,
            collectFee: false,
            deadline: block.timestamp + 100
        });

        ICLMigrator.V4CLPoolParams memory v4MintParams = ICLMigrator.V4CLPoolParams({
            poolKey: poolKey,
            tickLower: -100,
            tickUpper: 100,
            salt: bytes32(0),
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp + 100
        });

        // 3. multicall, combine selfPermitERC721, initialize and migrateFromV3
        bytes[] memory data = new bytes[](3);
        data[0] = abi.encodeWithSelector(migrator.selfPermitERC721.selector, v3Nfpm, 1, ddl, v, r, s);
        data[1] = abi.encodeWithSelector(migrator.initialize.selector, poolKey, INIT_SQRT_PRICE, bytes(""));
        data[2] = abi.encodeWithSelector(migrator.migrateFromV3.selector, v3PoolParams, v4MintParams, 0, 0);
        vm.prank(userAddr);
        migrator.multicall(data);

        // necessary checks
        // v3 liqudity should be 0
        (,,,,,,, uint128 liquidityFromV3After,,,,) = v3Nfpm.positions(1);
        assertEq(liquidityFromV3After, 0);

        // make sure liuqidty is minted to the correct pool
        assertEq(nonfungiblePoolManager.ownerOf(1), address(this));
        (
            ,
            ,
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
        ) = nonfungiblePoolManager.positions(1);

        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(poolKey.toId()));
        assertEq(Currency.unwrap(currency0), address(0));
        assertEq(Currency.unwrap(currency1), address(token0));
        assertEq(fee, 0);
        assertEq(tickLower, -100);
        assertEq(tickUpper, 100);
        assertEq(liquidity, 2005104164790028032677);
        assertEq(feeGrowthInside0LastX128, 0);
        assertEq(feeGrowthInside1LastX128, 0);
        assertEq(tokensOwed0, 0);
        assertEq(tokensOwed1, 0);
        assertEq(salt, bytes32(0));
        assertApproxEqAbs(address(vault).balance, 10 ether, 0.000001 ether);
        assertApproxEqAbs(token0.balanceOf(address(vault)), 10 ether, 0.000001 ether);
    }

    function testMigrateFromV3ThroughOffchainSignPayWithETH() public {
        // 1. mint some liquidity to the v3 pool
        _mintV3Liquidity(address(weth), address(token0));
        assertEq(v3Nfpm.ownerOf(1), address(this));
        (uint96 nonce,,,,,,, uint128 liquidityFromV3Before,,,,) = v3Nfpm.positions(1);
        assertGt(liquidityFromV3Before, 0);

        // 2. make sure migrator can transfer user's v3 lp token through offchain sign
        // v3Nfpm.approve(address(migrator), 1);
        (address userAddr, uint256 userPrivateKey) = makeAddrAndKey("user");

        // 2.a transfer the lp token to the user
        v3Nfpm.transferFrom(address(this), userAddr, 1);

        uint256 ddl = block.timestamp + 100;
        // 2.b prepare the hash
        bytes32 structHash = keccak256(abi.encode(v3Nfpm.PERMIT_TYPEHASH(), address(migrator), 1, nonce, ddl));
        bytes32 hash = keccak256(abi.encodePacked("\x19\x01", v3Nfpm.DOMAIN_SEPARATOR(), structHash));

        // 2.c generate the signature
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, hash);

        IBaseMigrator.V3PoolParams memory v3PoolParams = IBaseMigrator.V3PoolParams({
            nfp: address(v3Nfpm),
            tokenId: 1,
            liquidity: liquidityFromV3Before,
            amount0Min: 9.9 ether,
            amount1Min: 9.9 ether,
            collectFee: false,
            deadline: block.timestamp + 100
        });

        ICLMigrator.V4CLPoolParams memory v4MintParams = ICLMigrator.V4CLPoolParams({
            poolKey: poolKey,
            tickLower: -100,
            tickUpper: 100,
            salt: bytes32(0),
            amount0Min: 0 ether,
            amount1Min: 0 ether,
            recipient: address(this),
            deadline: block.timestamp + 100
        });

        // make the guy rich
        token0.transfer(userAddr, 10 ether);
        deal(userAddr, 10 ether);

        vm.prank(userAddr);
        token0.approve(address(migrator), 10 ether);

        // 3. multicall, combine selfPermitERC721, initialize and migrateFromV3
        bytes[] memory data = new bytes[](3);
        data[0] = abi.encodeWithSelector(migrator.selfPermitERC721.selector, v3Nfpm, 1, ddl, v, r, s);
        data[1] = abi.encodeWithSelector(migrator.initialize.selector, poolKey, INIT_SQRT_PRICE, bytes(""));
        data[2] =
            abi.encodeWithSelector(migrator.migrateFromV3.selector, v3PoolParams, v4MintParams, 10 ether, 10 ether);
        vm.prank(userAddr);
        migrator.multicall{value: 10 ether}(data);

        // necessary checks
        // v3 liqudity should be 0
        (,,,,,,, uint128 liquidityFromV3After,,,,) = v3Nfpm.positions(1);
        assertEq(liquidityFromV3After, 0);

        // make sure liuqidty is minted to the correct pool
        assertEq(nonfungiblePoolManager.ownerOf(1), address(this));
        (
            ,
            ,
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
        ) = nonfungiblePoolManager.positions(1);

        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(poolKey.toId()));
        assertEq(Currency.unwrap(currency0), address(0));
        assertEq(Currency.unwrap(currency1), address(token0));
        assertEq(fee, 0);
        assertEq(tickLower, -100);
        assertEq(tickUpper, 100);
        assertEq(liquidity, 4010208329580056065555);
        assertEq(feeGrowthInside0LastX128, 0);
        assertEq(feeGrowthInside1LastX128, 0);
        assertEq(tokensOwed0, 0);
        assertEq(tokensOwed1, 0);
        assertEq(salt, bytes32(0));
        assertApproxEqAbs(address(vault).balance, 20 ether, 0.000001 ether);
        assertApproxEqAbs(token0.balanceOf(address(vault)), 20 ether, 0.000001 ether);
    }

    function _mintV3Liquidity(address _token0, address _token1) internal {
        (_token0, _token1) = _token0 < _token1 ? (_token0, _token1) : (_token1, _token0);
        v3Nfpm.createAndInitializePoolIfNecessary(_token0, _token1, 500, INIT_SQRT_PRICE);
        IV3NonfungiblePositionManager.MintParams memory mintParams = IV3NonfungiblePositionManager.MintParams({
            token0: _token0,
            token1: _token1,
            fee: 500,
            tickLower: -100,
            tickUpper: 100,
            amount0Desired: 10 ether,
            amount1Desired: 10 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp + 100
        });

        v3Nfpm.mint(mintParams);
    }

    function _mintV3Liquidity(address _token0, address _token1, uint256 amount0, uint256 amount1) internal {
        int24 tickLower;
        int24 tickUpper;
        if (_token0 < _token1) {
            tickLower = -100;
            tickUpper = 200;
        } else {
            (_token0, _token1) = (_token1, _token0);
            (amount0, amount1) = (amount1, amount0);
            tickLower = -200;
            tickUpper = 100;
        }
        v3Nfpm.createAndInitializePoolIfNecessary(_token0, _token1, 500, INIT_SQRT_PRICE);

        IV3NonfungiblePositionManager.MintParams memory mintParams = IV3NonfungiblePositionManager.MintParams({
            token0: _token0,
            token1: _token1,
            fee: 500,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: amount0 - 0.1 ether,
            amount1Min: amount1 - 0.1 ether,
            recipient: address(this),
            deadline: block.timestamp + 100
        });

        v3Nfpm.mint(mintParams);
    }

    receive() external payable {}
}
