// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { DataTypes } from "../utils/DataTypes.sol";

/**
 * @title WaitAdapter
 * @notice POCA adapter for time-based and price-based conditions
 * @dev Returns PAUSE_EXECUTION when conditions aren't met, allowing resumption later
 * 
 * Condition Types:
 * - TIMESTAMP: Wait until a specific timestamp
 * - BLOCK: Wait until a specific block number
 * - PRICE_GTE: Wait until price >= target (via Chainlink)
 * - PRICE_LTE: Wait until price <= target (via Chainlink)
 */
contract WaitAdapter is IAdapter {
    // --- Types ---
    enum WaitType {
        TIMESTAMP,
        BLOCK,
        PRICE_GTE,
        PRICE_LTE
    }

    struct WaitParams {
        WaitType condition;
        uint256 value;       // For TIMESTAMP/BLOCK
        address feed;        // For PRICE conditions (Chainlink feed)
        int256 targetPrice;  // For PRICE conditions
    }

    // --- Constants ---
    bytes4 public constant ADAPTER_ID = bytes4(keccak256("WaitAdapter"));

    // --- IAdapter Implementation ---

    function execute(
        address, // initiator (unused)
        bytes calldata data
    ) external payable override returns (bytes memory) {
        WaitParams memory params = abi.decode(data, (WaitParams));

        bool conditionMet = false;

        if (params.condition == WaitType.TIMESTAMP) {
            conditionMet = block.timestamp >= params.value;
        } else if (params.condition == WaitType.BLOCK) {
            conditionMet = block.number >= params.value;
        } else if (params.condition == WaitType.PRICE_GTE) {
            int256 price = _getPrice(params.feed);
            conditionMet = price >= params.targetPrice;
        } else if (params.condition == WaitType.PRICE_LTE) {
            int256 price = _getPrice(params.feed);
            conditionMet = price <= params.targetPrice;
        }

        if (!conditionMet) {
            // Return PAUSE_EXECUTION - transaction succeeds but workflow pauses
            return abi.encode(DataTypes.PAUSE_EXECUTION);
        }

        // Condition met - return empty bytes to continue execution
        return "";
    }

    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    function send(bytes memory, uint8, uint64, uint112)
        external
        payable
        override
        returns (uint64)
    {
        revert("WaitAdapter: send not supported");
    }

    function estimateFee(uint8, uint112, uint256)
        external
        pure
        override
        returns (uint256)
    {
        return 0;
    }

    // --- Internal ---

    function _getPrice(address feed) internal view returns (int256) {
        (, int256 price,,,) = AggregatorV3Interface(feed).latestRoundData();
        return price;
    }
}

// --- Chainlink Interface ---
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
}
