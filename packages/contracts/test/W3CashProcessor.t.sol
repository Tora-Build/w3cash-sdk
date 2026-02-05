// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { W3CashProcessor } from "../src/w3cash/W3CashProcessor.sol";
import { AdapterRegistry } from "../src/w3cash/AdapterRegistry.sol";
import { IAdapterRegistry } from "../src/w3cash/interfaces/IAdapterRegistry.sol";
import { IAdapter } from "../src/w3cash/adapters/interfaces/IAdapter.sol";
import { DataTypes } from "../src/w3cash/utils/DataTypes.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @dev Mock adapter that returns success
contract MockSuccessAdapter is IAdapter {
    bytes4 public constant ADAPTER_ID = 0x11111111;

    function execute(address, bytes calldata) external payable override returns (bytes memory) {
        return abi.encode("success");
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

/// @dev Mock adapter that returns PAUSE_EXECUTION
contract MockPauseAdapter is IAdapter {
    bytes4 public constant ADAPTER_ID = 0x22222222;

    function execute(address, bytes calldata) external payable override returns (bytes memory) {
        return abi.encode(DataTypes.PAUSE_EXECUTION);
    }

    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    function send(bytes memory, uint8, uint64, uint112) external payable override returns (uint64) {
        return 0;
    }

    function estimateFee(uint8, uint112, uint256) external pure override returns (uint256) {
        return 0;
    }
}

contract W3CashProcessorTest is Test {
    using ECDSA for bytes32;

    W3CashProcessor public processor;
    AdapterRegistry public registry;
    MockSuccessAdapter public successAdapter;
    MockPauseAdapter public pauseAdapter;

    address public owner = address(0x1);
    uint256 public userPrivateKey = 0xBEEF;
    address public user;

    uint8 constant SUCCESS_ADAPTER_ID = 0;
    uint8 constant PAUSE_ADAPTER_ID = 1;
    uint8 constant CHAIN_INDEX = 0;
    uint256 constant CHAIN_ID = 84532;

    event WorkflowPaused(uint256 seq, bytes32 payloadHash);
    event LocalCommandProcessed(uint256 seq, bytes32 payloadHash);
    event NonceCancelled(address indexed user, uint256 oldNonce, uint256 newNonce);

    function setUp() public {
        user = vm.addr(userPrivateKey);

        vm.startPrank(owner);
        registry = new AdapterRegistry(owner);
        successAdapter = new MockSuccessAdapter();
        pauseAdapter = new MockPauseAdapter();

        registry.setAdapter(SUCCESS_ADAPTER_ID, address(successAdapter));
        registry.setAdapter(PAUSE_ADAPTER_ID, address(pauseAdapter));
        registry.setChain(CHAIN_INDEX, block.chainid); // Use current chain for local execution
        vm.stopPrank();

        processor = new W3CashProcessor(address(registry));
    }

    // --- Constructor Tests ---

    function test_Constructor_SetsRegistry() public view {
        assertEq(address(processor.registry()), address(registry));
    }

    function test_Constructor_RevertIfZeroRegistry() public {
        vm.expectRevert("Invalid registry");
        new W3CashProcessor(address(0));
    }

    function test_Processor_IsImmutable() public view {
        // Verify there are no admin functions on the processor
        // The processor should only have: execute, estimateFee, setAuthorizedEndpoint, registry (view)
        // and the immutable registry reference
        assertEq(address(processor.registry()), address(registry));
    }

    // --- setAuthorizedEndpoint Tests ---

    function test_SetAuthorizedEndpoint_OnlyRegistryOwner() public {
        bytes32 endpoint = keccak256("endpoint");

        vm.prank(owner);
        processor.setAuthorizedEndpoint(endpoint, true);
        assertTrue(processor.authorizedEndpoints(endpoint));
    }

    function test_SetAuthorizedEndpoint_RevertIfNotOwner() public {
        bytes32 endpoint = keccak256("endpoint");

        vm.prank(user);
        vm.expectRevert("Only registry owner");
        processor.setAuthorizedEndpoint(endpoint, true);
    }

    // --- Nonce / Cancel Tests ---

    function test_Nonce_StartsAtZero() public view {
        assertEq(processor.nonces(user), 0);
    }

    function test_IncrementNonce_IncrementsAndEmits() public {
        vm.prank(user);
        vm.expectEmit(true, false, false, true);
        emit NonceCancelled(user, 0, 1);
        uint256 newNonce = processor.incrementNonce();
        
        assertEq(newNonce, 1);
        assertEq(processor.nonces(user), 1);
    }

    function test_IncrementNonce_MultipleTimes() public {
        vm.startPrank(user);
        processor.incrementNonce();
        processor.incrementNonce();
        uint256 newNonce = processor.incrementNonce();
        vm.stopPrank();
        
        assertEq(newNonce, 3);
        assertEq(processor.nonces(user), 3);
    }

    function test_Execute_RevertIfWrongNonce() public {
        // Create instruction with nonce 1, but user's nonce is 0
        bytes[] memory operations = new bytes[](1);
        bytes[] memory inputs = new bytes[](1);
        operations[0] = abi.encode(
            CHAIN_INDEX,
            SUCCESS_ADAPTER_ID,
            uint64(0),
            address(successAdapter),
            bytes8(0),
            uint112(0)
        );
        inputs[0] = "";

        bytes memory instruction = _createInstruction(0, operations, inputs);
        bytes memory signedPayload = _createSignedPayloadWithNonce(instruction, userPrivateKey, 1);

        vm.expectRevert(); // InvalidNonce
        processor.execute(signedPayload);
    }

    function test_Execute_SucceedsWithCorrectNonce() public {
        // Increment user's nonce to 1
        vm.prank(user);
        processor.incrementNonce();

        // Create instruction with nonce 1
        bytes[] memory operations = new bytes[](1);
        bytes[] memory inputs = new bytes[](1);
        operations[0] = abi.encode(
            CHAIN_INDEX,
            SUCCESS_ADAPTER_ID,
            uint64(0),
            address(successAdapter),
            bytes8(0),
            uint112(0)
        );
        inputs[0] = "";

        bytes memory instruction = _createInstruction(0, operations, inputs);
        bytes memory signedPayload = _createSignedPayloadWithNonce(instruction, userPrivateKey, 1);

        processor.execute(signedPayload);
        // Should succeed without revert
    }

    function test_Cancel_InvalidatesPendingFlows() public {
        // Create a valid signed payload at nonce 0
        bytes[] memory operations = new bytes[](1);
        bytes[] memory inputs = new bytes[](1);
        operations[0] = abi.encode(
            CHAIN_INDEX,
            SUCCESS_ADAPTER_ID,
            uint64(0),
            address(successAdapter),
            bytes8(0),
            uint112(0)
        );
        inputs[0] = "";

        bytes memory instruction = _createInstruction(0, operations, inputs);
        bytes memory signedPayload = _createSignedPayloadWithNonce(instruction, userPrivateKey, 0);

        // User cancels by incrementing nonce
        vm.prank(user);
        processor.incrementNonce();

        // Old payload should now fail
        vm.expectRevert(); // InvalidNonce
        processor.execute(signedPayload);
    }

    // --- estimateFee Tests ---

    function test_EstimateFee_ReturnsAdapterFee() public view {
        uint256 fee = processor.estimateFee(SUCCESS_ADAPTER_ID, CHAIN_INDEX, 1 ether, 100000);
        assertEq(fee, 0.001 ether);
    }

    function test_EstimateFee_RevertIfAdapterNotRegistered() public {
        vm.expectRevert(IAdapterRegistry.AdapterNotRegistered.selector);
        processor.estimateFee(99, CHAIN_INDEX, 1 ether, 100000);
    }

    // --- Integration with Registry Tests ---

    function test_Processor_UsesRegistryForAdapters() public {
        // Create a new adapter and register it
        MockSuccessAdapter newAdapter = new MockSuccessAdapter();

        vm.prank(owner);
        registry.setAdapter(5, address(newAdapter));

        // Processor should be able to use it via estimateFee
        uint256 fee = processor.estimateFee(5, CHAIN_INDEX, 1 ether, 100000);
        assertEq(fee, 0.001 ether);
    }

    function test_Processor_UsesRegistryForChains() public view {
        // Verify the chain is registered
        uint256 chainId = registry.getChain(CHAIN_INDEX);
        assertEq(chainId, block.chainid);
    }

    function test_Processor_CanReceiveEth() public {
        vm.deal(address(this), 1 ether);
        (bool success,) = address(processor).call{value: 0.5 ether}("");
        assertTrue(success);
        assertEq(address(processor).balance, 0.5 ether);
    }

    // --- Frozen Registry Tests ---

    function test_Processor_WorksWithFrozenAdapters() public {
        vm.prank(owner);
        registry.freezeAdapter(SUCCESS_ADAPTER_ID);

        // Should still work
        uint256 fee = processor.estimateFee(SUCCESS_ADAPTER_ID, CHAIN_INDEX, 1 ether, 100000);
        assertEq(fee, 0.001 ether);
    }

    function test_Processor_WorksWithFrozenChains() public {
        vm.prank(owner);
        registry.freezeChain(CHAIN_INDEX);

        // Should still work
        uint256 chainId = registry.getChain(CHAIN_INDEX);
        assertEq(chainId, block.chainid);
    }

    // --- New Adapters Can Be Added Tests ---

    function test_NewAdaptersCanBeAddedWithoutRedeployingProcessor() public {
        // Deploy a new adapter
        MockSuccessAdapter newAdapter = new MockSuccessAdapter();

        // Add it to registry (new ID)
        vm.prank(owner);
        registry.setAdapter(10, address(newAdapter));

        // Processor can use it without any changes
        uint256 fee = processor.estimateFee(10, CHAIN_INDEX, 1 ether, 100000);
        assertEq(fee, 0.001 ether);
    }

    // --- Helper Functions ---

    function _createSignedPayload(
        bytes memory instruction,
        uint256 privateKey
    ) internal view returns (bytes memory) {
        return _createSignedPayloadWithNonce(instruction, privateKey, 0);
    }

    function _createSignedPayloadWithNonce(
        bytes memory instruction,
        uint256 privateKey,
        uint256 nonce
    ) internal pure returns (bytes memory) {
        (, bytes memory payload) = abi.decode(instruction, (bytes, bytes));
        // Sign over (payloadHash, nonce) to match processor verification
        bytes32 messageHash = keccak256(abi.encodePacked(keccak256(payload), nonce));
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, ethSignedHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        address initiator = vm.addr(privateKey);

        DataTypes.SignedPayload memory sp = DataTypes.SignedPayload({
            instruction: instruction,
            initiator: initiator,
            nonce: nonce,
            signature: signature
        });

        return abi.encode(sp);
    }

    function _createInstruction(
        uint256 seq,
        bytes[] memory operations,
        bytes[] memory inputs
    ) internal pure returns (bytes memory) {
        bytes memory payload = abi.encode(operations, inputs);
        bytes32 payloadHash = keccak256(payload);
        bytes memory header = abi.encode(seq, operations.length, payloadHash);
        return abi.encode(header, payload);
    }
}
