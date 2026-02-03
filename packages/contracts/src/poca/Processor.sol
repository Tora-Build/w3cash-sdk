// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./adapters/interfaces/IAdapter.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Processor
 * @notice Simple adapter-based instruction processor
 * @dev Routes instructions to registered adapters based on adapter ID
 */
contract Processor is Ownable {
    // --- Errors ---
    error AdapterNotRegistered(bytes4 adapterId);
    error AdapterAlreadyRegistered(bytes4 adapterId);
    error InvalidInstruction();
    error ExecutionFailed(bytes reason);
    error ZeroAddress();

    // --- State ---
    mapping(bytes4 => address) private _adapters;
    bytes4[] private _adapterIds;

    // --- Events ---
    event AdapterRegistered(bytes4 indexed adapterId, address indexed adapter);
    event AdapterRemoved(bytes4 indexed adapterId);
    event InstructionExecuted(address indexed caller, bytes32 indexed instructionHash, bool success, bytes result);

    // --- Constructor ---
    constructor(address initialOwner) Ownable(initialOwner) {}

    // --- Adapter Management ---

    function registerAdapter(address adapter) external onlyOwner {
        if (adapter == address(0)) revert ZeroAddress();
        
        bytes4 adapterId = IAdapter(adapter).adapterId();
        if (_adapters[adapterId] != address(0)) {
            revert AdapterAlreadyRegistered(adapterId);
        }

        _adapters[adapterId] = adapter;
        _adapterIds.push(adapterId);

        emit AdapterRegistered(adapterId, adapter);
    }

    function removeAdapter(bytes4 adapterId) external onlyOwner {
        if (_adapters[adapterId] == address(0)) {
            revert AdapterNotRegistered(adapterId);
        }

        delete _adapters[adapterId];

        for (uint256 i = 0; i < _adapterIds.length; i++) {
            if (_adapterIds[i] == adapterId) {
                _adapterIds[i] = _adapterIds[_adapterIds.length - 1];
                _adapterIds.pop();
                break;
            }
        }

        emit AdapterRemoved(adapterId);
    }

    function getAdapter(bytes4 adapterId) external view returns (address) {
        return _adapters[adapterId];
    }

    function isAdapterRegistered(bytes4 adapterId) external view returns (bool) {
        return _adapters[adapterId] != address(0);
    }

    function getAdapterIds() external view returns (bytes4[] memory) {
        return _adapterIds;
    }

    // --- Instruction Execution ---

    /**
     * @notice Execute a single instruction
     * @param instruction Encoded as [adapterId (4 bytes)][data (remaining)]
     */
    function execute(bytes calldata instruction) external returns (bytes memory result) {
        if (instruction.length < 4) revert InvalidInstruction();

        bytes4 adapterId = bytes4(instruction[:4]);
        bytes calldata data = instruction[4:];

        address adapter = _adapters[adapterId];
        if (adapter == address(0)) {
            revert AdapterNotRegistered(adapterId);
        }

        try IAdapter(adapter).execute(msg.sender, data) returns (bytes memory adapterResult) {
            result = adapterResult;
            emit InstructionExecuted(msg.sender, keccak256(instruction), true, result);
        } catch (bytes memory reason) {
            emit InstructionExecuted(msg.sender, keccak256(instruction), false, reason);
            revert ExecutionFailed(reason);
        }
    }

    /**
     * @notice Execute multiple instructions atomically
     */
    function executeBatch(bytes[] calldata instructions) external returns (bytes[] memory results) {
        results = new bytes[](instructions.length);

        for (uint256 i = 0; i < instructions.length; i++) {
            bytes calldata instruction = instructions[i];
            if (instruction.length < 4) revert InvalidInstruction();

            bytes4 adapterId = bytes4(instruction[:4]);
            bytes calldata data = instruction[4:];

            address adapter = _adapters[adapterId];
            if (adapter == address(0)) {
                revert AdapterNotRegistered(adapterId);
            }

            try IAdapter(adapter).execute(msg.sender, data) returns (bytes memory adapterResult) {
                results[i] = adapterResult;
                emit InstructionExecuted(msg.sender, keccak256(instruction), true, adapterResult);
            } catch (bytes memory reason) {
                emit InstructionExecuted(msg.sender, keccak256(instruction), false, reason);
                revert ExecutionFailed(reason);
            }
        }
    }
}
