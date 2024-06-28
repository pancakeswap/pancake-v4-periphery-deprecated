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
import {BinPool} from "pancake-v4-core/src/pool-bin/libraries/BinPool.sol";
import {BinPoolManager} from "pancake-v4-core/src/pool-bin/BinPoolManager.sol";
import {BinPoolParametersHelper} from "pancake-v4-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {Vault} from "pancake-v4-core/src/Vault.sol";
import {BinFungiblePositionManager} from "../../src/pool-bin/BinFungiblePositionManager.sol";
import {IBinFungiblePositionManager} from "../../src/pool-bin/interfaces/IBinFungiblePositionManager.sol";
import {LiquidityParamsHelper} from "./helpers/LiquidityParamsHelper.sol";
import {SafeCast} from "pancake-v4-core/src/pool-bin/libraries/math/SafeCast.sol";
import {BeforeMintSwapHook} from "./helpers/BeforeMintSwapHook.sol";
import {PoolId, PoolIdLibrary} from "pancake-v4-core/src/types/PoolId.sol";
import {PackedUint128Math} from "pancake-v4-core/src/pool-bin/libraries/math/PackedUint128Math.sol";
import {BinSwapRouter} from "../../src/pool-bin/BinSwapRouter.sol";
import {BinSwapRouterBase} from "../../src/pool-bin/BinSwapRouterBase.sol";
import {IBinSwapRouterBase} from "../../src/pool-bin/interfaces/IBinSwapRouterBase.sol";
import {ISwapRouterBase} from "../../src/interfaces/ISwapRouterBase.sol";
import {SwapRouterBase} from "../../src/SwapRouterBase.sol";
import {PeripheryPayments} from "../../src/base/PeripheryPayments.sol";
import {PeripheryValidation} from "../../src/base/PeripheryValidation.sol";
import {IBinQuoter, BinQuoter} from "../../src/pool-bin/lens/BinQuoter.sol";
import {PathKey} from "../../src/libraries/PathKey.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract BinQuoterTest is Test, GasSnapshot, LiquidityParamsHelper {
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
    BinQuoter quoter;
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
        quoter = new BinQuoter(vault, address(poolManager));

        binFungiblePositionManager =
            new BinFungiblePositionManager(IVault(address(vault)), IBinPoolManager(address(poolManager)), address(weth));

        token0 = new MockERC20("TestA", "A", 18);
        token1 = new MockERC20("TestB", "B", 18);
        token2 = new MockERC20("TestC", "C", 18);

        // sort token
        (token0, token1) = token0 > token1 ? (token1, token0) : (token0, token1);
        if (token2 < token0) {
            (token0, token1, token2) = (token2, token0, token1);
        } else if (token2 < token1) {
            (token1, token2) = (token2, token1);
        }

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            hooks: IHooks(address(0)),
            poolManager: IBinPoolManager(address(poolManager)),
            fee: uint24(3000), // 3000 = 0.3%
            parameters: poolParam.setBinStep(10) // binStep
        });
        key2 = PoolKey({
            currency0: Currency.wrap(address(token1)),
            currency1: Currency.wrap(address(token2)),
            hooks: IHooks(address(0)),
            poolManager: IBinPoolManager(address(poolManager)),
            fee: uint24(3000), // 3000 = 0.3%
            parameters: poolParam.setBinStep(10) // binStep
        });
        key3 = PoolKey({
            currency0: Currency.wrap(address(address(0))),
            currency1: Currency.wrap(address(token0)),
            hooks: IHooks(address(0)),
            poolManager: IBinPoolManager(address(poolManager)),
            fee: uint24(3000), // 3000 = 0.3%
            parameters: poolParam.setBinStep(10) // binStep
        });

        poolManager.initialize(key, activeId, ZERO_BYTES);
        poolManager.initialize(key2, activeId, ZERO_BYTES);
        poolManager.initialize(key3, activeId, ZERO_BYTES);

        vm.startPrank(alice);
        token0.approve(address(binFungiblePositionManager), 1000 ether);
        token1.approve(address(binFungiblePositionManager), 1000 ether);
        token2.approve(address(binFungiblePositionManager), 1000 ether);
        token0.approve(address(router), 1000 ether);
        token1.approve(address(router), 1000 ether);
        token2.approve(address(router), 1000 ether);

        // add liquidity, 10 ether across 3 bins for both pool
        token0.mint(alice, 10 ether);
        token1.mint(alice, 20 ether); // 20 as token1 is used in both pool
        token2.mint(alice, 10 ether);
        uint24[] memory binIds = getBinIds(activeId, 3);
        IBinFungiblePositionManager.AddLiquidityParams memory addParams;
        addParams = _getAddParams(key, binIds, 10 ether, 10 ether, activeId, alice);
        binFungiblePositionManager.addLiquidity(addParams);
        addParams = _getAddParams(key2, binIds, 10 ether, 10 ether, activeId, alice);
        binFungiblePositionManager.addLiquidity(addParams);

        // add liquidity for ETH-token0 native pool (10 eth each)
        token0.mint(alice, 10 ether);
        vm.deal(alice, 10 ether);
        addParams = _getAddParams(key3, binIds, 10 ether, 10 ether, activeId, alice);
        binFungiblePositionManager.addLiquidity{value: 10 ether}(addParams);
    }

    function testQuoter_quoteExactInputSingle_zeroForOne() public {
        vm.startPrank(alice);

        vm.deal(alice, 1 ether);
        assertEq(alice.balance, 1 ether);
        assertEq(token0.balanceOf(alice), 0 ether);

        snapStart("BinQuoterTest#testQuoter_quoteExactInputSingle");
        (int128[] memory deltaAmounts, uint24 activeIdAfter) = quoter.quoteExactInputSingle(
            IBinQuoter.QuoteExactSingleParams({
                poolKey: key3,
                zeroForOne: true,
                exactAmount: 1 ether,
                hookData: new bytes(0)
            })
        );
        snapEnd();

        vm.expectEmit(true, true, true, true);
        emit IBinPoolManager.Swap(key3.toId(), address(router), -1 ether, deltaAmounts[1], activeIdAfter, key3.fee, 0);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(vault), address(alice), uint256(uint128(deltaAmounts[1])));

        uint256 amountOut = router.exactInputSingle{value: 1 ether}(
            IBinSwapRouterBase.V4BinExactInputSingleParams({
                poolKey: key3,
                swapForY: true, // swap ETH for token0
                recipient: alice,
                amountIn: 1 ether,
                amountOutMinimum: 0,
                hookData: new bytes(0)
            }),
            block.timestamp + 60
        );

        (uint24 currentActiveId,,) = poolManager.getSlot0(key.toId());

        assertEq(activeIdAfter, currentActiveId);
        assertEq(uint128(-deltaAmounts[0]), 1 ether);
        assertEq(uint128(deltaAmounts[1]), amountOut);
        assertEq(amountOut, 997000000000000000);
        assertEq(alice.balance, 0 ether);
        assertEq(token0.balanceOf(alice), amountOut);
    }

    function testQuoter_quoteExactInputSingle_oneForZero() public {
        vm.startPrank(alice);

        token0.mint(alice, 1 ether);
        assertEq(alice.balance, 0 ether);
        assertEq(token0.balanceOf(alice), 1 ether);

        (int128[] memory deltaAmounts, uint24 activeIdAfter) = quoter.quoteExactInputSingle(
            IBinQuoter.QuoteExactSingleParams({
                poolKey: key3,
                zeroForOne: false,
                exactAmount: 1 ether,
                hookData: new bytes(0)
            })
        );

        vm.expectEmit(true, true, true, true);
        emit IBinPoolManager.Swap(key3.toId(), address(router), deltaAmounts[0], -1 ether, activeIdAfter, key3.fee, 0);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(alice), address(vault), 1 ether);

        uint256 amountOut = router.exactInputSingle(
            IBinSwapRouterBase.V4BinExactInputSingleParams({
                poolKey: key3,
                swapForY: false, // swap token0 for ETH
                recipient: alice,
                amountIn: 1 ether,
                amountOutMinimum: 0,
                hookData: new bytes(0)
            }),
            block.timestamp + 60
        );

        (uint24 currentActiveId,,) = poolManager.getSlot0(key.toId());

        assertEq(activeIdAfter, currentActiveId);
        assertEq(uint128(deltaAmounts[0]), amountOut);
        assertEq(uint128(-deltaAmounts[1]), 1 ether);
        assertEq(amountOut, 997000000000000000);
        assertEq(alice.balance, amountOut);
        assertEq(token0.balanceOf(alice), 0 ether);
    }

    function testQuoter_quoteExactInput_SingleHop() public {
        vm.startPrank(alice);
        token0.mint(alice, 1 ether);

        ISwapRouterBase.PathKey[] memory path = new ISwapRouterBase.PathKey[](1);
        path[0] = ISwapRouterBase.PathKey({
            intermediateCurrency: Currency.wrap(address(token1)),
            fee: key.fee,
            hooks: key.hooks,
            hookData: new bytes(0),
            poolManager: key.poolManager,
            parameters: key.parameters
        });

        PathKey[] memory quoter_path = new PathKey[](1);
        quoter_path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(token1)),
            fee: key.fee,
            hooks: key.hooks,
            hookData: new bytes(0),
            poolManager: key.poolManager,
            parameters: key.parameters
        });
        snapStart("BinQuoterTest#testQuoter_quoteExactInput_SingleHop");
        (int128[] memory deltaAmounts, uint24[] memory activeIdAfterList) = quoter.quoteExactInput(
            IBinQuoter.QuoteExactParams({
                exactCurrency: Currency.wrap(address(token0)),
                path: quoter_path,
                exactAmount: 1 ether
            })
        );
        snapEnd();

        vm.expectEmit(true, true, true, true);
        emit IBinPoolManager.Swap(
            key.toId(), address(router), -1 ether, deltaAmounts[1], activeIdAfterList[0], key.fee, 0
        );
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(alice), address(vault), 1 ether);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(vault), address(alice), uint256(uint128(deltaAmounts[1])));

        uint256 amountOut = router.exactInput(
            IBinSwapRouterBase.V4BinExactInputParams({
                currencyIn: Currency.wrap(address(token0)),
                path: path,
                recipient: alice,
                amountIn: 1 ether,
                amountOutMinimum: 0
            }),
            block.timestamp + 60
        );

        (uint24 currentActiveId,,) = poolManager.getSlot0(key.toId());

        assertEq(activeIdAfterList[0], currentActiveId);
        assertEq(-deltaAmounts[0], 1 ether);
        assertEq(uint128(deltaAmounts[1]), amountOut);
        assertEq(token1.balanceOf(alice), amountOut);
    }

    function testQuoter_quoteExactInput_MultiHop() public {
        vm.startPrank(alice);
        token0.mint(alice, 1 ether);

        ISwapRouterBase.PathKey[] memory path = new ISwapRouterBase.PathKey[](2);
        path[0] = ISwapRouterBase.PathKey({
            intermediateCurrency: Currency.wrap(address(token1)),
            fee: key.fee,
            hooks: key.hooks,
            hookData: new bytes(0),
            poolManager: key.poolManager,
            parameters: key.parameters
        });
        path[1] = ISwapRouterBase.PathKey({
            intermediateCurrency: Currency.wrap(address(token2)),
            fee: key2.fee,
            hooks: key2.hooks,
            hookData: new bytes(0),
            poolManager: key2.poolManager,
            parameters: key2.parameters
        });

        PathKey[] memory quoter_path = new PathKey[](2);
        quoter_path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(token1)),
            fee: key.fee,
            hooks: key.hooks,
            hookData: new bytes(0),
            poolManager: key.poolManager,
            parameters: key.parameters
        });
        quoter_path[1] = PathKey({
            intermediateCurrency: Currency.wrap(address(token2)),
            fee: key2.fee,
            hooks: key2.hooks,
            hookData: new bytes(0),
            poolManager: key2.poolManager,
            parameters: key2.parameters
        });

        snapStart("BinQuoterTest#testQuoter_quoteExactInput_MultiHop");
        (int128[] memory deltaAmounts, uint24[] memory activeIdAfterList) = quoter.quoteExactInput(
            IBinQuoter.QuoteExactParams({
                exactCurrency: Currency.wrap(address(token0)),
                path: quoter_path,
                exactAmount: 1 ether
            })
        );
        snapEnd();

        // first hop
        vm.expectEmit(true, true, true, true);
        emit IBinPoolManager.Swap(
            key.toId(), address(router), -1 ether, 997000000000000000, activeIdAfterList[0], key.fee, 0
        );
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(alice), address(vault), 1 ether);
        // second hop
        vm.expectEmit(true, true, true, true);
        emit IBinPoolManager.Swap(
            key2.toId(), address(router), -997000000000000000, deltaAmounts[2], activeIdAfterList[1], key2.fee, 0
        );
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(vault), address(bob), uint256(uint128(deltaAmounts[2])));

        uint256 amountOut = router.exactInput(
            IBinSwapRouterBase.V4BinExactInputParams({
                currencyIn: Currency.wrap(address(token0)),
                path: path,
                recipient: bob,
                amountIn: 1 ether,
                amountOutMinimum: 0
            }),
            block.timestamp + 60
        );

        (uint24 currentActiveId,,) = poolManager.getSlot0(key.toId());

        assertEq(-deltaAmounts[0], 1 ether);
        assertEq(deltaAmounts[1], 0);
        assertEq(activeIdAfterList[1], currentActiveId);
        assertEq(uint128(deltaAmounts[2]), amountOut);
        // 1 ether * 0.997 * 0.997 (0.3% fee twice)
        assertEq(amountOut, 994009000000000000);
        assertEq(token2.balanceOf(alice), 0);
        assertEq(token2.balanceOf(bob), amountOut);
    }

    function testQuoter_quoteExactOutputSingle_zeroForOne() public {
        vm.startPrank(alice);
        token0.mint(alice, 1 ether);

        snapStart("BinQuoterTest#testQuoter_quoteExactOutputSingle");
        (int128[] memory deltaAmounts, uint24 activeIdAfter) = quoter.quoteExactOutputSingle(
            IBinQuoter.QuoteExactSingleParams({
                poolKey: key,
                zeroForOne: true,
                exactAmount: 0.5 ether,
                hookData: new bytes(0)
            })
        );
        snapEnd();

        vm.expectEmit(true, true, true, true);
        emit IBinPoolManager.Swap(key.toId(), address(router), deltaAmounts[0], 0.5 ether, activeIdAfter, key.fee, 0);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(alice), address(vault), uint256(uint128(-deltaAmounts[0])));
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(vault), address(bob), 0.5 ether);

        uint256 amountIn = router.exactOutputSingle(
            IBinSwapRouterBase.V4BinExactOutputSingleParams({
                poolKey: key,
                swapForY: true,
                recipient: bob,
                amountOut: 0.5 ether,
                amountInMaximum: 1 ether,
                hookData: new bytes(0)
            }),
            block.timestamp + 60
        );

        (uint24 currentActiveId,,) = poolManager.getSlot0(key.toId());

        assertEq(activeIdAfter, currentActiveId);
        assertEq(uint128(-deltaAmounts[0]), amountIn);
        assertEq(uint128(deltaAmounts[1]), 0.5 ether);
        assertEq(token0.balanceOf(alice), 1 ether - amountIn);
        assertEq(token1.balanceOf(alice), 0 ether);
        assertEq(token1.balanceOf(bob), 0.5 ether);
    }

    function testQuoter_quoteExactOutputSingle_oneForZero() public {
        vm.startPrank(alice);
        token1.mint(alice, 1 ether);

        (int128[] memory deltaAmounts, uint24 activeIdAfter) = quoter.quoteExactOutputSingle(
            IBinQuoter.QuoteExactSingleParams({
                poolKey: key,
                zeroForOne: false,
                exactAmount: 0.5 ether,
                hookData: new bytes(0)
            })
        );

        vm.expectEmit(true, true, true, true);
        emit IBinPoolManager.Swap(key.toId(), address(router), 0.5 ether, deltaAmounts[1], activeIdAfter, key.fee, 0);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(alice), address(vault), uint256(uint128(-deltaAmounts[1])));
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(vault), address(bob), 0.5 ether);

        uint256 amountIn = router.exactOutputSingle(
            IBinSwapRouterBase.V4BinExactOutputSingleParams({
                poolKey: key,
                swapForY: false,
                recipient: bob,
                amountOut: 0.5 ether,
                amountInMaximum: 1 ether,
                hookData: new bytes(0)
            }),
            block.timestamp + 60
        );

        (uint24 currentActiveId,,) = poolManager.getSlot0(key.toId());

        assertEq(activeIdAfter, currentActiveId);
        assertEq(uint128(-deltaAmounts[1]), amountIn);
        assertEq(uint128(deltaAmounts[0]), 0.5 ether);
        assertEq(token0.balanceOf(alice), 0 ether);
        assertEq(token1.balanceOf(alice), 1 ether - amountIn);
        assertEq(token0.balanceOf(bob), 0.5 ether);
    }

    function testQuoter_quoteExactOutput_SingleHop() public {
        // swap token0 input -> token1 output
        vm.startPrank(alice);
        token0.mint(alice, 1 ether);

        ISwapRouterBase.PathKey[] memory path = new ISwapRouterBase.PathKey[](1);
        path[0] = ISwapRouterBase.PathKey({
            intermediateCurrency: Currency.wrap(address(token0)),
            fee: key.fee,
            hooks: key.hooks,
            hookData: new bytes(0),
            poolManager: key.poolManager,
            parameters: key.parameters
        });

        // before test validation
        assertEq(token0.balanceOf(alice), 1 ether);
        assertEq(token1.balanceOf(alice), 0);

        PathKey[] memory quoter_path = new PathKey[](1);
        quoter_path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(token0)),
            fee: key.fee,
            hooks: key.hooks,
            hookData: new bytes(0),
            poolManager: key.poolManager,
            parameters: key.parameters
        });

        snapStart("BinQuoterTest#testQuoter_quoteExactOutput_SingleHop");
        (int128[] memory deltaAmounts, uint24[] memory activeIdAfterList) = quoter.quoteExactOutput(
            IBinQuoter.QuoteExactParams({
                exactCurrency: Currency.wrap(address(token1)),
                path: quoter_path,
                exactAmount: 0.5 ether
            })
        );
        snapEnd();

        vm.expectEmit(true, true, true, true);
        emit IBinPoolManager.Swap(
            key.toId(), address(router), deltaAmounts[0], 0.5 ether, activeIdAfterList[0], key.fee, 0
        );
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(alice), address(vault), uint256(uint128(-deltaAmounts[0])));
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(vault), address(alice), 0.5 ether);

        uint256 amountIn = router.exactOutput(
            IBinSwapRouterBase.V4BinExactOutputParams({
                currencyOut: Currency.wrap(address(token1)),
                path: path,
                recipient: alice,
                amountOut: 0.5 ether,
                amountInMaximum: 1 ether
            }),
            block.timestamp + 60
        );

        (uint24 currentActiveId,,) = poolManager.getSlot0(key.toId());

        // after test validation
        assertEq(activeIdAfterList[0], currentActiveId);
        assertEq(uint128(-deltaAmounts[0]), amountIn);
        assertEq(uint128(deltaAmounts[1]), 0.5 ether);
        assertEq(amountIn, 501504513540621866); // amt in should be greater than 0.5 eth
        assertEq(token0.balanceOf(alice), 1 ether - amountIn);
        assertEq(token1.balanceOf(alice), 0.5 ether);
    }

    function testQuoter_quoteExactOutput_MultiHop() public {
        // swap token0 input -> token1 -> token2 output
        vm.startPrank(alice);
        token0.mint(alice, 1 ether);

        ISwapRouterBase.PathKey[] memory path = new ISwapRouterBase.PathKey[](2);
        path[0] = ISwapRouterBase.PathKey({
            intermediateCurrency: Currency.wrap(address(token0)),
            fee: key.fee,
            hooks: key.hooks,
            hookData: new bytes(0),
            poolManager: key.poolManager,
            parameters: key.parameters
        });
        path[1] = ISwapRouterBase.PathKey({
            intermediateCurrency: Currency.wrap(address(token1)),
            fee: key2.fee,
            hooks: key2.hooks,
            hookData: new bytes(0),
            poolManager: key2.poolManager,
            parameters: key2.parameters
        });

        PathKey[] memory quoter_path = new PathKey[](2);
        quoter_path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(token0)),
            fee: key.fee,
            hooks: key.hooks,
            hookData: new bytes(0),
            poolManager: key.poolManager,
            parameters: key.parameters
        });
        quoter_path[1] = PathKey({
            intermediateCurrency: Currency.wrap(address(token1)),
            fee: key2.fee,
            hooks: key2.hooks,
            hookData: new bytes(0),
            poolManager: key2.poolManager,
            parameters: key2.parameters
        });

        snapStart("BinQuoterTest#testQuoter_quoteExactOutput_MultiHop");
        (int128[] memory deltaAmounts, uint24[] memory activeIdAfterList) = quoter.quoteExactOutput(
            IBinQuoter.QuoteExactParams({
                exactCurrency: Currency.wrap(address(token2)),
                path: quoter_path,
                exactAmount: 0.5 ether
            })
        );
        snapEnd();

        // before test validation
        assertEq(token0.balanceOf(alice), 1 ether);
        assertEq(token1.balanceOf(alice), 0);
        assertEq(token2.balanceOf(alice), 0);
        assertEq(token2.balanceOf(bob), 0 ether);

        // first hop
        vm.expectEmit(true, true, true, true);
        emit IBinPoolManager.Swap(
            key2.toId(), address(router), -501504513540621866, 0.5 ether, activeIdAfterList[1], key2.fee, 0
        );
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(vault), address(bob), 0.5 ether);
        // second hop
        vm.expectEmit(true, true, true, true);
        emit IBinPoolManager.Swap(
            key.toId(), address(router), deltaAmounts[0], 501504513540621866, activeIdAfterList[0], key.fee, 0
        );
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(alice), address(vault), uint256(uint128(-deltaAmounts[0])));

        uint256 amountIn = router.exactOutput(
            IBinSwapRouterBase.V4BinExactOutputParams({
                currencyOut: Currency.wrap(address(token2)),
                path: path,
                recipient: bob,
                amountOut: 0.5 ether,
                amountInMaximum: 1 ether
            }),
            block.timestamp + 60
        );

        (uint24 currentActiveId,,) = poolManager.getSlot0(key.toId());

        // after test validation
        // amt in should be greater than 0.5 eth + 0.3% fee twice (2 pool)
        assertEq(activeIdAfterList[1], currentActiveId);
        assertEq(uint128(-deltaAmounts[0]), amountIn);
        assertEq(uint128(deltaAmounts[1]), 0);
        assertEq(uint128(deltaAmounts[2]), 0.5 ether);
        assertEq(amountIn, 503013554203231561);
        assertEq(token0.balanceOf(alice), 1 ether - amountIn);
        assertEq(token2.balanceOf(bob), 0.5 ether);
    }

    function testQuoter_lockAcquired_revert_InvalidLockAcquiredSender() public {
        vm.startPrank(alice);
        vm.expectRevert(IBinQuoter.InvalidLockAcquiredSender.selector);
        quoter.lockAcquired(abi.encodeWithSelector(quoter.lockAcquired.selector, "0x"));
    }

    function testQuoter_lockAcquired_revert_LockFailure() public {
        vm.startPrank(address(vault));
        vm.expectRevert(IBinQuoter.LockFailure.selector);
        quoter.lockAcquired(abi.encodeWithSelector(quoter.lockAcquired.selector, address(this), "0x"));
    }

    function testQuoter_lockAcquired_revert_NotSelf() public {
        vm.startPrank(address(alice));
        vm.expectRevert(IBinQuoter.NotSelf.selector);

        quoter._quoteExactInputSingle(
            IBinQuoter.QuoteExactSingleParams({
                poolKey: key3,
                zeroForOne: true,
                exactAmount: 1 ether,
                hookData: new bytes(0)
            })
        );
    }

    function testQuoter_lockAcquired_revert_UnexpectedRevertBytes() public {
        vm.startPrank(address(alice));

        vm.expectRevert(
            abi.encodeWithSelector(
                IBinQuoter.UnexpectedRevertBytes.selector,
                abi.encodeWithSelector(BinPool.BinPool__OutOfLiquidity.selector)
            )
        );
        quoter.quoteExactOutputSingle(
            IBinQuoter.QuoteExactSingleParams({
                poolKey: key,
                zeroForOne: true,
                exactAmount: 20 ether,
                hookData: new bytes(0)
            })
        );
    }
}
