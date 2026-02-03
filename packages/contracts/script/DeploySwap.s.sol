// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import "../src/flows/SwapFlow.sol";

contract DeploySwap is Script {
    // Uniswap V3 SwapRouter02 on Base Sepolia
    // Note: Using official Uniswap deployment
    address constant SWAP_ROUTER_BASE_SEPOLIA = 0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);
        
        SwapFlow swap = new SwapFlow(SWAP_ROUTER_BASE_SEPOLIA);
        console.log("SwapFlow deployed at:", address(swap));
        
        vm.stopBroadcast();
    }
}
