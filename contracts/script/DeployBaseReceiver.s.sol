// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/BaseReceiver.sol";

/// @title DeployBaseReceiver — Deploys BaseReceiver to Base (or local fork)
contract DeployBaseReceiver is Script {
    function run() external {
        // The mint recipient is the solver or ArbExecutor on the destination chain
        address mintRecipient = vm.envAddress("MINT_RECIPIENT");

        vm.startBroadcast();
        BaseReceiver receiver = new BaseReceiver(mintRecipient);
        vm.stopBroadcast();

        console.log("=== BaseReceiver Deployment ===");
        console.log("Deployed at     :", address(receiver));
        console.log("Mint Recipient  :", mintRecipient);
        console.log("Domain Separator:", vm.toString(receiver.getDomainSeparator()));
    }
}
