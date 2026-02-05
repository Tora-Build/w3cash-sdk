// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "../adapters/interfaces/IAdapter.sol";

/**
 * @title IAdapterRegistry
 * @notice Interface for the adapter registry used by W3CashProcessor
 * @dev Registry manages adapter registration with freeze capability for immutability
 */
interface IAdapterRegistry {
    // --- Events ---
    event AdapterSet(uint8 indexed id, address indexed adapter);
    event AdapterFrozen(uint8 indexed id, address indexed adapter);
    event ChainSet(uint8 indexed chain, uint256 chainId);
    event ChainFrozen(uint8 indexed chain, uint256 chainId);

    // --- Errors ---
    error AdapterAlreadyFrozen();
    error AdapterNotRegistered();
    error ChainAlreadyFrozen();
    error ChainNotRegistered();
    error InvalidAdapter();
    error InvalidChainId();

    // --- Read Functions ---

    /**
     * @notice Get the registry owner address
     * @return owner The owner address
     */
    function owner() external view returns (address);

    /**
     * @notice Get adapter by ID
     * @param id Adapter index (0-255)
     * @return adapter The adapter contract
     */
    function getAdapter(uint8 id) external view returns (IAdapter adapter);

    /**
     * @notice Check if adapter is registered
     * @param id Adapter index
     * @return registered True if adapter is set
     */
    function isAdapterRegistered(uint8 id) external view returns (bool registered);

    /**
     * @notice Check if adapter is frozen (immutable)
     * @param id Adapter index
     * @return frozen True if adapter cannot be changed
     */
    function isAdapterFrozen(uint8 id) external view returns (bool frozen);

    /**
     * @notice Get chain ID mapping
     * @param chain Chain index (0-255)
     * @return chainId The EVM chain ID
     */
    function getChain(uint8 chain) external view returns (uint256 chainId);

    /**
     * @notice Check if chain is frozen
     * @param chain Chain index
     * @return frozen True if chain mapping cannot be changed
     */
    function isChainFrozen(uint8 chain) external view returns (bool frozen);

    // --- Write Functions (Owner Only) ---

    /**
     * @notice Set adapter address for given ID
     * @param id Adapter index
     * @param adapter Adapter contract address
     */
    function setAdapter(uint8 id, address adapter) external;

    /**
     * @notice Freeze adapter permanently (cannot be changed after)
     * @param id Adapter index to freeze
     */
    function freezeAdapter(uint8 id) external;

    /**
     * @notice Set chain ID mapping
     * @param chain Chain index
     * @param chainId EVM chain ID
     */
    function setChain(uint8 chain, uint256 chainId) external;

    /**
     * @notice Freeze chain mapping permanently
     * @param chain Chain index to freeze
     */
    function freezeChain(uint8 chain) external;
}
