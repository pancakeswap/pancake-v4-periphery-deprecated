// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {BinMigratorFromV2} from "./BinMigratorFromV2.sol";

contract BinMigratorFromUniswapV2Test is BinMigratorFromV2 {
    function _getBytecodePath() internal pure override returns (string memory) {
        // Create a Uniswap V2 pair
        // relative to the root of the project
        // https://etherscan.io/address/0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f#code
        return "./test/bin/uniV2Factory.bytecode";
    }

    function _getContractName() internal pure override returns (string memory) {
        return "BinMigratorFromUniswapV2Test";
    }
}
