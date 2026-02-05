// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapterRegistry } from "./interfaces/IAdapterRegistry.sol";
import { IAdapter } from "./adapters/interfaces/IAdapter.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title AdapterRegistry
 * @notice Upgradeable registry for POCA adapters with freeze capability
 * @dev
 * - Owner can add/update adapters until they are frozen
 * - Once frozen, an adapter cannot be changed (permanent immutability)
 * - New adapter IDs can always be added (extensibility)
 * - Ownership can be transferred to multisig/DAO for decentralization
 *
 * Trust Model:
 * - Before freeze: Admin-controlled (trusted)
 * - After freeze: Trustless (immutable)
 */
contract AdapterRegistry is IAdapterRegistry, Ownable {
    // --- State ---

    /// @notice Adapter address by ID
    mapping(uint8 => address) private _adapters;

    /// @notice Whether adapter ID is frozen (immutable)
    mapping(uint8 => bool) private _adapterFrozen;

    /// @notice Chain ID mapping by index
    mapping(uint8 => uint256) private _chains;

    /// @notice Whether chain mapping is frozen
    mapping(uint8 => bool) private _chainFrozen;

    // --- Constructor ---

    constructor(address initialOwner) Ownable(initialOwner) {}

    // --- Read Functions ---

    /// @inheritdoc IAdapterRegistry
    function owner() public view override(IAdapterRegistry, Ownable) returns (address) {
        return Ownable.owner();
    }

    /// @inheritdoc IAdapterRegistry
    function getAdapter(uint8 id) external view override returns (IAdapter) {
        address adapter = _adapters[id];
        if (adapter == address(0)) revert AdapterNotRegistered();
        return IAdapter(adapter);
    }

    /// @inheritdoc IAdapterRegistry
    function isAdapterRegistered(uint8 id) external view override returns (bool) {
        return _adapters[id] != address(0);
    }

    /// @inheritdoc IAdapterRegistry
    function isAdapterFrozen(uint8 id) external view override returns (bool) {
        return _adapterFrozen[id];
    }

    /// @inheritdoc IAdapterRegistry
    function getChain(uint8 chain) external view override returns (uint256) {
        uint256 chainId = _chains[chain];
        if (chainId == 0) revert ChainNotRegistered();
        return chainId;
    }

    /// @inheritdoc IAdapterRegistry
    function isChainFrozen(uint8 chain) external view override returns (bool) {
        return _chainFrozen[chain];
    }

    // --- Admin Functions ---

    /// @inheritdoc IAdapterRegistry
    function setAdapter(uint8 id, address adapter) external override onlyOwner {
        if (_adapterFrozen[id]) revert AdapterAlreadyFrozen();
        if (adapter == address(0)) revert InvalidAdapter();

        _adapters[id] = adapter;
        emit AdapterSet(id, adapter);
    }

    /// @inheritdoc IAdapterRegistry
    function freezeAdapter(uint8 id) external override onlyOwner {
        address adapter = _adapters[id];
        if (adapter == address(0)) revert AdapterNotRegistered();
        if (_adapterFrozen[id]) revert AdapterAlreadyFrozen();

        _adapterFrozen[id] = true;
        emit AdapterFrozen(id, adapter);
    }

    /// @inheritdoc IAdapterRegistry
    function setChain(uint8 chain, uint256 chainId) external override onlyOwner {
        if (_chainFrozen[chain]) revert ChainAlreadyFrozen();
        if (chainId == 0) revert InvalidChainId();

        _chains[chain] = chainId;
        emit ChainSet(chain, chainId);
    }

    /// @inheritdoc IAdapterRegistry
    function freezeChain(uint8 chain) external override onlyOwner {
        uint256 chainId = _chains[chain];
        if (chainId == 0) revert ChainNotRegistered();
        if (_chainFrozen[chain]) revert ChainAlreadyFrozen();

        _chainFrozen[chain] = true;
        emit ChainFrozen(chain, chainId);
    }

    // --- Batch Operations ---

    /**
     * @notice Set multiple adapters at once
     * @param ids Adapter IDs
     * @param adapters Adapter addresses
     */
    function setAdapters(uint8[] calldata ids, address[] calldata adapters) external onlyOwner {
        require(ids.length == adapters.length, "Length mismatch");
        for (uint256 i = 0; i < ids.length; i++) {
            if (_adapterFrozen[ids[i]]) revert AdapterAlreadyFrozen();
            if (adapters[i] == address(0)) revert InvalidAdapter();

            _adapters[ids[i]] = adapters[i];
            emit AdapterSet(ids[i], adapters[i]);
        }
    }

    /**
     * @notice Freeze multiple adapters at once
     * @param ids Adapter IDs to freeze
     */
    function freezeAdapters(uint8[] calldata ids) external onlyOwner {
        for (uint256 i = 0; i < ids.length; i++) {
            address adapter = _adapters[ids[i]];
            if (adapter == address(0)) revert AdapterNotRegistered();
            if (_adapterFrozen[ids[i]]) revert AdapterAlreadyFrozen();

            _adapterFrozen[ids[i]] = true;
            emit AdapterFrozen(ids[i], adapter);
        }
    }

    /**
     * @notice Set multiple chain mappings at once
     * @param chains Chain indices
     * @param chainIds EVM chain IDs
     */
    function setChains(uint8[] calldata chains, uint256[] calldata chainIds) external onlyOwner {
        require(chains.length == chainIds.length, "Length mismatch");
        for (uint256 i = 0; i < chains.length; i++) {
            if (_chainFrozen[chains[i]]) revert ChainAlreadyFrozen();
            if (chainIds[i] == 0) revert InvalidChainId();

            _chains[chains[i]] = chainIds[i];
            emit ChainSet(chains[i], chainIds[i]);
        }
    }
}
