// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { AdapterRegistry } from "../src/w3cash/AdapterRegistry.sol";
import { W3CashProcessor } from "../src/w3cash/W3CashProcessor.sol";
import { WaitAdapter } from "../src/w3cash/adapters/WaitAdapter.sol";
import { QueryAdapter } from "../src/w3cash/adapters/QueryAdapter.sol";
import { AaveAdapter } from "../src/w3cash/adapters/AaveAdapter.sol";

/**
 * @title DeployW3Cash
 * @notice Deployment script for W3Cash v4 (Immutable Processor + Upgradeable Registry)
 *
 * Deployment Order:
 * 1. Deploy AdapterRegistry (upgradeable, owned)
 * 2. Deploy W3CashProcessor with registry reference (immutable)
 * 3. Deploy adapters with processor reference (onlyProcessor guard)
 * 4. Register adapters in registry
 * 5. Set chain mappings
 * 6. (Optional) Freeze production adapters
 *
 * Trust Model:
 * - W3CashProcessor: TRUSTLESS (immutable, no admin)
 * - AdapterRegistry: Admin-controlled until adapters are frozen
 * - Adapters: Locked to processor via onlyProcessor guard
 */
contract DeployW3Cash is Script {
    // Base Sepolia addresses
    address constant AAVE_POOL = 0x07eA79F68B2B3df564D0A34F8e19D9B1e339814b;
    uint256 constant BASE_SEPOLIA_CHAIN_ID = 84532;

    // Adapter IDs (using uint8 indices)
    uint8 constant WAIT_ADAPTER_ID = 0;
    uint8 constant QUERY_ADAPTER_ID = 1;
    uint8 constant AAVE_ADAPTER_ID = 2;

    // Chain indices
    uint8 constant BASE_SEPOLIA_CHAIN_INDEX = 0;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying POCA contracts...");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy AdapterRegistry
        AdapterRegistry registry = new AdapterRegistry(deployer);
        console.log("AdapterRegistry deployed at:", address(registry));

        // 2. Deploy W3CashProcessor (immutable, references registry)
        W3CashProcessor processor = new W3CashProcessor(address(registry));
        console.log("W3CashProcessor deployed at:", address(processor));

        // 3. Deploy adapters (with processor address for onlyProcessor guard)
        WaitAdapter waitAdapter = new WaitAdapter(address(processor));
        console.log("WaitAdapter deployed at:", address(waitAdapter));

        QueryAdapter queryAdapter = new QueryAdapter(address(processor));
        console.log("QueryAdapter deployed at:", address(queryAdapter));

        AaveAdapter aaveAdapter = new AaveAdapter(AAVE_POOL, address(processor));
        console.log("AaveAdapter deployed at:", address(aaveAdapter));

        // 4. Register adapters in registry
        registry.setAdapter(WAIT_ADAPTER_ID, address(waitAdapter));
        registry.setAdapter(QUERY_ADAPTER_ID, address(queryAdapter));
        registry.setAdapter(AAVE_ADAPTER_ID, address(aaveAdapter));
        console.log("Adapters registered in registry");

        // 5. Set chain mapping
        registry.setChain(BASE_SEPOLIA_CHAIN_INDEX, BASE_SEPOLIA_CHAIN_ID);
        console.log("Chain mapping set: index", BASE_SEPOLIA_CHAIN_INDEX, "-> chainId", BASE_SEPOLIA_CHAIN_ID);

        vm.stopBroadcast();

        // Output deployment summary
        console.log("");
        console.log("=== DEPLOYMENT SUMMARY ===");
        console.log("AdapterRegistry:", address(registry));
        console.log("WaitAdapter:", address(waitAdapter));
        console.log("QueryAdapter:", address(queryAdapter));
        console.log("AaveAdapter:", address(aaveAdapter));
        console.log("W3CashProcessor:", address(processor));
        console.log("");
        console.log("Next steps:");
        console.log("1. Test the deployment on testnet");
        console.log("2. Freeze adapters once verified: registry.freezeAdapter(id)");
        console.log("3. (Optional) Transfer registry ownership to multisig");
    }
}

/**
 * @title FreezeAdapters
 * @notice Freeze production adapters for immutability
 */
contract FreezeAdapters is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address registryAddress = vm.envAddress("ADAPTER_REGISTRY");

        AdapterRegistry registry = AdapterRegistry(registryAddress);

        console.log("Freezing adapters in registry:", registryAddress);

        vm.startBroadcast(deployerPrivateKey);

        // Freeze all registered adapters
        uint8[] memory adapterIds = new uint8[](2);
        adapterIds[0] = 0; // WaitAdapter
        adapterIds[1] = 1; // AaveAdapter

        registry.freezeAdapters(adapterIds);

        // Freeze chain mapping
        registry.freezeChain(0); // Base Sepolia

        vm.stopBroadcast();

        console.log("Adapters frozen successfully");
        console.log("These adapters can no longer be modified");
    }
}

/**
 * @title AddAdapter
 * @notice Add a new adapter to an existing registry
 */
contract AddAdapter is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address registryAddress = vm.envAddress("ADAPTER_REGISTRY");
        uint8 adapterId = uint8(vm.envUint("ADAPTER_ID"));
        address adapterAddress = vm.envAddress("ADAPTER_ADDRESS");

        AdapterRegistry registry = AdapterRegistry(registryAddress);

        console.log("Adding adapter to registry:", registryAddress);
        console.log("Adapter ID:", adapterId);
        console.log("Adapter Address:", adapterAddress);

        vm.startBroadcast(deployerPrivateKey);

        registry.setAdapter(adapterId, adapterAddress);

        vm.stopBroadcast();

        console.log("Adapter added successfully");
    }
}
