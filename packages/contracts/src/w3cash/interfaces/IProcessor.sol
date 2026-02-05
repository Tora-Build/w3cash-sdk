// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IProcessor
 * @notice Interface for POCA Processor contracts
 */
interface IProcessor {
    // --- Events ---
    event AdapterRegistered(bytes4 indexed adapterId, address indexed adapter);
    event AdapterRemoved(bytes4 indexed adapterId);
    event InstructionExecuted(address indexed caller, bytes32 indexed instructionHash, bool success, bytes result);
    event WorkflowPaused(uint256 seq, bytes32 payloadHash);
    event CrossChainMessageSent(bytes instruction);

    // --- Functions ---
    
    /**
     * @notice Execute an instruction
     */
    function execute(bytes calldata instruction) external returns (bytes memory);

    /**
     * @notice Execute multiple instructions atomically
     */
    function executeBatch(bytes[] calldata instructions) external returns (bytes[] memory);

    /**
     * @notice Get adapter address by ID
     */
    function getAdapter(bytes4 adapterId) external view returns (address);

    /**
     * @notice Check if adapter is registered
     */
    function isAdapterRegistered(bytes4 adapterId) external view returns (bool);
}
