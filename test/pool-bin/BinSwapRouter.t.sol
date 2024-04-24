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

import {Permit2Payments} from "../../src/base/Permit2Payments.sol";
import {Permit2} from "../helpers/permit2/Permit2.sol";
import {IAllowanceTransfer} from "../helpers/permit2/interfaces/IAllowanceTransfer.sol";

contract BinSwapRouterTest is Test, GasSnapshot, LiquidityParamsHelper {
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
    Permit2 permit2;

    // address alice = makeAddr("alice");
    address alice;
    uint256 aliceKey;
    address bob = makeAddr("bob");
    uint24 activeId = 2 ** 23; // where token0 and token1 price is the same

    function setUp() public {
        (alice, aliceKey) = makeAddrAndKey("alice");

        weth = new WETH();
        permit2 = new Permit2();
        vault = new Vault();
        poolManager = new BinPoolManager(IVault(address(vault)), 500000);
        vault.registerPoolManager(address(poolManager));
        router = new BinSwapRouter(vault, poolManager, address(weth), address(permit2));

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
        token0.approve(address(permit2), 1000 ether);
        token1.approve(address(permit2), 1000 ether);
        token2.approve(address(permit2), 1000 ether);

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

    function defaultERC20PermitAllowance(address token0, uint160 amount, uint48 expiration, uint48 nonce)
        internal
        view
        returns (IAllowanceTransfer.PermitSingle memory)
    {
        IAllowanceTransfer.PermitDetails memory details =
            IAllowanceTransfer.PermitDetails({token: token0, amount: amount, expiration: expiration, nonce: nonce});
        return IAllowanceTransfer.PermitSingle({
            details: details,
            spender: address(router),
            sigDeadline: block.timestamp + 100
        });
    }

    function getPermitSignature(
        IAllowanceTransfer.PermitSingle memory permit,
        uint256 privateKey,
        bytes32 domainSeparator
    ) internal pure returns (bytes memory sig) {
        (uint8 v, bytes32 r, bytes32 s) = getPermitSignatureRaw(permit, privateKey, domainSeparator);
        return bytes.concat(r, s, bytes1(v));
    }

    function getPermitSignatureRaw(
        IAllowanceTransfer.PermitSingle memory permit,
        uint256 privateKey,
        bytes32 domainSeparator
    ) internal pure returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 _PERMIT_SINGLE_TYPEHASH = keccak256(
            "PermitSingle(PermitDetails details,address spender,uint256 sigDeadline)PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"
        );
        bytes32 _PERMIT_DETAILS_TYPEHASH =
            keccak256("PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)");

        bytes32 permitHash = keccak256(abi.encode(_PERMIT_DETAILS_TYPEHASH, permit.details));

        bytes32 msgHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                keccak256(abi.encode(_PERMIT_SINGLE_TYPEHASH, permitHash, permit.spender, permit.sigDeadline))
            )
        );

        (v, r, s) = vm.sign(privateKey, msgHash);
    }

    /// option 1: For end user. Assume user approve token to permit2 before hand
    /// Flow: user sign a permit2 message and use multicall to swap in 1 txn
    function testSwap_PermitOption1() public {
        // code to generate the permit signature. done in metamask
        bytes32 DOMAIN_SEPARATOR = permit2.DOMAIN_SEPARATOR();
        uint160 defaultAmount = 1 ether;
        uint48 defaultNonce = 0;
        uint48 defaultExpiration = uint48(block.timestamp + 5);
        IAllowanceTransfer.PermitSingle memory permit =
            defaultERC20PermitAllowance(address(token0), defaultAmount, defaultExpiration, defaultNonce);
        bytes memory sig = getPermitSignature(permit, aliceKey, DOMAIN_SEPARATOR);

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

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSelector(router.permit.selector, alice, permit, sig);
        data[1] = abi.encodeWithSelector(
            router.exactInput.selector,
            IBinSwapRouterBase.V4BinExactInputParams({
                currencyIn: Currency.wrap(address(token0)),
                path: path,
                recipient: alice,
                amountIn: 1 ether,
                amountOutMinimum: 0
            }),
            block.timestamp + 60
        );

        bytes[] memory result = new bytes[](2);
        result = router.multicall(data);

        assertEq(token1.balanceOf(alice), abi.decode(result[1], (uint256)));
    }

    // option 2: for bot potentially
    // -> pre-req: txn 1: call token.approve(permit2, type(uint256).max)

    // -> in bot arb flow: 
    // 1. call permit2.approve(token, router, amount, expiration)
    // 2. call router.exactInput 
    function testSwap_PermitOption2() public {
        vm.startPrank(alice);
        token0.mint(alice, 1 ether);

        permit2.approve(address(token0), address(router), 1 ether, uint48(block.timestamp + 5));

        ISwapRouterBase.PathKey[] memory path = new ISwapRouterBase.PathKey[](1);
        path[0] = ISwapRouterBase.PathKey({
            intermediateCurrency: Currency.wrap(address(token1)),
            fee: key.fee,
            hooks: key.hooks,
            hookData: new bytes(0),
            poolManager: key.poolManager,
            parameters: key.parameters
        });

        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeWithSelector(
            router.exactInput.selector,
            IBinSwapRouterBase.V4BinExactInputParams({
                currencyIn: Currency.wrap(address(token0)),
                path: path,
                recipient: alice,
                amountIn: 1 ether,
                amountOutMinimum: 0
            }),
            block.timestamp + 60
        );

        bytes[] memory result = new bytes[](2);
        result = router.multicall(data);

        assertEq(token1.balanceOf(alice), abi.decode(result[0], (uint256)));
    }
}
