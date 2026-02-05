// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { DataTypes } from "../utils/DataTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title BalanceAdapter
/// @notice Simplified condition adapter for checking token balances
/// @dev Wrapper around common balance checks - easier to use than QueryAdapter
contract BalanceAdapter is IAdapter {

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error BalanceAdapter__CallerNotProcessor();
    error BalanceAdapter__InvalidOperator();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("BalanceAdapter"));

    // Operators
    uint8 public constant OP_LT = 0;   // <
    uint8 public constant OP_GT = 1;   // >
    uint8 public constant OP_LTE = 2;  // <=
    uint8 public constant OP_GTE = 3;  // >=
    uint8 public constant OP_EQ = 4;   // ==
    uint8 public constant OP_NEQ = 5;  // !=

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The authorized Processor contract
    address public immutable processor;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyProcessor() {
        if (msg.sender != processor) revert BalanceAdapter__CallerNotProcessor();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _processor The authorized Processor address
    constructor(address _processor) {
        processor = _processor;
    }

    /*//////////////////////////////////////////////////////////////
                           ADAPTER INTERFACE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAdapter
    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    /// @notice Check if a balance condition is met
    /// @param account The account to check (can be overridden in data)
    /// @param data ABI encoded (address token, address target, uint8 operator, uint256 threshold)
    ///        token: ERC20 token address (address(0) for native ETH)
    ///        target: Address to check balance of
    ///        operator: Comparison operator (0-5)
    ///        threshold: Value to compare against
    /// @return PAUSE_EXECUTION if condition not met, empty bytes if met
    function execute(
        address account,
        bytes calldata data
    ) external payable override onlyProcessor returns (bytes memory) {
        (
            address token,
            address target,
            uint8 operator,
            uint256 threshold
        ) = abi.decode(data, (address, address, uint8, uint256));

        // Get balance
        uint256 balance;
        if (token == address(0)) {
            // Native ETH balance
            balance = target.balance;
        } else {
            // ERC20 balance
            balance = IERC20(token).balanceOf(target);
        }

        // Check condition
        bool conditionMet = _compare(balance, operator, threshold);

        if (!conditionMet) {
            return abi.encode(DataTypes.PAUSE_EXECUTION);
        }

        return "";
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _compare(uint256 actual, uint8 operator, uint256 expected) internal pure returns (bool) {
        if (operator == OP_LT) return actual < expected;
        if (operator == OP_GT) return actual > expected;
        if (operator == OP_LTE) return actual <= expected;
        if (operator == OP_GTE) return actual >= expected;
        if (operator == OP_EQ) return actual == expected;
        if (operator == OP_NEQ) return actual != expected;
        revert BalanceAdapter__InvalidOperator();
    }

    /// @inheritdoc IAdapter
    function send(bytes memory, uint8, uint64, uint112) external payable override returns (uint64) {
        return 0;
    }

    /// @inheritdoc IAdapter
    function estimateFee(uint8, uint112, uint256) external pure override returns (uint256) {
        return 0;
    }
}
