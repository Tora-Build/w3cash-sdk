// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { AdapterRegistry } from "../src/w3cash/AdapterRegistry.sol";

// New Adapters
import { LiquidateAdapter } from "../src/w3cash/adapters/LiquidateAdapter.sol";
import { CompoundAdapter } from "../src/w3cash/adapters/CompoundAdapter.sol";
import { SignatureAdapter } from "../src/w3cash/adapters/SignatureAdapter.sol";
import { BatchAdapter } from "../src/w3cash/adapters/BatchAdapter.sol";
import { GasPriceAdapter } from "../src/w3cash/adapters/GasPriceAdapter.sol";
import { TimeRangeAdapter } from "../src/w3cash/adapters/TimeRangeAdapter.sol";
import { StakeAdapter } from "../src/w3cash/adapters/StakeAdapter.sol";

/**
 * @title DeployMoreAdapters
 * @notice Deploy additional adapters to W3Cash
 */
contract DeployMoreAdapters is Script {
    // Deployed W3Cash addresses (Base Sepolia)
    address constant PROCESSOR = 0x0fdFB12E72b08289F1374E69aCa39D69A279fdcE;
    address constant REGISTRY = 0x2E9e3AC48af39Fe96EbB5b71075FA847795B7A82;
    
    // Base Sepolia externals
    address constant AAVE_POOL = 0x07eA79F68B2B3df564D0A34F8e19D9B1e339814b;
    
    // Compound V3 - using placeholder (not deployed on Base Sepolia)
    address constant COMPOUND_COMET = address(0);
    
    // Staking - using placeholders for testnet
    address constant LIDO_STETH = address(0);
    address constant WSTETH = address(0);
    address constant CBETH = address(0);
    address constant RETH = address(0);
    address constant ROCKET_DEPOSIT = address(0);

    // Adapter IDs (continuing from 19)
    uint8 constant LIQUIDATE_ADAPTER_ID = 20;
    uint8 constant COMPOUND_ADAPTER_ID = 21;
    uint8 constant BATCH_ADAPTER_ID = 22;
    uint8 constant STAKE_ADAPTER_ID = 23;
    
    // Condition adapter IDs
    uint8 constant SIGNATURE_ADAPTER_ID = 104;
    uint8 constant GAS_PRICE_ADAPTER_ID = 105;
    uint8 constant TIME_RANGE_ADAPTER_ID = 106;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying additional adapters...");
        console.log("Deployer:", deployer);

        AdapterRegistry registry = AdapterRegistry(REGISTRY);

        vm.startBroadcast(deployerPrivateKey);

        // ============ ACTION ADAPTERS ============
        
        // Liquidate Adapter
        LiquidateAdapter liquidateAdapter = new LiquidateAdapter(AAVE_POOL, PROCESSOR);
        console.log("LiquidateAdapter deployed at:", address(liquidateAdapter));
        registry.setAdapter(LIQUIDATE_ADAPTER_ID, address(liquidateAdapter));

        // Batch Adapter
        BatchAdapter batchAdapter = new BatchAdapter(PROCESSOR, REGISTRY);
        console.log("BatchAdapter deployed at:", address(batchAdapter));
        registry.setAdapter(BATCH_ADAPTER_ID, address(batchAdapter));

        // Stake Adapter (with placeholder addresses - won't work on testnet)
        StakeAdapter stakeAdapter = new StakeAdapter(
            LIDO_STETH,
            WSTETH,
            CBETH,
            RETH,
            ROCKET_DEPOSIT,
            PROCESSOR
        );
        console.log("StakeAdapter deployed at:", address(stakeAdapter));
        registry.setAdapter(STAKE_ADAPTER_ID, address(stakeAdapter));

        // ============ CONDITION ADAPTERS ============

        // Signature Adapter
        SignatureAdapter signatureAdapter = new SignatureAdapter(PROCESSOR);
        console.log("SignatureAdapter deployed at:", address(signatureAdapter));
        registry.setAdapter(SIGNATURE_ADAPTER_ID, address(signatureAdapter));

        // Gas Price Adapter
        GasPriceAdapter gasPriceAdapter = new GasPriceAdapter(PROCESSOR);
        console.log("GasPriceAdapter deployed at:", address(gasPriceAdapter));
        registry.setAdapter(GAS_PRICE_ADAPTER_ID, address(gasPriceAdapter));

        // Time Range Adapter
        TimeRangeAdapter timeRangeAdapter = new TimeRangeAdapter(PROCESSOR);
        console.log("TimeRangeAdapter deployed at:", address(timeRangeAdapter));
        registry.setAdapter(TIME_RANGE_ADAPTER_ID, address(timeRangeAdapter));

        vm.stopBroadcast();

        // Summary
        console.log("");
        console.log("=== ADDITIONAL ADAPTERS DEPLOYED ===");
        console.log("");
        console.log("ACTION ADAPTERS:");
        console.log("  LiquidateAdapter (ID 20):", address(liquidateAdapter));
        console.log("  BatchAdapter (ID 22):", address(batchAdapter));
        console.log("  StakeAdapter (ID 23):", address(stakeAdapter));
        console.log("");
        console.log("CONDITION ADAPTERS:");
        console.log("  SignatureAdapter (ID 104):", address(signatureAdapter));
        console.log("  GasPriceAdapter (ID 105):", address(gasPriceAdapter));
        console.log("  TimeRangeAdapter (ID 106):", address(timeRangeAdapter));
    }
}
