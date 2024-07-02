// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {BaseScript} from "./BaseScript.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {CLQuoter} from "../src/pool-cl/lens/CLQuoter.sol";

/**
 * forge script script/06_DeployCLQuoter.s.sol:DeployCLQuoterScript -vvv \
 *     --rpc-url $RPC_URL \
 *     --broadcast \
 *     --slow \
 *     --verify
 */
contract DeployCLQuoterScript is BaseScript {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address vault = getAddressFromConfig("vault");
        emit log_named_address("Vault", vault);

        address clPoolManager = getAddressFromConfig("clPoolManager");
        emit log_named_address("CLPoolManager", clPoolManager);

        CLQuoter clQuoter = new CLQuoter(IVault(vault), clPoolManager);
        emit log_named_address("CLQuoter", address(clQuoter));

        vm.stopBroadcast();
    }
}
