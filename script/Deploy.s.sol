// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {DealGuardCore} from "../src/DealGuardCore.sol";

/// Usage:
///   OWNER=0x... EVIDENCE_HASH=0x... forge script script/Deploy.s.sol \
///     --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
contract Deploy is Script {
    function run() external returns (DealGuardCore core) {
        address owner = vm.envAddress("OWNER");
        bytes32 evidenceHash = vm.envBytes32("EVIDENCE_HASH");
        vm.startBroadcast();
        core = new DealGuardCore(owner, evidenceHash);
        vm.stopBroadcast();
        console2.log("DealGuardCore", address(core));
    }
}
