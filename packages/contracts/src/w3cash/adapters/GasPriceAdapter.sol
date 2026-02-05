// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { DataTypes } from "../utils/DataTypes.sol";

/// @title GasPriceAdapter
/// @notice Condition adapter for checking gas price
/// @dev Execute actions only when gas is cheap
contract GasPriceAdapter is IAdapter {

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error GasPriceAdapter__CallerNotProcessor();
    error GasPriceAdapter__InvalidOperator();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("GasPriceAdapter"));

    // Operators
    uint8 public constant OP_LT = 0;   // <
    uint8 public constant OP_GT = 1;   // >
    uint8 public constant OP_LTE = 2;  // <=
    uint8 public constant OP_GTE = 3;  // >=

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The authorized Processor contract
    address public immutable processor;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyProcessor() {
        if (msg.sender != processor) revert GasPriceAdapter__CallerNotProcessor();
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

    /// @notice Check if gas price condition is met
    /// @param account The account (unused)
    /// @param data ABI encoded (uint8 operator, uint256 threshold)
    ///        operator: Comparison operator (0-3)
    ///        threshold: Gas price threshold in wei
    /// @return PAUSE_EXECUTION if condition not met, empty bytes if met
    function execute(
        address account,
        bytes calldata data
    ) external payable override onlyProcessor returns (bytes memory) {
        (uint8 operator, uint256 threshold) = abi.decode(data, (uint8, uint256));

        uint256 currentGasPrice = tx.gasprice;

        bool conditionMet = _compare(currentGasPrice, operator, threshold);

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
        revert GasPriceAdapter__InvalidOperator();
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get current gas price
    function getCurrentGasPrice() external view returns (uint256) {
        return tx.gasprice;
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
