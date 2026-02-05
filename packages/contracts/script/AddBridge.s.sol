// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { AdapterRegistry } from "../src/w3cash/AdapterRegistry.sol";
import { BridgeAdapter } from "../src/w3cash/adapters/BridgeAdapter.sol";

/**
 * @title AddBridge
 * @notice Deploy and register BridgeAdapter (Across)
 */
contract AddBridge is Script {
    // Deployed W3Cash v4 addresses (Base Sepolia)
    address constant PROCESSOR = 0x0fdFB12E72b08289F1374E69aCa39D69A279fdcE;
    address constant REGISTRY = 0x2E9e3AC48af39Fe96EbB5b71075FA847795B7A82;
    
    // Across SpokePool on Base Sepolia
    address constant ACROSS_SPOKE_POOL = 0x82B564983aE7274c86695917BBf8C99ECb6F0F8F;

    // Adapter ID (continuing from existing)
    uint8 constant BRIDGE_ADAPTER_ID = 7;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Adding BridgeAdapter to W3Cash...");
        console.log("Deployer:", deployer);

        AdapterRegistry registry = AdapterRegistry(REGISTRY);

        vm.startBroadcast(deployerPrivateKey);

        BridgeAdapter bridgeAdapter = new BridgeAdapter(ACROSS_SPOKE_POOL, PROCESSOR);
        console.log("BridgeAdapter deployed at:", address(bridgeAdapter));

        registry.setAdapter(BRIDGE_ADAPTER_ID, address(bridgeAdapter));
        console.log("BridgeAdapter registered with ID:", BRIDGE_ADAPTER_ID);

        vm.stopBroadcast();

        console.log("");
        console.log("=== BRIDGE ADAPTER DEPLOYED ===");
        console.log("BridgeAdapter (ID 7):", address(bridgeAdapter));
    }
}
