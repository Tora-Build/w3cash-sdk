// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { AdapterRegistry } from "../src/w3cash/AdapterRegistry.sol";

// New Adapters
import { BorrowAdapter } from "../src/w3cash/adapters/BorrowAdapter.sol";
import { RepayAdapter } from "../src/w3cash/adapters/RepayAdapter.sol";
import { DelegateAdapter } from "../src/w3cash/adapters/DelegateAdapter.sol";
import { VoteAdapter } from "../src/w3cash/adapters/VoteAdapter.sol";
import { ClaimAdapter } from "../src/w3cash/adapters/ClaimAdapter.sol";
import { BurnAdapter } from "../src/w3cash/adapters/BurnAdapter.sol";
import { MintAdapter } from "../src/w3cash/adapters/MintAdapter.sol";
import { LockAdapter } from "../src/w3cash/adapters/LockAdapter.sol";
import { UnwrapAdapter } from "../src/w3cash/adapters/UnwrapAdapter.sol";
import { FlashLoanAdapter } from "../src/w3cash/adapters/FlashLoanAdapter.sol";
import { AddLiquidityAdapter } from "../src/w3cash/adapters/AddLiquidityAdapter.sol";
import { RemoveLiquidityAdapter } from "../src/w3cash/adapters/RemoveLiquidityAdapter.sol";

// Condition Adapters
import { BalanceAdapter } from "../src/w3cash/adapters/BalanceAdapter.sol";
import { AllowanceAdapter } from "../src/w3cash/adapters/AllowanceAdapter.sol";
import { PriceAdapter } from "../src/w3cash/adapters/PriceAdapter.sol";
import { HealthFactorAdapter } from "../src/w3cash/adapters/HealthFactorAdapter.sol";

/**
 * @title DeployNewAdapters
 * @notice Deploy and register new adapters to existing W3Cash deployment
 */
