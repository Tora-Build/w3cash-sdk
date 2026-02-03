// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IFlow} from "./IFlow.sol";

/// @title W3CashCore
/// @notice Minimal, immutable router for flow execution
/// @dev No state, no admin, no upgrades — maximum trust
/// @custom:security-contact security@w3.cash
contract W3CashCore {
    /// @notice Emitted when a flow is executed
    event FlowExecuted(address indexed caller, address indexed flow, bool success);

    /// @notice Execute a single flow
    /// @param flow The flow contract address
    /// @param data The calldata to pass to the flow
    /// @return result The result from the flow
    function execute(address flow, bytes calldata data) external returns (bytes memory result) {
        result = IFlow(flow).execute(msg.sender, data);
        emit FlowExecuted(msg.sender, flow, true);
    }

    /// @notice Execute multiple flows atomically
    /// @param flows Array of flow contract addresses
    /// @param datas Array of calldata for each flow
    /// @return results Array of results from each flow
    function executeBatch(
        address[] calldata flows,
        bytes[] calldata datas
    ) external returns (bytes[] memory results) {
        require(flows.length == datas.length, "length mismatch");
        results = new bytes[](flows.length);
        for (uint256 i = 0; i < flows.length; i++) {
            results[i] = IFlow(flows[i]).execute(msg.sender, datas[i]);
            emit FlowExecuted(msg.sender, flows[i], true);
        }
    }
}
