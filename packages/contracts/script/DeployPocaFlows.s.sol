// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "../src/flows/ScheduledFlow.sol";
import "../src/flows/DCAFlow.sol";

contract DeployPocaFlows is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy ScheduledFlow
        ScheduledFlow scheduled = new ScheduledFlow();
        console.log("ScheduledFlow deployed at:", address(scheduled));
        
        // Deploy DCAFlow
        DCAFlow dca = new DCAFlow();
        console.log("DCAFlow deployed at:", address(dca));
        
        vm.stopBroadcast();
    }
}
