// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {AdapterRegistry} from "../src/w3cash/AdapterRegistry.sol";
import {W3CashProcessorLegacy} from "../src/w3cash/W3CashProcessorLegacy.sol";
import {TransferAdapter} from "../src/w3cash/adapters/TransferAdapter.sol";
import {ApproveAdapter} from "../src/w3cash/adapters/ApproveAdapter.sol";
import {WaitAdapter} from "../src/w3cash/adapters/WaitAdapter.sol";
import {QueryAdapter} from "../src/w3cash/adapters/QueryAdapter.sol";
import {GasPriceAdapter} from "../src/w3cash/adapters/GasPriceAdapter.sol";
import {TimeRangeAdapter} from "../src/w3cash/adapters/TimeRangeAdapter.sol";
import {SignatureAdapter} from "../src/w3cash/adapters/SignatureAdapter.sol";

/// @notice Deploys the minimal W3Cash core (no external-protocol adapters) — for
///         chains like X Layer testnet where Uniswap/Aave/Across/Chainlink aren't
///         available. Covers transfer/approve + the time/block/gas/query/co-signer gates.
contract DeployXLayerCore is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);
        AdapterRegistry registry = new AdapterRegistry(deployer);
        W3CashProcessorLegacy processor = new W3CashProcessorLegacy(address(registry));
        address p = address(processor);

        TransferAdapter transferA = new TransferAdapter(p);
        ApproveAdapter approveA = new ApproveAdapter(p);
        WaitAdapter waitA = new WaitAdapter(p);
        QueryAdapter queryA = new QueryAdapter(p);
        GasPriceAdapter gasA = new GasPriceAdapter(p);
        TimeRangeAdapter timeA = new TimeRangeAdapter(p);
        SignatureAdapter sigA = new SignatureAdapter(p);
        vm.stopBroadcast();

        console2.log("DEPLOYER  ", deployer);
        console2.log("registry  ", address(registry));
        console2.log("processor ", p);
        console2.log("transfer  ", address(transferA));
        console2.log("approve   ", address(approveA));
        console2.log("wait      ", address(waitA));
        console2.log("query     ", address(queryA));
        console2.log("gasPrice  ", address(gasA));
        console2.log("timeRange ", address(timeA));
        console2.log("signature ", address(sigA));
    }
}
