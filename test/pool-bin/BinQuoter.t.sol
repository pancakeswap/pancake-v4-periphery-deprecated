// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {PoolKey} from "pancake-v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {BinHelper} from "pancake-v4-core/src/pool-bin/libraries/BinHelper.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {BinPoolManager} from "pancake-v4-core/src/pool-bin/BinPoolManager.sol";
import {BinPoolParametersHelper} from "pancake-v4-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {Vault} from "pancake-v4-core/src/Vault.sol";
import {BinFungiblePositionManager} from "../../src/pool-bin/BinFungiblePositionManager.sol";
import {IBinFungiblePositionManager} from "../../src/pool-bin/interfaces/IBinFungiblePositionManager.sol";
import {LiquidityParamsHelper} from "./helpers/LiquidityParamsHelper.sol";
import {SafeCast} from "pancake-v4-core/src/pool-bin/libraries/math/SafeCast.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {PackedUint128Math} from "pancake-v4-core/src/pool-bin/libraries/math/PackedUint128Math.sol";
import {BinSwapRouter} from "../../src/pool-bin/BinSwapRouter.sol";
import {BinSwapRouterBase} from "../../src/pool-bin/BinSwapRouterBase.sol";
import {IBinSwapRouterBase} from "../../src/pool-bin/interfaces/IBinSwapRouterBase.sol";
import {ISwapRouterBase} from "../../src/interfaces/ISwapRouterBase.sol";
import {SwapRouterBase} from "../../src/SwapRouterBase.sol";
import {IBinQuoter} from "../../src/pool-bin/interfaces/IBinQuoter.sol";
import {BinQuoter} from "../../src/pool-bin/lens/BinQuoter.sol";

contract BinQuoterTest is Test, GasSnapshot {
    using BinPoolParametersHelper for bytes32;
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;

    bytes constant ZERO_BYTES = new bytes(0);

    PoolKey key;
    PoolKey key2;
    PoolKey key3;
    Vault vault;
    BinPoolManager poolManager;
    BinFungiblePositionManager binFungiblePositionManager;
    MockERC20 token0;
    MockERC20 token1;
    MockERC20 token2;
    bytes32 poolParam;
    BinSwapRouter router;
    WETH weth;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint24 activeId = 2 ** 23; // where token0 and token1 price is the same

    function setUp() public {
        weth = new WETH();
        vault = new Vault();
        poolManager = new BinPoolManager(IVault(address(vault)), 500000);
        vault.registerApp(address(poolManager));
        router = new BinSwapRouter(vault, poolManager, address(weth));
    }

    function testBinQuoter_LockAcquired_VaultOnly() public {
        vm.expectRevert(SwapRouterBase.NotVault.selector);
        router.lockAcquired(new bytes(0));
    }
}