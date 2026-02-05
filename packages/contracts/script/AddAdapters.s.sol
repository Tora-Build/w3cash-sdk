// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { AdapterRegistry } from "../src/w3cash/AdapterRegistry.sol";
import { TransferAdapter } from "../src/w3cash/adapters/TransferAdapter.sol";
import { ApproveAdapter } from "../src/w3cash/adapters/ApproveAdapter.sol";
import { SwapAdapter } from "../src/w3cash/adapters/SwapAdapter.sol";
import { WrapAdapter } from "../src/w3cash/adapters/WrapAdapter.sol";

/**
 * @title AddAdapters
 * @notice Deploy and register new action adapters to existing W3Cash deployment
 */
contract AddAdapters is Script {
    // Deployed W3Cash v4 addresses (Base Sepolia)
    address constant PROCESSOR = 0x0fdFB12E72b08289F1374E69aCa39D69A279fdcE;
    address constant REGISTRY = 0x2E9e3AC48af39Fe96EbB5b71075FA847795B7A82;
    
    // Base Sepolia externals
    address constant UNISWAP_ROUTER = 0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4; // Universal Router
    address constant WETH = 0x4200000000000000000000000000000000000006;

    // New adapter IDs (continuing from existing: 0=Wait, 1=Query, 2=Aave)
    uint8 constant TRANSFER_ADAPTER_ID = 3;
    uint8 constant APPROVE_ADAPTER_ID = 4;
    uint8 constant SWAP_ADAPTER_ID = 5;
    uint8 constant WRAP_ADAPTER_ID = 6;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Adding new adapters to W3Cash...");
        console.log("Deployer:", deployer);
        console.log("Processor:", PROCESSOR);
        console.log("Registry:", REGISTRY);

        AdapterRegistry registry = AdapterRegistry(REGISTRY);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy adapters
        TransferAdapter transferAdapter = new TransferAdapter(PROCESSOR);
        console.log("TransferAdapter deployed at:", address(transferAdapter));

        ApproveAdapter approveAdapter = new ApproveAdapter(PROCESSOR);
        console.log("ApproveAdapter deployed at:", address(approveAdapter));

        SwapAdapter swapAdapter = new SwapAdapter(UNISWAP_ROUTER, PROCESSOR);
        console.log("SwapAdapter deployed at:", address(swapAdapter));

        WrapAdapter wrapAdapter = new WrapAdapter(WETH, PROCESSOR);
        console.log("WrapAdapter deployed at:", address(wrapAdapter));

        // Register in registry
        registry.setAdapter(TRANSFER_ADAPTER_ID, address(transferAdapter));
        registry.setAdapter(APPROVE_ADAPTER_ID, address(approveAdapter));
        registry.setAdapter(SWAP_ADAPTER_ID, address(swapAdapter));
        registry.setAdapter(WRAP_ADAPTER_ID, address(wrapAdapter));
        console.log("All adapters registered");

        vm.stopBroadcast();

        // Summary
        console.log("");
        console.log("=== NEW ADAPTERS DEPLOYED ===");
        console.log("TransferAdapter (ID 3):", address(transferAdapter));
        console.log("ApproveAdapter (ID 4):", address(approveAdapter));
        console.log("SwapAdapter (ID 5):", address(swapAdapter));
        console.log("WrapAdapter (ID 6):", address(wrapAdapter));
    }
}
