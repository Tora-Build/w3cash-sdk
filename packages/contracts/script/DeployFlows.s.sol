// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "../src/flows/x402Flow.sol";
import "../src/flows/YieldFlow.sol";

contract DeployFlows is Script {
    // Aave V3 Pool on Base Sepolia
    address constant AAVE_POOL_BASE_SEPOLIA = 0x07eA79F68B2B3df564D0A34F8e19D9B1e339814b;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy x402Flow
        x402Flow x402 = new x402Flow();
        console.log("x402Flow deployed at:", address(x402));
        
        // Deploy YieldFlow
        YieldFlow yield = new YieldFlow(AAVE_POOL_BASE_SEPOLIA);
        console.log("YieldFlow deployed at:", address(yield));
        
        vm.stopBroadcast();
    }
}
