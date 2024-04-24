// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {SafeCast} from "pancake-v4-core/src/libraries/SafeCast.sol";
import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
import {PeripheryPayments} from "./PeripheryPayments.sol";
import {IAllowanceTransfer} from "../interfaces/IAllowanceTransfer.sol";

/// @title Payments through Permit2
/// @notice Performs interactions with Permit2 to transfer tokens
abstract contract Permit2Payments is PeripheryPayments {
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;

    /// @notice Performs a transferFrom on Permit2
    /// @param token The token to transfer
    /// @param from The address to transfer from
    /// @param to The recipient of the transfer
    /// @param amount The amount to transfer
    function permit2TransferFrom(address token, address from, address to, uint160 amount) internal {
        PERMIT2.transferFrom(from, to, amount, token);
    }

    function permit(address owner, IAllowanceTransfer.PermitSingle memory permitSingle, bytes calldata signature)
        external
    {
        PERMIT2.permit(owner, permitSingle, signature);
    }

    /// @notice Either performs a regular payment or transferFrom on Permit2, depending on the payer address
    /// @param currency The currency to transfer
    /// @param payer The address to pay for the transfer
    /// @param recipient The recipient of the transfer
    /// @param amount The amount to transfer
    function payOrPermit2Transfer(Currency currency, address payer, address recipient, uint256 amount) internal {
        if (payer == address(this)) currency.transfer(recipient, amount);
        else permit2TransferFrom(Currency.unwrap(currency), payer, recipient, amount.toUint160());
    }
}

// function testMulticall_ExactInputRefundEth() public {
//     // swap ETH to token0 and refund left over ETH
//     vm.startPrank(alice);

//     vm.deal(alice, 2 ether);
//     assertEq(alice.balance, 2 ether);
//     assertEq(token0.balanceOf(alice), 0 ether);

//     // swap 1 ETH for token0 and call refundEth
//     bytes[] memory data = new bytes[](2);
//     data[0] = abi.encodeWithSelector(
//         router.exactInputSingle.selector,
//         IBinSwapRouterBase.V4BinExactInputSingleParams({
//             poolKey: key3,
//             swapForY: true, // swap ETH for token0
//             recipient: alice,
//             amountIn: 1 ether,
//             amountOutMinimum: 0,
//             hookData: new bytes(0)
//         }),
//         block.timestamp + 60
//     );
//     data[1] = abi.encodeWithSelector(router.refundETH.selector);

//     bytes[] memory result = new bytes[](2);
//     result = router.multicall{value: 2 ether}(data);

//     assertEq(alice.balance, 1 ether);
//     assertEq(address(router).balance, 0 ether);
//     assertEq(token0.balanceOf(alice), abi.decode(result[0], (uint256)));
// }
