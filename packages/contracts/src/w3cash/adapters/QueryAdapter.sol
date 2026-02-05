// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { DataTypes } from "../utils/DataTypes.sol";

/**
 * @title QueryAdapter
 * @notice Generic condition adapter that reads any contract view function
 * @dev Uses staticcall to read on-chain state and compare against expected values
 * 
 * Supported operators: <, >, <=, >=, ==, !=
 * 
 * Example use cases:
 * - Wait until token balance >= threshold
 * - Wait until oracle price > target
 * - Wait until Aave APY changes
 * - Wait until governance proposal state == executed
 */
contract QueryAdapter is IAdapter {
    bytes4 public constant ADAPTER_ID = bytes4(keccak256("QueryAdapter"));

    /// @notice Processor address (only processor can call execute)
    address public immutable processor;

    // Operator constants
    uint8 public constant OP_LT = 0;   // <
    uint8 public constant OP_GT = 1;   // >
    uint8 public constant OP_LTE = 2;  // <=
    uint8 public constant OP_GTE = 3;  // >=
    uint8 public constant OP_EQ = 4;   // ==
    uint8 public constant OP_NEQ = 5;  // !=

    error OnlyProcessor();
    error InvalidOperator();
    error QueryFailed();

    constructor(address _processor) {
        processor = _processor;
    }

    /**
     * @notice Execute a query condition check
     * @param input ABI-encoded QueryParams
     * @return PAUSE_EXECUTION if condition not met, empty bytes if met
     */
    function execute(address, bytes calldata input) external payable override returns (bytes memory) {
        if (msg.sender != processor) revert OnlyProcessor();

        (
            address target,      // Contract to query
            bytes memory data,   // Encoded function call (selector + args)
            uint8 operator,      // Comparison operator
            uint256 expected     // Expected value to compare against
        ) = abi.decode(input, (address, bytes, uint8, uint256));

        // Execute staticcall to read state
        (bool success, bytes memory result) = target.staticcall(data);
        if (!success) revert QueryFailed();

        // Decode result as uint256 (works for most view functions)
        uint256 actual = abi.decode(result, (uint256));

        // Compare based on operator
        bool conditionMet = _compare(actual, operator, expected);

        if (!conditionMet) {
            return abi.encode(DataTypes.PAUSE_EXECUTION);
        }

        return "";
    }

    function _compare(uint256 actual, uint8 operator, uint256 expected) internal pure returns (bool) {
        if (operator == OP_LT) return actual < expected;
        if (operator == OP_GT) return actual > expected;
        if (operator == OP_LTE) return actual <= expected;
        if (operator == OP_GTE) return actual >= expected;
        if (operator == OP_EQ) return actual == expected;
        if (operator == OP_NEQ) return actual != expected;
        revert InvalidOperator();
    }

    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    // Not used for condition adapters
    function send(bytes memory, uint8, uint64, uint112) external payable override returns (uint64) {
        return 0;
    }

    function estimateFee(uint8, uint112, uint256) external pure override returns (uint256) {
        return 0;
    }
}
