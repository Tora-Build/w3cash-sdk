// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { PostConditionAdapter } from "../src/w3cash/adapters/PostConditionAdapter.sol";

contract MockView {
    uint256 public value;
    function set(uint256 v) external { value = v; }
    function getValue() external view returns (uint256) { return value; }
    function reverts() external pure returns (uint256) { revert("nope"); }
}

contract PostConditionAdapterTest is Test {
    PostConditionAdapter internal pc;
    MockView internal target;

    function setUp() public {
        pc = new PostConditionAdapter();
        target = new MockView();
    }

    function _data(uint8 op, uint256 expected) internal view returns (bytes memory) {
        return abi.encode(
            address(target),
            abi.encodeWithSelector(target.getValue.selector),
            op,
            expected
        );
    }

    function test_Declares_ActionKind_And_AssertVerb() public view {
        assertEq(pc.adapterKind(), 2);
        assertEq(pc.verb(), uint32(1 << 7));
    }

    function test_Passes_WhenConditionMet() public {
        target.set(150);
        // 150 >= 100 => passes, returns empty (no revert).
        bytes memory out = pc.run(address(0xBEEF), _data(pc.OP_GTE(), 100));
        assertEq(out.length, 0);
    }

    function test_Reverts_WhenConditionUnmet() public {
        target.set(50);
        uint8 gte = pc.OP_GTE();
        bytes memory data = _data(gte, 100);
        // 50 >= 100 => fails => hard revert (the whole intent unwinds).
        vm.expectRevert(
            abi.encodeWithSelector(PostConditionAdapter.PostConditionFailed.selector, uint256(50), gte, uint256(100))
        );
        pc.run(address(0xBEEF), data);
    }

    function test_Reverts_OnStaticcallFailure() public {
        bytes memory data = abi.encode(
            address(target),
            abi.encodeWithSelector(target.reverts.selector),
            pc.OP_GTE(),
            uint256(1)
        );
        vm.expectRevert(PostConditionAdapter.StaticcallFailed.selector);
        pc.run(address(0xBEEF), data);
    }

    function test_Reverts_OnInvalidOperator() public {
        target.set(10);
        vm.expectRevert(PostConditionAdapter.InvalidOperator.selector);
        pc.run(address(0xBEEF), _data(99, 1));
    }
}
