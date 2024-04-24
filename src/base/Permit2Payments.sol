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
