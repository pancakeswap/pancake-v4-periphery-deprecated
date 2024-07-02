// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {BinQuoter} from "../src/pool-bin/lens/BinQuoter.sol";

/**
 * forge script script/07_DeployBinQuoter.s.sol:DeployBinQuoterScript -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow \
 *     --verify
 */
contract DeployBinQuoterScript is BaseScript {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address vault = getAddressFromConfig("vault");
        emit log_named_address("Vault", vault);

        address binPoolManager = getAddressFromConfig("binPoolManager");
        emit log_named_address("BinPoolManager", binPoolManager);

        BinQuoter binQuoter = new BinQuoter(IVault(vault), binPoolManager);
        emit log_named_address("BinQuoter", address(binQuoter));

        vm.stopBroadcast();
    }
}
