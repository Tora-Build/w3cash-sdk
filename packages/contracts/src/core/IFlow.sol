// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IFlow
/// @notice Standard interface for w3cash flow contracts
/// @dev All flows must implement this interface to be executable via w3cash core
interface IFlow {
    /// @notice Execute a flow action
    /// @param caller The original caller (msg.sender to w3cash core)
    /// @param data The encoded action data
    /// @return result The encoded result of the action
    function execute(address caller, bytes calldata data) external payable returns (bytes memory result);

    /// @notice Get the unique identifier for this flow
    /// @return flowId The 4-byte flow identifier (e.g., "x402", "8004")
    function flowId() external pure returns (bytes4);

    /// @notice Check if this flow supports a specific action
    /// @param action The 4-byte action selector
    /// @return supported True if the action is supported
    function supportsAction(bytes4 action) external view returns (bool);

    /// @notice Get human-readable flow metadata
    /// @return name The flow name
    /// @return version The flow version
    function metadata() external pure returns (string memory name, string memory version);
}
