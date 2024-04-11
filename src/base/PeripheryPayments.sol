// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.19;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
import {IPeripheryPayments} from "../interfaces/IPeripheryPayments.sol";
import {IWETH9} from "../interfaces/external/IWETH9.sol";
import {PeripheryImmutableState} from "./PeripheryImmutableState.sol";

abstract contract PeripheryPayments is IPeripheryPayments, PeripheryImmutableState {
    using CurrencyLibrary for Currency;

    error InsufficientToken();
    error ERC20TransferFromFailed();

    // todo: double check
    // in v3, There is a check on "require(msg.sender == WETH9, 'Not WETH9');"
    //  - make sense in v3 as only WETH will send ETH during unwrapETH and there's no native ETH pair in v3
    // in v4, due to native ETH pair, theres a chance ETH is sent from vault or binfungibleposition etc..
    receive() external payable {}

    /// @inheritdoc IPeripheryPayments
    function unwrapWETH9(uint256 amountMinimum, address recipient) public payable override {
        uint256 balanceWETH9 = IWETH9(WETH9).balanceOf(address(this));
        if (balanceWETH9 < amountMinimum) revert InsufficientToken();

        if (balanceWETH9 > 0) {
            IWETH9(WETH9).withdraw(balanceWETH9);
            CurrencyLibrary.NATIVE.transfer(recipient, balanceWETH9);
        }
    }

    /// @inheritdoc IPeripheryPayments
    function refundETH() external payable override {
        if (address(this).balance > 0) CurrencyLibrary.NATIVE.transfer(msg.sender, address(this).balance);
    }

    /// @inheritdoc IPeripheryPayments
    function sweepToken(Currency currency, uint256 amountMinimum, address recipient) public payable override {
        uint256 balanceCurrency = currency.balanceOfSelf();
        if (balanceCurrency < amountMinimum) revert InsufficientToken();

        if (balanceCurrency > 0) {
            currency.transfer(recipient, balanceCurrency);
        }
    }

    /// @dev If currency is native, assumed contract contains the ETH balance
    /// @param currency The currency to pay
    /// @param payer The entity that must pay
    /// @param recipient The entity that will receive payment
    /// @param value The amount to pay
    function pay(Currency currency, address payer, address recipient, uint256 value) internal {
        if (payer == address(this) || currency.isNative()) {
            // currency is native, assume contract owns the ETH currently
            currency.transfer(recipient, value);
        } else {
            // pull payment
            _safeTransferFrom(IERC20(Currency.unwrap(currency)), payer, recipient, value);
        }
    }

    /// @dev Safely transfers tokens from the payer to the recipient
    /// borrowed from solmate/utils/SafeTransferLib.sol
    function _safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        bool success;

        /// @solidity memory-safe-assembly
        assembly {
            // Get a pointer to some free memory.
            let freeMemoryPointer := mload(0x40)

            // Write the abi-encoded calldata into memory, beginning with the function selector.
            mstore(freeMemoryPointer, 0x23b872dd00000000000000000000000000000000000000000000000000000000)
            mstore(add(freeMemoryPointer, 4), and(from, 0xffffffffffffffffffffffffffffffffffffffff)) // Append and mask the "from" argument.
            mstore(add(freeMemoryPointer, 36), and(to, 0xffffffffffffffffffffffffffffffffffffffff)) // Append and mask the "to" argument.
            mstore(add(freeMemoryPointer, 68), amount) // Append the "amount" argument. Masking not required as it's a full 32 byte type.

            success :=
                and(
                    // Set success to whether the call reverted, if not we check it either
                    // returned exactly 1 (can't just be non-zero data), or had no return data.
                    or(and(eq(mload(0), 1), gt(returndatasize(), 31)), iszero(returndatasize())),
                    // We use 100 because the length of our calldata totals up like so: 4 + 32 * 3.
                    // We use 0 and 32 to copy up to 32 bytes of return data into the scratch space.
                    // Counterintuitively, this call must be positioned second to the or() call in the
                    // surrounding and() call or else returndatasize() will be zero during the computation.
                    call(gas(), token, 0, freeMemoryPointer, 100, 0, 32)
                )
        }

        if (!success) {
            revert ERC20TransferFromFailed();
        }
    }
}
