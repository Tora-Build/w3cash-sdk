// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/core/W3CashCore.sol";
import "../src/core/IFlow.sol";

/// @dev Mock flow for testing
contract MockFlow is IFlow {
    bytes4 public constant FLOW_ID = 0x12345678;
    bytes4 public constant ACTION_ECHO = 0xaabbccdd;
    
    function execute(address caller, bytes calldata data) external payable override returns (bytes memory) {
        bytes4 action = bytes4(data[:4]);
        if (action == ACTION_ECHO) {
            // Echo back the caller and remaining data
            return abi.encode(caller, data[4:]);
        }
        revert("unsupported action");
    }
    
    function flowId() external pure override returns (bytes4) {
        return FLOW_ID;
    }
    
    function supportsAction(bytes4 action) external view override returns (bool) {
        return action == ACTION_ECHO;
    }
    
    function metadata() external pure override returns (string memory, string memory) {
        return ("MockFlow", "1.0.0");
    }
}

contract W3CashCoreTest is Test {
    W3CashCore public core;
    MockFlow public mockFlow;
    
    bytes4 constant ACTION_ECHO = 0xaabbccdd;
    
    function setUp() public {
        core = new W3CashCore();
        mockFlow = new MockFlow();
    }
    
    function test_Execute() public {
        bytes memory data = abi.encodePacked(ACTION_ECHO, "hello");
        
        bytes memory result = core.execute(address(mockFlow), data);
        
        (address caller, bytes memory echoData) = abi.decode(result, (address, bytes));
        assertEq(caller, address(this));
        assertEq(string(echoData), "hello");
    }
    
    function test_ExecuteBatch() public {
        address[] memory flows = new address[](2);
        flows[0] = address(mockFlow);
        flows[1] = address(mockFlow);
        
        bytes[] memory datas = new bytes[](2);
        datas[0] = abi.encodePacked(ACTION_ECHO, "first");
        datas[1] = abi.encodePacked(ACTION_ECHO, "second");
        
        bytes[] memory results = core.executeBatch(flows, datas);
        
        assertEq(results.length, 2);
        
        (, bytes memory echo1) = abi.decode(results[0], (address, bytes));
        (, bytes memory echo2) = abi.decode(results[1], (address, bytes));
        
        assertEq(string(echo1), "first");
        assertEq(string(echo2), "second");
    }
    
    function test_ExecuteBatch_LengthMismatch() public {
        address[] memory flows = new address[](2);
        bytes[] memory datas = new bytes[](1);
        
        vm.expectRevert("length mismatch");
        core.executeBatch(flows, datas);
    }
    
    function test_FlowMetadata() public view {
        (string memory name, string memory version) = mockFlow.metadata();
        assertEq(name, "MockFlow");
        assertEq(version, "1.0.0");
    }
    
    function test_FlowSupportsAction() public view {
        assertTrue(mockFlow.supportsAction(ACTION_ECHO));
        assertFalse(mockFlow.supportsAction(bytes4(0xdeadbeef)));
    }
}
