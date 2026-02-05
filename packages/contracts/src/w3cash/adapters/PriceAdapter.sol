// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { DataTypes } from "../utils/DataTypes.sol";

/// @title AggregatorV3Interface
/// @notice Chainlink price feed interface
interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
    
    function decimals() external view returns (uint8);
}

/// @title PriceAdapter
/// @notice Simplified condition adapter for checking Chainlink prices
/// @dev Wrapper around Chainlink oracle checks - easier to use than QueryAdapter
contract PriceAdapter is IAdapter {

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error PriceAdapter__CallerNotProcessor();
    error PriceAdapter__InvalidOperator();
    error PriceAdapter__StalePrice();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("PriceAdapter"));

    // Operators
    uint8 public constant OP_LT = 0;   // <
    uint8 public constant OP_GT = 1;   // >
    uint8 public constant OP_LTE = 2;  // <=
    uint8 public constant OP_GTE = 3;  // >=
    uint8 public constant OP_EQ = 4;   // ==
    uint8 public constant OP_NEQ = 5;  // !=

    /// @notice Maximum staleness for price data (1 hour)
    uint256 public constant MAX_STALENESS = 3600;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The authorized Processor contract
    address public immutable processor;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyProcessor() {
        if (msg.sender != processor) revert PriceAdapter__CallerNotProcessor();
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

    /// @notice Check if a price condition is met
    /// @param account The account (unused for price checks)
    /// @param data ABI encoded (address feed, uint8 operator, int256 targetPrice, bool checkStaleness)
    ///        feed: Chainlink price feed address
    ///        operator: Comparison operator (0-5)
    ///        targetPrice: Price to compare against (in feed decimals, usually 8)
    ///        checkStaleness: If true, revert on stale prices
    /// @return PAUSE_EXECUTION if condition not met, empty bytes if met
    function execute(
        address account,
        bytes calldata data
    ) external payable override onlyProcessor returns (bytes memory) {
        (
            address feed,
            uint8 operator,
            int256 targetPrice,
            bool checkStaleness
        ) = abi.decode(data, (address, uint8, int256, bool));

        // Get price from Chainlink
        (
            ,
            int256 price,
            ,
            uint256 updatedAt,
        ) = AggregatorV3Interface(feed).latestRoundData();

        // Check staleness if required
        if (checkStaleness && block.timestamp - updatedAt > MAX_STALENESS) {
            revert PriceAdapter__StalePrice();
        }

        // Check condition
        bool conditionMet = _compare(price, operator, targetPrice);

        if (!conditionMet) {
            return abi.encode(DataTypes.PAUSE_EXECUTION);
        }

        return "";
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _compare(int256 actual, uint8 operator, int256 expected) internal pure returns (bool) {
        if (operator == OP_LT) return actual < expected;
        if (operator == OP_GT) return actual > expected;
        if (operator == OP_LTE) return actual <= expected;
        if (operator == OP_GTE) return actual >= expected;
        if (operator == OP_EQ) return actual == expected;
        if (operator == OP_NEQ) return actual != expected;
        revert PriceAdapter__InvalidOperator();
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get current price from a feed
    function getPrice(address feed) external view returns (int256 price, uint256 updatedAt) {
        (, price, , updatedAt,) = AggregatorV3Interface(feed).latestRoundData();
    }

    /// @notice Check if price is stale
    function isStale(address feed) external view returns (bool) {
        (, , , uint256 updatedAt,) = AggregatorV3Interface(feed).latestRoundData();
        return block.timestamp - updatedAt > MAX_STALENESS;
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
