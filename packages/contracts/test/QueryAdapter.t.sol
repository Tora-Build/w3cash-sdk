// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { QueryAdapter } from "../src/w3cash/adapters/QueryAdapter.sol";
import { DataTypes } from "../src/w3cash/utils/DataTypes.sol";

/// @dev Mock contract with various view functions for testing
contract MockQueryTarget {
    uint256 public value = 100;
    mapping(address => uint256) public balances;

    function setValue(uint256 _value) external {
        value = _value;
    }

    function setBalance(address account, uint256 amount) external {
        balances[account] = amount;
    }

    function getValue() external view returns (uint256) {
        return value;
    }

    function getBalance(address account) external view returns (uint256) {
        return balances[account];
    }

    function alwaysReverts() external pure returns (uint256) {
        revert("intentional revert");
    }
}

contract QueryAdapterTest is Test {
    QueryAdapter public adapter;
    MockQueryTarget public target;
    
    address public processor = address(0x1);
    address public user = address(0x2);

    function setUp() public {
        adapter = new QueryAdapter(processor);
        target = new MockQueryTarget();
    }

    // --- Constructor Tests ---

    function test_Constructor_SetsProcessor() public view {
        assertEq(adapter.processor(), processor);
    }

    function test_AdapterId() public view {
        assertEq(adapter.adapterId(), bytes4(keccak256("QueryAdapter")));
    }

    // --- Access Control Tests ---

    function test_Execute_RevertIfNotProcessor() public {
        bytes memory input = _encodeQuery(
            address(target),
            abi.encodeWithSelector(target.getValue.selector),
            adapter.OP_GTE(),
            50
        );

        vm.prank(user);
        vm.expectRevert(QueryAdapter.OnlyProcessor.selector);
        adapter.execute(user, input);
    }

    // --- Operator Tests ---

    function test_Query_LessThan_ConditionMet() public {
        target.setValue(50);
        
        bytes memory input = _encodeQuery(
            address(target),
            abi.encodeWithSelector(target.getValue.selector),
            adapter.OP_LT(),
            100 // 50 < 100 = true
        );

        vm.prank(processor);
        bytes memory result = adapter.execute(user, input);
        assertEq(result.length, 0); // Condition met = empty return
    }

    function test_Query_LessThan_ConditionNotMet() public {
        target.setValue(150);
        
        bytes memory input = _encodeQuery(
            address(target),
            abi.encodeWithSelector(target.getValue.selector),
            adapter.OP_LT(),
            100 // 150 < 100 = false
        );

        vm.prank(processor);
        bytes memory result = adapter.execute(user, input);
        assertEq(keccak256(result), keccak256(abi.encode(DataTypes.PAUSE_EXECUTION)));
    }

    function test_Query_GreaterThan_ConditionMet() public {
        target.setValue(150);
        
        bytes memory input = _encodeQuery(
            address(target),
            abi.encodeWithSelector(target.getValue.selector),
            adapter.OP_GT(),
            100 // 150 > 100 = true
        );

        vm.prank(processor);
        bytes memory result = adapter.execute(user, input);
        assertEq(result.length, 0);
    }

    function test_Query_GreaterThan_ConditionNotMet() public {
        target.setValue(50);
        
        bytes memory input = _encodeQuery(
            address(target),
            abi.encodeWithSelector(target.getValue.selector),
            adapter.OP_GT(),
            100 // 50 > 100 = false
        );

        vm.prank(processor);
        bytes memory result = adapter.execute(user, input);
        assertEq(keccak256(result), keccak256(abi.encode(DataTypes.PAUSE_EXECUTION)));
    }

    function test_Query_LessThanOrEqual_ConditionMet() public {
        target.setValue(100);
        
        bytes memory input = _encodeQuery(
            address(target),
            abi.encodeWithSelector(target.getValue.selector),
            adapter.OP_LTE(),
            100 // 100 <= 100 = true
        );

        vm.prank(processor);
        bytes memory result = adapter.execute(user, input);
        assertEq(result.length, 0);
    }

    function test_Query_GreaterThanOrEqual_ConditionMet() public {
        target.setValue(100);
        
        bytes memory input = _encodeQuery(
            address(target),
            abi.encodeWithSelector(target.getValue.selector),
            adapter.OP_GTE(),
            100 // 100 >= 100 = true
        );

        vm.prank(processor);
        bytes memory result = adapter.execute(user, input);
        assertEq(result.length, 0);
    }

    function test_Query_Equal_ConditionMet() public {
        target.setValue(100);
        
        bytes memory input = _encodeQuery(
            address(target),
            abi.encodeWithSelector(target.getValue.selector),
            adapter.OP_EQ(),
            100 // 100 == 100 = true
        );

        vm.prank(processor);
        bytes memory result = adapter.execute(user, input);
        assertEq(result.length, 0);
    }

    function test_Query_Equal_ConditionNotMet() public {
        target.setValue(99);
        
        bytes memory input = _encodeQuery(
            address(target),
            abi.encodeWithSelector(target.getValue.selector),
            adapter.OP_EQ(),
            100 // 99 == 100 = false
        );

        vm.prank(processor);
        bytes memory result = adapter.execute(user, input);
        assertEq(keccak256(result), keccak256(abi.encode(DataTypes.PAUSE_EXECUTION)));
    }

    function test_Query_NotEqual_ConditionMet() public {
        target.setValue(99);
        
        bytes memory input = _encodeQuery(
            address(target),
            abi.encodeWithSelector(target.getValue.selector),
            adapter.OP_NEQ(),
            100 // 99 != 100 = true
        );

        vm.prank(processor);
        bytes memory result = adapter.execute(user, input);
        assertEq(result.length, 0);
    }

    function test_Query_NotEqual_ConditionNotMet() public {
        target.setValue(100);
        
        bytes memory input = _encodeQuery(
            address(target),
            abi.encodeWithSelector(target.getValue.selector),
            adapter.OP_NEQ(),
            100 // 100 != 100 = false
        );

        vm.prank(processor);
        bytes memory result = adapter.execute(user, input);
        assertEq(keccak256(result), keccak256(abi.encode(DataTypes.PAUSE_EXECUTION)));
    }

    function test_Query_InvalidOperator() public {
        bytes memory input = _encodeQuery(
            address(target),
            abi.encodeWithSelector(target.getValue.selector),
            99, // Invalid operator
            100
        );

        vm.prank(processor);
        vm.expectRevert(QueryAdapter.InvalidOperator.selector);
        adapter.execute(user, input);
    }

    // --- Query with Arguments Tests ---

    function test_Query_WithArguments() public {
        address testAccount = address(0x123);
        target.setBalance(testAccount, 500);

        bytes memory input = _encodeQuery(
            address(target),
            abi.encodeWithSelector(target.getBalance.selector, testAccount),
            adapter.OP_GTE(),
            400 // 500 >= 400 = true
        );

        vm.prank(processor);
        bytes memory result = adapter.execute(user, input);
        assertEq(result.length, 0);
    }

    // --- Error Cases ---

    function test_Query_RevertIfCallFails() public {
        bytes memory input = _encodeQuery(
            address(target),
            abi.encodeWithSelector(target.alwaysReverts.selector),
            adapter.OP_EQ(),
            100
        );

        vm.prank(processor);
        vm.expectRevert(QueryAdapter.QueryFailed.selector);
        adapter.execute(user, input);
    }

    // --- Helper Functions ---

    function _encodeQuery(
        address _target,
        bytes memory data,
        uint8 operator,
        uint256 expected
    ) internal pure returns (bytes memory) {
        return abi.encode(_target, data, operator, expected);
    }
}
