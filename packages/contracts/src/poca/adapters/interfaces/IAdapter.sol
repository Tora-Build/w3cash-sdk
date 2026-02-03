// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IAdapter
 * @notice Interface for POCA adapters (WaitAdapter, SwapAdapter, BridgeAdapter, etc.)
 */
interface IAdapter {
    /**
     * @notice Execute an adapter action
     * @param initiator The original caller/signer
     * @param data Encoded action parameters
     * @return result Execution result (or PAUSE_EXECUTION bytes)
     */
    function execute(address initiator, bytes calldata data)
        external
        payable
        returns (bytes memory result);

    /**
     * @notice Get the adapter's unique identifier
     * @return adapterId 4-byte identifier
     */
    function adapterId() external pure returns (bytes4);

    /**
     * @notice Send cross-chain message (for AMB adapters)
     */
    function send(bytes memory instruction, uint8 chain, uint64 fee, uint112 value)
        external
        payable
        returns (uint64);

    /**
     * @notice Estimate fee for cross-chain execution
     */
    function estimateFee(uint8 chain, uint112 value, uint256 gasLimit)
        external
        view
        returns (uint256);
}
