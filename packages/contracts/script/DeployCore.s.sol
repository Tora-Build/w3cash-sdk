// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "../src/core/W3CashCore.sol";

contract DeployCore is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);
        
        W3CashCore core = new W3CashCore();
        
        vm.stopBroadcast();
        
        console.log("W3CashCore deployed at:", address(core));
    }
}
