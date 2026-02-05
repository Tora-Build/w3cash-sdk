// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { DataTypes } from "../utils/DataTypes.sol";

/// @title TimeRangeAdapter
/// @notice Condition adapter for checking if current time is within a range
/// @dev Useful for executing only during business hours, market hours, etc.
contract TimeRangeAdapter is IAdapter {

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error TimeRangeAdapter__CallerNotProcessor();
    error TimeRangeAdapter__InvalidRange();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("TimeRangeAdapter"));

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The authorized Processor contract
    address public immutable processor;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyProcessor() {
        if (msg.sender != processor) revert TimeRangeAdapter__CallerNotProcessor();
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

    /// @notice Check if current time is within a range
    /// @param account The account (unused)
    /// @param data ABI encoded (uint256 startTime, uint256 endTime, bool recurring)
    ///        startTime: Start of time window (timestamp or hour of day if recurring)
    ///        endTime: End of time window (timestamp or hour of day if recurring)
    ///        recurring: If true, startTime/endTime are hours (0-23) and repeat daily
    /// @return PAUSE_EXECUTION if outside time range, empty bytes if within
    function execute(
        address account,
        bytes calldata data
    ) external payable override onlyProcessor returns (bytes memory) {
        (
            uint256 startTime,
            uint256 endTime,
            bool recurring
        ) = abi.decode(data, (uint256, uint256, bool));

        bool inRange;

        if (recurring) {
            // Recurring daily check (startTime and endTime are hours 0-23)
            uint256 currentHour = (block.timestamp % 86400) / 3600; // UTC hour
            
            if (startTime <= endTime) {
                // Normal range (e.g., 9 to 17)
                inRange = currentHour >= startTime && currentHour < endTime;
            } else {
                // Overnight range (e.g., 22 to 6)
                inRange = currentHour >= startTime || currentHour < endTime;
            }
        } else {
            // One-time range check
            inRange = block.timestamp >= startTime && block.timestamp <= endTime;
        }

        if (!inRange) {
            return abi.encode(DataTypes.PAUSE_EXECUTION);
        }

        return "";
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get current UTC hour
    function getCurrentHour() external view returns (uint256) {
        return (block.timestamp % 86400) / 3600;
    }

    /// @notice Check if within a recurring daily time range
    function isWithinDailyRange(uint256 startHour, uint256 endHour) external view returns (bool) {
        uint256 currentHour = (block.timestamp % 86400) / 3600;
        
        if (startHour <= endHour) {
            return currentHour >= startHour && currentHour < endHour;
        } else {
            return currentHour >= startHour || currentHour < endHour;
        }
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
