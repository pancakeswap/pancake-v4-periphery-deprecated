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

interface IPancakeV2LikePairFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

abstract contract CLMigratorFromV2 is OldVersionHelper, GasSnapshot {
    using CLPoolParametersHelper for bytes32;
    using PoolIdLibrary for PoolKey;

    WETH weth;
    MockERC20 token0;
    MockERC20 token1;

    Vault vault;
    CLPoolManager poolManager;
    NonfungiblePositionManager nonfungiblePoolManager;
    ICLMigrator migrator;
    PoolKey poolKey;
    PoolKey poolKeyWithoutNativeToken;

    IPancakeV2LikePairFactory v2Factory;
    IPancakePair v2Pair;
    IPancakePair v2PairWithoutNativeToken;

    function _getBytecodePath() internal pure virtual returns (string memory);

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

        v2Factory = IPancakeV2LikePairFactory(createContractThroughBytecode(_getBytecodePath()));
        v2Pair = IPancakePair(v2Factory.createPair(address(weth), address(token0)));
        v2PairWithoutNativeToken = IPancakePair(v2Factory.createPair(address(token0), address(token1)));
    }

    function testMigrateFromV2IncludingInit() public {
        // 1. mint some liquidity to the v2 pair
        _mintV2Liquidity(v2Pair);
        uint256 lpTokenBefore = v2Pair.balanceOf(address(this));
        assertGt(lpTokenBefore, 0);

        // 2. make sure migrator can transfer user's v2 lp token
        v2Pair.approve(address(migrator), lpTokenBefore);

        IBaseMigrator.V2PoolParams memory v2PoolParams = IBaseMigrator.V2PoolParams({
            pair: address(v2Pair),
            migrateAmount: lpTokenBefore,
            // minor precision loss is acceptable
            amount0Min: 9.999 ether,
            amount1Min: 9.999 ether
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

        // 3. multicall, combine initialize and migrateFromV2
        uint160 initSqrtPrice = 79228162514264337593543950336;
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(migrator.initialize.selector, poolKey, initSqrtPrice, bytes(""));
        data[1] = abi.encodeWithSelector(migrator.migrateFromV2.selector, v2PoolParams, v4MintParams, 0, 0);
        snapStart(string(abi.encodePacked(_getContractName(), "#testMigrateFromV2IncludingInit")));
        migrator.multicall(data);
        snapEnd();

        // necessary checks
        // v2 pair should be burned already
        assertEq(v2Pair.balanceOf(address(this)), 0);

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
        assertEq(liquidity, 2005104164790027832367);
        assertEq(feeGrowthInside0LastX128, 0);
        assertEq(feeGrowthInside1LastX128, 0);
        assertEq(tokensOwed0, 0);
        assertEq(tokensOwed1, 0);
        assertEq(salt, bytes32(0));
        assertApproxEqAbs(address(vault).balance, 10 ether, 0.000001 ether);
        assertApproxEqAbs(token0.balanceOf(address(vault)), 10 ether, 0.000001 ether);
    }

    function testMigrateFromV2TokenMismatch() public {
        // 1. mint some liquidity to the v2 pair
        _mintV2Liquidity(v2Pair);
        uint256 lpTokenBefore = v2Pair.balanceOf(address(this));

        // 2. make sure migrator can transfer user's v2 lp token
        v2Pair.approve(address(migrator), lpTokenBefore);

        IBaseMigrator.V2PoolParams memory v2PoolParams = IBaseMigrator.V2PoolParams({
            pair: address(v2Pair),
            migrateAmount: lpTokenBefore,
            // minor precision loss is acceptable
            amount0Min: 9.999 ether,
            amount1Min: 9.999 ether
        });

        // v2 weth, token0
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

        // 3. multicall, combine initialize and migrateFromV2
        uint160 initSqrtPrice = 79228162514264337593543950336;
        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(migrator.initialize.selector, poolKeyMismatch, initSqrtPrice, bytes(""));
        data[1] = abi.encodeWithSelector(migrator.migrateFromV2.selector, v2PoolParams, v4MintParams, 0, 0);
        vm.expectRevert();
        migrator.multicall(data);

        {
            // v2 weth, token0
            // v4 token0, token1
            poolKeyMismatch.currency0 = Currency.wrap(address(token0));
            poolKeyMismatch.currency1 = Currency.wrap(address(token1));
            v4MintParams.poolKey = poolKeyMismatch;
            data = new bytes[](2);
            data[0] = abi.encodeWithSelector(migrator.initialize.selector, poolKeyMismatch, initSqrtPrice, bytes(""));
            data[1] = abi.encodeWithSelector(migrator.migrateFromV2.selector, v2PoolParams, v4MintParams, 0, 0);
            vm.expectRevert();
            migrator.multicall(data);
        }
    }

    function testMigrateFromV2WithoutInit() public {
        // 1. mint some liquidity to the v2 pair
        _mintV2Liquidity(v2Pair);
        uint256 lpTokenBefore = v2Pair.balanceOf(address(this));
        assertGt(lpTokenBefore, 0);

        // 2. make sure migrator can transfer user's v2 lp token
        v2Pair.approve(address(migrator), lpTokenBefore);

        // 3. initialize the pool
        uint160 initSqrtPrice = 79228162514264337593543950336;
        migrator.initialize(poolKey, initSqrtPrice, bytes(""));

        IBaseMigrator.V2PoolParams memory v2PoolParams = IBaseMigrator.V2PoolParams({
            pair: address(v2Pair),
            migrateAmount: lpTokenBefore,
            // minor precision loss is acceptable
            amount0Min: 9.999 ether,
            amount1Min: 9.999 ether
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

        // 4. migrate from v2 to v4
        snapStart(string(abi.encodePacked(_getContractName(), "#testMigrateFromV2WithoutInit")));
        migrator.migrateFromV2(v2PoolParams, v4MintParams, 0, 0);
        snapEnd();

        // necessary checks
        // v2 pair should be burned already
        assertEq(v2Pair.balanceOf(address(this)), 0);

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
        assertEq(liquidity, 2005104164790027832367);
        assertEq(feeGrowthInside0LastX128, 0);
        assertEq(feeGrowthInside1LastX128, 0);
        assertEq(tokensOwed0, 0);
        assertEq(tokensOwed1, 0);
        assertEq(salt, bytes32(0));
        assertApproxEqAbs(address(vault).balance, 10 ether, 0.000001 ether);
        assertApproxEqAbs(token0.balanceOf(address(vault)), 10 ether, 0.000001 ether);
    }

    function testMigrateFromV2WithoutNativeToken() public {
        // 1. mint some liquidity to the v2 pair
        _mintV2Liquidity(v2PairWithoutNativeToken);
        uint256 lpTokenBefore = v2PairWithoutNativeToken.balanceOf(address(this));
        assertGt(lpTokenBefore, 0);

        // 2. make sure migrator can transfer user's v2 lp token
        v2PairWithoutNativeToken.approve(address(migrator), lpTokenBefore);

        // 3. initialize the pool
        uint160 initSqrtPrice = 79228162514264337593543950336;
        migrator.initialize(poolKeyWithoutNativeToken, initSqrtPrice, bytes(""));

        IBaseMigrator.V2PoolParams memory v2PoolParams = IBaseMigrator.V2PoolParams({
            pair: address(v2PairWithoutNativeToken),
            migrateAmount: lpTokenBefore,
            // minor precision loss is acceptable
            amount0Min: 9.999 ether,
            amount1Min: 9.999 ether
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

        // 4. migrate from v2 to v4
        snapStart(string(abi.encodePacked(_getContractName(), "#testMigrateFromV2WithoutNativeToken")));
        migrator.migrateFromV2(v2PoolParams, v4MintParams, 0, 0);
        snapEnd();

        // necessary checks
        // v2 pair should be burned already
        assertEq(v2PairWithoutNativeToken.balanceOf(address(this)), 0);

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
        assertEq(liquidity, 2005104164790027832367);
        assertEq(feeGrowthInside0LastX128, 0);
        assertEq(feeGrowthInside1LastX128, 0);
        assertEq(tokensOwed0, 0);
        assertEq(tokensOwed1, 0);
        assertEq(salt, bytes32(0));
        assertApproxEqAbs(token0.balanceOf(address(vault)), 10 ether, 0.000001 ether);
        assertApproxEqAbs(token1.balanceOf(address(vault)), 10 ether, 0.000001 ether);
    }

    function testMigrateFromV2AddExtraAmount() public {
        // 1. mint some liquidity to the v2 pair
        _mintV2Liquidity(v2Pair);
        uint256 lpTokenBefore = v2Pair.balanceOf(address(this));
        assertGt(lpTokenBefore, 0);

        // 2. make sure migrator can transfer user's v2 lp token
        v2Pair.approve(address(migrator), lpTokenBefore);

        // 3. initialize the pool
        uint160 initSqrtPrice = 79228162514264337593543950336;
        migrator.initialize(poolKey, initSqrtPrice, bytes(""));

        IBaseMigrator.V2PoolParams memory v2PoolParams = IBaseMigrator.V2PoolParams({
            pair: address(v2Pair),
            migrateAmount: lpTokenBefore,
            // minor precision loss is acceptable
            amount0Min: 9.999 ether,
            amount1Min: 9.999 ether
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
        // 4. migrate from v2 to v4
        migrator.migrateFromV2{value: 20 ether}(v2PoolParams, v4MintParams, 20 ether, 20 ether);

        // necessary checks
        // consumed extra 20 ether from user
        assertApproxEqAbs(balance0Before - address(this).balance, 20 ether, 0.000001 ether);
        assertEq(balance1Before - token0.balanceOf(address(this)), 20 ether);
        // WETH balance unchanged
        assertEq(weth.balanceOf(address(this)), 90 ether);

        // v2 pair should be burned already
        assertEq(v2Pair.balanceOf(address(this)), 0);

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
        assertApproxEqAbs(liquidity, 2005104164790027832367 * 3, 0.000001 ether);
        assertEq(feeGrowthInside0LastX128, 0);
        assertEq(feeGrowthInside1LastX128, 0);
        assertEq(tokensOwed0, 0);
        assertEq(tokensOwed1, 0);
        assertEq(salt, bytes32(0));
        assertApproxEqAbs(address(vault).balance, 30 ether, 0.000001 ether);
        assertApproxEqAbs(token0.balanceOf(address(vault)), 30 ether, 0.000001 ether);
    }

    function testMigrateFromV2AddExtraAmountThroughWETH() public {
        // 1. mint some liquidity to the v2 pair
        _mintV2Liquidity(v2Pair);
        uint256 lpTokenBefore = v2Pair.balanceOf(address(this));
        assertGt(lpTokenBefore, 0);

        // 2. make sure migrator can transfer user's v2 lp token
        v2Pair.approve(address(migrator), lpTokenBefore);

        // 3. initialize the pool
        uint160 initSqrtPrice = 79228162514264337593543950336;
        migrator.initialize(poolKey, initSqrtPrice, bytes(""));

        IBaseMigrator.V2PoolParams memory v2PoolParams = IBaseMigrator.V2PoolParams({
            pair: address(v2Pair),
            migrateAmount: lpTokenBefore,
            // minor precision loss is acceptable
            amount0Min: 9.999 ether,
            amount1Min: 9.999 ether
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
        // 4. migrate from v2 to v4, not sending ETH denotes pay by WETH
        migrator.migrateFromV2(v2PoolParams, v4MintParams, 20 ether, 20 ether);

        // necessary checks
        // consumed extra 20 ether from user
        // native token balance unchanged
        assertApproxEqAbs(balance0Before - address(this).balance, 0 ether, 0.000001 ether);
        assertEq(balance1Before - token0.balanceOf(address(this)), 20 ether);
        // consumed 20 ether WETH
        assertEq(weth.balanceOf(address(this)), 70 ether);

        // v2 pair should be burned already
        assertEq(v2Pair.balanceOf(address(this)), 0);

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
        assertApproxEqAbs(liquidity, 2005104164790027832367 * 3, 0.000001 ether);
        assertEq(feeGrowthInside0LastX128, 0);
        assertEq(feeGrowthInside1LastX128, 0);
        assertEq(tokensOwed0, 0);
        assertEq(tokensOwed1, 0);
        assertEq(salt, bytes32(0));
        assertApproxEqAbs(address(vault).balance, 30 ether, 0.000001 ether);
        assertApproxEqAbs(token0.balanceOf(address(vault)), 30 ether, 0.000001 ether);
    }

    function testMigrateFromV2Refund() public {
        // 1. mint some liquidity to the v2 pair
        // 10 ether WETH, 5 ether token0
        // addr of weth > addr of token0, hence the order has to be reversed
        bool isWETHFirst = address(weth) < address(token0);
        if (isWETHFirst) {
            _mintV2Liquidity(v2Pair, 10 ether, 5 ether);
        } else {
            _mintV2Liquidity(v2Pair, 5 ether, 10 ether);
        }
        uint256 lpTokenBefore = v2Pair.balanceOf(address(this));
        assertGt(lpTokenBefore, 0);

        // 2. make sure migrator can transfer user's v2 lp token
        v2Pair.approve(address(migrator), lpTokenBefore);

        // 3. initialize the pool
        uint160 initSqrtPrice = 79228162514264337593543950336;
        migrator.initialize(poolKey, initSqrtPrice, bytes(""));

        IBaseMigrator.V2PoolParams memory v2PoolParams = IBaseMigrator.V2PoolParams({
            pair: address(v2Pair),
            migrateAmount: lpTokenBefore,
            // the order of token0 and token1 respect to the pair
            // but may mismatch the order of v4 pool key when WETH is invovled
            amount0Min: isWETHFirst ? 9.999 ether : 4.999 ether,
            amount1Min: isWETHFirst ? 4.999 ether : 9.999 ether
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

        // 4. migrate from v2 to v4, not sending ETH denotes pay by WETH
        migrator.migrateFromV2(v2PoolParams, v4MintParams, 0, 0);

        // necessary checks
        // refund 5 ether in the form of native token
        assertApproxEqAbs(address(this).balance - balance0Before, 5 ether, 0.000001 ether);
        assertEq(balance1Before - token0.balanceOf(address(this)), 0 ether);
        // WETH balance unchanged
        assertEq(weth.balanceOf(address(this)), 90 ether);

        // v2 pair should be burned already
        assertEq(v2Pair.balanceOf(address(this)), 0);

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
        assertApproxEqAbs(liquidity * 2, 2005104164790027832367, 0.000001 ether);
        assertEq(feeGrowthInside0LastX128, 0);
        assertEq(feeGrowthInside1LastX128, 0);
        assertEq(tokensOwed0, 0);
        assertEq(tokensOwed1, 0);
        assertEq(salt, bytes32(0));
        assertApproxEqAbs(address(vault).balance, 5 ether, 0.000001 ether);
        assertApproxEqAbs(token0.balanceOf(address(vault)), 5 ether, 0.000001 ether);
    }

    function testMigrateFromV2RefundNonNativeToken() public {
        // 1. mint some liquidity to the v2 pair
        _mintV2Liquidity(v2PairWithoutNativeToken, 10 ether, 5 ether);
        uint256 lpTokenBefore = v2PairWithoutNativeToken.balanceOf(address(this));
        assertGt(lpTokenBefore, 0);

        // 2. make sure migrator can transfer user's v2 lp token
        v2PairWithoutNativeToken.approve(address(migrator), lpTokenBefore);

        // 3. initialize the pool
        uint160 initSqrtPrice = 79228162514264337593543950336;
        migrator.initialize(poolKeyWithoutNativeToken, initSqrtPrice, bytes(""));

        IBaseMigrator.V2PoolParams memory v2PoolParams = IBaseMigrator.V2PoolParams({
            pair: address(v2PairWithoutNativeToken),
            migrateAmount: lpTokenBefore,
            // the order of token0 and token1 respect to the pair
            // but may mismatch the order of v4 pool key when WETH is invovled
            amount0Min: 9.999 ether,
            amount1Min: 4.999 ether
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

        // 4. migrate from v2 to v4
        migrator.migrateFromV2(v2PoolParams, v4MintParams, 0, 0);

        // necessary checks

        // refund 5 ether of token0
        assertApproxEqAbs(token0.balanceOf(address(this)) - balance0Before, 5 ether, 0.000001 ether);
        assertEq(balance1Before - token1.balanceOf(address(this)), 0 ether);
        // WETH balance unchanged
        assertEq(weth.balanceOf(address(this)), 100 ether);

        // v2 pair should be burned already
        assertEq(v2PairWithoutNativeToken.balanceOf(address(this)), 0);

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
        assertApproxEqAbs(liquidity * 2, 2005104164790027832367, 0.000001 ether);
        assertEq(feeGrowthInside0LastX128, 0);
        assertEq(feeGrowthInside1LastX128, 0);
        assertEq(tokensOwed0, 0);
        assertEq(tokensOwed1, 0);
        assertEq(salt, bytes32(0));
        assertApproxEqAbs(token0.balanceOf(address(vault)), 5 ether, 0.000001 ether);
        assertApproxEqAbs(token1.balanceOf(address(vault)), 5 ether, 0.000001 ether);
    }

    function _mintV2Liquidity(IPancakePair pair) public {
        IERC20(pair.token0()).transfer(address(pair), 10 ether);
        IERC20(pair.token1()).transfer(address(pair), 10 ether);

        pair.mint(address(this));
    }

    function _mintV2Liquidity(IPancakePair pair, uint256 amount0, uint256 amount1) public {
        IERC20(pair.token0()).transfer(address(pair), amount0);
        IERC20(pair.token1()).transfer(address(pair), amount1);

        pair.mint(address(this));
    }

    receive() external payable {}
}
