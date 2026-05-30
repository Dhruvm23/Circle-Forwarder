// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/ArbExecutor.sol";

/// @title DeployArbExecutor — Deploys ArbExecutor to Arbitrum (or local fork)
contract DeployArbExecutor is Script {
    function run() external {
        // The solver address authorized to call fulfillIntent
        address solver = vm.envAddress("SOLVER_ADDRESS");

        vm.startBroadcast();
        ArbExecutor executor = new ArbExecutor(solver);
        vm.stopBroadcast();

        console.log("=== ArbExecutor Deployment ===");
        console.log("Deployed at :", address(executor));
        console.log("Solver      :", solver);
    }
}
