// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { AdapterRegistry } from "../src/poca/AdapterRegistry.sol";
import { IAdapterRegistry } from "../src/poca/interfaces/IAdapterRegistry.sol";
import { IAdapter } from "../src/poca/adapters/interfaces/IAdapter.sol";

/// @dev Mock adapter for testing
contract MockAdapter is IAdapter {
    bytes4 public constant ADAPTER_ID = 0x12345678;

    function execute(address, bytes calldata) external payable override returns (bytes memory) {
        return abi.encode("executed");
    }

    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    function send(bytes memory, uint8, uint64, uint112) external payable override returns (uint64) {
        return 0;
    }

    function estimateFee(uint8, uint112, uint256) external pure override returns (uint256) {
        return 0.001 ether;
    }
}

contract AdapterRegistryTest is Test {
    AdapterRegistry public registry;
    MockAdapter public adapter1;
    MockAdapter public adapter2;

    address public owner = address(0x1);
    address public nonOwner = address(0x2);

    uint8 constant ADAPTER_ID_1 = 0;
    uint8 constant ADAPTER_ID_2 = 1;
    uint8 constant CHAIN_INDEX = 0;
    uint256 constant CHAIN_ID = 84532; // Base Sepolia

    event AdapterSet(uint8 indexed id, address indexed adapter);
    event AdapterFrozen(uint8 indexed id, address indexed adapter);
    event ChainSet(uint8 indexed chain, uint256 chainId);
    event ChainFrozen(uint8 indexed chain, uint256 chainId);

    function setUp() public {
        vm.startPrank(owner);
        registry = new AdapterRegistry(owner);
        adapter1 = new MockAdapter();
        adapter2 = new MockAdapter();
        vm.stopPrank();
    }

    // --- Constructor Tests ---

    function test_Constructor_SetsOwner() public view {
        assertEq(registry.owner(), owner);
    }

    // --- setAdapter Tests ---

    function test_SetAdapter_Success() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit AdapterSet(ADAPTER_ID_1, address(adapter1));
        registry.setAdapter(ADAPTER_ID_1, address(adapter1));

        assertEq(address(registry.getAdapter(ADAPTER_ID_1)), address(adapter1));
        assertTrue(registry.isAdapterRegistered(ADAPTER_ID_1));
    }

    function test_SetAdapter_RevertIfNotOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        registry.setAdapter(ADAPTER_ID_1, address(adapter1));
    }

    function test_SetAdapter_RevertIfZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IAdapterRegistry.InvalidAdapter.selector);
        registry.setAdapter(ADAPTER_ID_1, address(0));
    }

    function test_SetAdapter_RevertIfFrozen() public {
        vm.startPrank(owner);
        registry.setAdapter(ADAPTER_ID_1, address(adapter1));
        registry.freezeAdapter(ADAPTER_ID_1);

        vm.expectRevert(IAdapterRegistry.AdapterAlreadyFrozen.selector);
        registry.setAdapter(ADAPTER_ID_1, address(adapter2));
        vm.stopPrank();
    }

    function test_SetAdapter_CanReplaceBeforeFreeze() public {
        vm.startPrank(owner);
        registry.setAdapter(ADAPTER_ID_1, address(adapter1));
        assertEq(address(registry.getAdapter(ADAPTER_ID_1)), address(adapter1));

        registry.setAdapter(ADAPTER_ID_1, address(adapter2));
        assertEq(address(registry.getAdapter(ADAPTER_ID_1)), address(adapter2));
        vm.stopPrank();
    }

    // --- freezeAdapter Tests ---

    function test_FreezeAdapter_Success() public {
        vm.startPrank(owner);
        registry.setAdapter(ADAPTER_ID_1, address(adapter1));

        vm.expectEmit(true, true, false, false);
        emit AdapterFrozen(ADAPTER_ID_1, address(adapter1));
        registry.freezeAdapter(ADAPTER_ID_1);

        assertTrue(registry.isAdapterFrozen(ADAPTER_ID_1));
        vm.stopPrank();
    }

    function test_FreezeAdapter_RevertIfNotRegistered() public {
        vm.prank(owner);
        vm.expectRevert(IAdapterRegistry.AdapterNotRegistered.selector);
        registry.freezeAdapter(ADAPTER_ID_1);
    }

    function test_FreezeAdapter_RevertIfAlreadyFrozen() public {
        vm.startPrank(owner);
        registry.setAdapter(ADAPTER_ID_1, address(adapter1));
        registry.freezeAdapter(ADAPTER_ID_1);

        vm.expectRevert(IAdapterRegistry.AdapterAlreadyFrozen.selector);
        registry.freezeAdapter(ADAPTER_ID_1);
        vm.stopPrank();
    }

    function test_FreezeAdapter_RevertIfNotOwner() public {
        vm.prank(owner);
        registry.setAdapter(ADAPTER_ID_1, address(adapter1));

        vm.prank(nonOwner);
        vm.expectRevert();
        registry.freezeAdapter(ADAPTER_ID_1);
    }

    // --- getAdapter Tests ---

    function test_GetAdapter_RevertIfNotRegistered() public {
        vm.expectRevert(IAdapterRegistry.AdapterNotRegistered.selector);
        registry.getAdapter(ADAPTER_ID_1);
    }

    function test_GetAdapter_ReturnsCorrectAdapter() public {
        vm.prank(owner);
        registry.setAdapter(ADAPTER_ID_1, address(adapter1));

        IAdapter retrieved = registry.getAdapter(ADAPTER_ID_1);
        assertEq(address(retrieved), address(adapter1));
    }

    // --- Chain Management Tests ---

    function test_SetChain_Success() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit ChainSet(CHAIN_INDEX, CHAIN_ID);
        registry.setChain(CHAIN_INDEX, CHAIN_ID);

        assertEq(registry.getChain(CHAIN_INDEX), CHAIN_ID);
    }

    function test_SetChain_RevertIfNotOwner() public {
        vm.prank(nonOwner);
        vm.expectRevert();
        registry.setChain(CHAIN_INDEX, CHAIN_ID);
    }

    function test_SetChain_RevertIfFrozen() public {
        vm.startPrank(owner);
        registry.setChain(CHAIN_INDEX, CHAIN_ID);
        registry.freezeChain(CHAIN_INDEX);

        vm.expectRevert(IAdapterRegistry.ChainAlreadyFrozen.selector);
        registry.setChain(CHAIN_INDEX, 1);
        vm.stopPrank();
    }

    function test_FreezeChain_Success() public {
        vm.startPrank(owner);
        registry.setChain(CHAIN_INDEX, CHAIN_ID);

        vm.expectEmit(true, false, false, true);
        emit ChainFrozen(CHAIN_INDEX, CHAIN_ID);
        registry.freezeChain(CHAIN_INDEX);

        assertTrue(registry.isChainFrozen(CHAIN_INDEX));
        vm.stopPrank();
    }

    function test_FreezeChain_RevertIfNotRegistered() public {
        vm.prank(owner);
        vm.expectRevert(IAdapterRegistry.ChainNotRegistered.selector);
        registry.freezeChain(CHAIN_INDEX);
    }

    function test_GetChain_RevertIfNotRegistered() public {
        vm.expectRevert(IAdapterRegistry.ChainNotRegistered.selector);
        registry.getChain(CHAIN_INDEX);
    }

    // --- Batch Operations Tests ---

    function test_SetAdapters_Batch() public {
        uint8[] memory ids = new uint8[](2);
        ids[0] = ADAPTER_ID_1;
        ids[1] = ADAPTER_ID_2;

        address[] memory adapters = new address[](2);
        adapters[0] = address(adapter1);
        adapters[1] = address(adapter2);

        vm.prank(owner);
        registry.setAdapters(ids, adapters);

        assertEq(address(registry.getAdapter(ADAPTER_ID_1)), address(adapter1));
        assertEq(address(registry.getAdapter(ADAPTER_ID_2)), address(adapter2));
    }

    function test_SetAdapters_RevertIfLengthMismatch() public {
        uint8[] memory ids = new uint8[](2);
        address[] memory adapters = new address[](1);

        vm.prank(owner);
        vm.expectRevert("Length mismatch");
        registry.setAdapters(ids, adapters);
    }

    function test_FreezeAdapters_Batch() public {
        vm.startPrank(owner);
        registry.setAdapter(ADAPTER_ID_1, address(adapter1));
        registry.setAdapter(ADAPTER_ID_2, address(adapter2));

        uint8[] memory ids = new uint8[](2);
        ids[0] = ADAPTER_ID_1;
        ids[1] = ADAPTER_ID_2;

        registry.freezeAdapters(ids);

        assertTrue(registry.isAdapterFrozen(ADAPTER_ID_1));
        assertTrue(registry.isAdapterFrozen(ADAPTER_ID_2));
        vm.stopPrank();
    }

    function test_SetChains_Batch() public {
        uint8[] memory chains = new uint8[](2);
        chains[0] = 0;
        chains[1] = 1;

        uint256[] memory chainIds = new uint256[](2);
        chainIds[0] = 84532;
        chainIds[1] = 8453;

        vm.prank(owner);
        registry.setChains(chains, chainIds);

        assertEq(registry.getChain(0), 84532);
        assertEq(registry.getChain(1), 8453);
    }

    // --- Immutability After Freeze Tests ---

    function test_FrozenAdapter_CanStillBeRead() public {
        vm.startPrank(owner);
        registry.setAdapter(ADAPTER_ID_1, address(adapter1));
        registry.freezeAdapter(ADAPTER_ID_1);
        vm.stopPrank();

        // Should still be able to read
        IAdapter retrieved = registry.getAdapter(ADAPTER_ID_1);
        assertEq(address(retrieved), address(adapter1));
    }

    function test_FrozenAdapter_CanStillExecute() public {
        vm.startPrank(owner);
        registry.setAdapter(ADAPTER_ID_1, address(adapter1));
        registry.freezeAdapter(ADAPTER_ID_1);
        vm.stopPrank();

        IAdapter adapter = registry.getAdapter(ADAPTER_ID_1);
        bytes memory result = adapter.execute(address(this), "");
        assertEq(abi.decode(result, (string)), "executed");
    }

    function test_NewAdapterCanBeAddedAfterOthersFrozen() public {
        vm.startPrank(owner);
        // Freeze adapter 1
        registry.setAdapter(ADAPTER_ID_1, address(adapter1));
        registry.freezeAdapter(ADAPTER_ID_1);

        // Can still add adapter 2
        registry.setAdapter(ADAPTER_ID_2, address(adapter2));
        assertEq(address(registry.getAdapter(ADAPTER_ID_2)), address(adapter2));
        vm.stopPrank();
    }
}