contract DeployNewAdapters is Script {
    // Deployed W3Cash addresses (Base Sepolia)
    address constant PROCESSOR = 0x0fdFB12E72b08289F1374E69aCa39D69A279fdcE;
    address constant REGISTRY = 0x2E9e3AC48af39Fe96EbB5b71075FA847795B7A82;
    
    // Base Sepolia externals
    address constant AAVE_POOL = 0x07eA79F68B2B3df564D0A34F8e19D9B1e339814b; // Aave V3 Pool
    address constant AAVE_REWARDS = address(0); // No rewards controller on testnet
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant UNISWAP_POSITION_MANAGER = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;

    // New adapter IDs (continuing from existing: 0-7 are taken)
    uint8 constant BORROW_ADAPTER_ID = 8;
    uint8 constant REPAY_ADAPTER_ID = 9;
    uint8 constant DELEGATE_ADAPTER_ID = 10;
    uint8 constant VOTE_ADAPTER_ID = 11;
    uint8 constant CLAIM_ADAPTER_ID = 12;
    uint8 constant BURN_ADAPTER_ID = 13;
    uint8 constant MINT_ADAPTER_ID = 14;
    uint8 constant LOCK_ADAPTER_ID = 15;
    uint8 constant UNWRAP_ADAPTER_ID = 16;
    uint8 constant FLASHLOAN_ADAPTER_ID = 17;
    uint8 constant ADD_LIQUIDITY_ADAPTER_ID = 18;
    uint8 constant REMOVE_LIQUIDITY_ADAPTER_ID = 19;
    
    // Condition adapter IDs (100+)
    uint8 constant BALANCE_ADAPTER_ID = 100;
    uint8 constant ALLOWANCE_ADAPTER_ID = 101;
    uint8 constant PRICE_ADAPTER_ID = 102;
    uint8 constant HEALTH_FACTOR_ADAPTER_ID = 103;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying new adapters to W3Cash...");
        console.log("Deployer:", deployer);
        console.log("Processor:", PROCESSOR);
        console.log("Registry:", REGISTRY);

        AdapterRegistry registry = AdapterRegistry(REGISTRY);

        vm.startBroadcast(deployerPrivateKey);

        // ============ ACTION ADAPTERS ============
        
        // Borrow Adapter
        BorrowAdapter borrowAdapter = new BorrowAdapter(AAVE_POOL, PROCESSOR);
        console.log("BorrowAdapter deployed at:", address(borrowAdapter));
        registry.setAdapter(BORROW_ADAPTER_ID, address(borrowAdapter));

        // Repay Adapter
        RepayAdapter repayAdapter = new RepayAdapter(AAVE_POOL, PROCESSOR);
        console.log("RepayAdapter deployed at:", address(repayAdapter));
        registry.setAdapter(REPAY_ADAPTER_ID, address(repayAdapter));

        // Delegate Adapter
        DelegateAdapter delegateAdapter = new DelegateAdapter(PROCESSOR);
        console.log("DelegateAdapter deployed at:", address(delegateAdapter));
        registry.setAdapter(DELEGATE_ADAPTER_ID, address(delegateAdapter));

        // Vote Adapter
        VoteAdapter voteAdapter = new VoteAdapter(PROCESSOR);
        console.log("VoteAdapter deployed at:", address(voteAdapter));
        registry.setAdapter(VOTE_ADAPTER_ID, address(voteAdapter));

        // Claim Adapter
        ClaimAdapter claimAdapter = new ClaimAdapter(PROCESSOR, AAVE_REWARDS);
        console.log("ClaimAdapter deployed at:", address(claimAdapter));
        registry.setAdapter(CLAIM_ADAPTER_ID, address(claimAdapter));

        // Burn Adapter
        BurnAdapter burnAdapter = new BurnAdapter(PROCESSOR);
        console.log("BurnAdapter deployed at:", address(burnAdapter));
        registry.setAdapter(BURN_ADAPTER_ID, address(burnAdapter));

        // Mint Adapter
        MintAdapter mintAdapter = new MintAdapter(PROCESSOR);
        console.log("MintAdapter deployed at:", address(mintAdapter));
        registry.setAdapter(MINT_ADAPTER_ID, address(mintAdapter));

        // Lock Adapter
        LockAdapter lockAdapter = new LockAdapter(PROCESSOR);
        console.log("LockAdapter deployed at:", address(lockAdapter));
        registry.setAdapter(LOCK_ADAPTER_ID, address(lockAdapter));

        // Unwrap Adapter
        UnwrapAdapter unwrapAdapter = new UnwrapAdapter(WETH, PROCESSOR);
        console.log("UnwrapAdapter deployed at:", address(unwrapAdapter));
        registry.setAdapter(UNWRAP_ADAPTER_ID, address(unwrapAdapter));

        // FlashLoan Adapter
        FlashLoanAdapter flashLoanAdapter = new FlashLoanAdapter(AAVE_POOL, PROCESSOR);
        console.log("FlashLoanAdapter deployed at:", address(flashLoanAdapter));
        registry.setAdapter(FLASHLOAN_ADAPTER_ID, address(flashLoanAdapter));

        // Add Liquidity Adapter
        AddLiquidityAdapter addLiquidityAdapter = new AddLiquidityAdapter(UNISWAP_POSITION_MANAGER, PROCESSOR);
        console.log("AddLiquidityAdapter deployed at:", address(addLiquidityAdapter));
        registry.setAdapter(ADD_LIQUIDITY_ADAPTER_ID, address(addLiquidityAdapter));

        // Remove Liquidity Adapter
        RemoveLiquidityAdapter removeLiquidityAdapter = new RemoveLiquidityAdapter(UNISWAP_POSITION_MANAGER, PROCESSOR);
        console.log("RemoveLiquidityAdapter deployed at:", address(removeLiquidityAdapter));
        registry.setAdapter(REMOVE_LIQUIDITY_ADAPTER_ID, address(removeLiquidityAdapter));

        // ============ CONDITION ADAPTERS ============

        // Balance Adapter
        BalanceAdapter balanceAdapter = new BalanceAdapter(PROCESSOR);
        console.log("BalanceAdapter deployed at:", address(balanceAdapter));
        registry.setAdapter(BALANCE_ADAPTER_ID, address(balanceAdapter));

        // Allowance Adapter
        AllowanceAdapter allowanceAdapter = new AllowanceAdapter(PROCESSOR);
        console.log("AllowanceAdapter deployed at:", address(allowanceAdapter));
        registry.setAdapter(ALLOWANCE_ADAPTER_ID, address(allowanceAdapter));

        // Price Adapter
        PriceAdapter priceAdapter = new PriceAdapter(PROCESSOR);
        console.log("PriceAdapter deployed at:", address(priceAdapter));
        registry.setAdapter(PRICE_ADAPTER_ID, address(priceAdapter));

        // Health Factor Adapter
        HealthFactorAdapter healthFactorAdapter = new HealthFactorAdapter(AAVE_POOL, PROCESSOR);
        console.log("HealthFactorAdapter deployed at:", address(healthFactorAdapter));
        registry.setAdapter(HEALTH_FACTOR_ADAPTER_ID, address(healthFactorAdapter));

        vm.stopBroadcast();

        // Summary
        console.log("");
        console.log("=== NEW ADAPTERS DEPLOYED ===");
        console.log("");
        console.log("ACTION ADAPTERS:");
        console.log("  BorrowAdapter (ID 8):", address(borrowAdapter));
        console.log("  RepayAdapter (ID 9):", address(repayAdapter));
        console.log("  DelegateAdapter (ID 10):", address(delegateAdapter));
        console.log("  VoteAdapter (ID 11):", address(voteAdapter));
        console.log("  ClaimAdapter (ID 12):", address(claimAdapter));
        console.log("  BurnAdapter (ID 13):", address(burnAdapter));
        console.log("  MintAdapter (ID 14):", address(mintAdapter));
        console.log("  LockAdapter (ID 15):", address(lockAdapter));
        console.log("  UnwrapAdapter (ID 16):", address(unwrapAdapter));
        console.log("  FlashLoanAdapter (ID 17):", address(flashLoanAdapter));
        console.log("  AddLiquidityAdapter (ID 18):", address(addLiquidityAdapter));
        console.log("  RemoveLiquidityAdapter (ID 19):", address(removeLiquidityAdapter));
        console.log("");
        console.log("CONDITION ADAPTERS:");
        console.log("  BalanceAdapter (ID 100):", address(balanceAdapter));
        console.log("  AllowanceAdapter (ID 101):", address(allowanceAdapter));
        console.log("  PriceAdapter (ID 102):", address(priceAdapter));
        console.log("  HealthFactorAdapter (ID 103):", address(healthFactorAdapter));
    }
}
