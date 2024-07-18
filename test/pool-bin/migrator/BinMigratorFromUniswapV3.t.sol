// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import {BinMigratorFromV3} from "./BinMigratorFromV3.sol";

contract BinMigratorFromUniswapV3Test is BinMigratorFromV3 {
    function _getDeployerBytecodePath() internal pure override returns (string memory) {
        return "";
    }

    function _getFactoryBytecodePath() internal pure override returns (string memory) {
        // https://etherscan.io/address/0x1F98431c8aD98523631AE4a59f267346ea31F984#code
        return "./test/bin/uniV3Factory.bytecode";
    }

    function _getNfpmBytecodePath() internal pure override returns (string memory) {
        // https://etherscan.io/address/0xC36442b4a4522E871399CD717aBDD847Ab11FE88#code
        return "./test/bin/uniV3Nfpm.bytecode";
    }

    function _getContractName() internal pure override returns (string memory) {
        return "BinMigratorFromUniswapV3Test";
    }
}
