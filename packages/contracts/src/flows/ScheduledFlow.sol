// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IFlow } from "../core/IFlow.sol";
import { DataTypes } from "../poca/utils/DataTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

/**
 * @title ScheduledFlow
 * @notice Flow that enables time-based and conditional execution powered by POCA
 * @dev Uses PAUSE_EXECUTION pattern for resumable workflows
 * 
 * Example use cases:
 * - DCA: Schedule recurring deposits/swaps
 * - Limit Orders: Execute swap when price condition met
 * - Vesting: Release tokens on schedule
 */
contract ScheduledFlow is IFlow {
    // --- Constants ---
    bytes4 public constant FLOW_ID = bytes4(keccak256("ScheduledFlow"));
    
    // Actions
    bytes4 public constant ACTION_SCHEDULE = bytes4(keccak256("schedule"));
    bytes4 public constant ACTION_EXECUTE = bytes4(keccak256("execute"));
    bytes4 public constant ACTION_CANCEL = bytes4(keccak256("cancel"));
    bytes4 public constant ACTION_STATUS = bytes4(keccak256("status"));

    // --- Types ---
    enum ConditionType {
        TIMESTAMP,      // Execute after timestamp
        BLOCK,          // Execute after block number
        PRICE_GTE,      // Execute when price >= target
        PRICE_LTE       // Execute when price <= target
    }

    struct ScheduledTask {
        address owner;
        address targetFlow;
        bytes4 targetAction;
        bytes targetParams;
        ConditionType conditionType;
        uint256 conditionValue;
        address priceFeed;       // For price conditions
        int256 targetPrice;      // For price conditions
        bool executed;
        bool cancelled;
        uint256 createdAt;
    }

    // --- Storage ---
    mapping(bytes32 => ScheduledTask) public tasks;
    uint256 public taskCount;

    // --- Events ---
    event TaskScheduled(
        bytes32 indexed taskId,
        address indexed owner,
        address targetFlow,
        ConditionType conditionType,
        uint256 conditionValue
    );
    event TaskExecuted(bytes32 indexed taskId, address indexed executor);
    event TaskCancelled(bytes32 indexed taskId);
    event TaskPaused(bytes32 indexed taskId, string reason);

    // --- IFlow Implementation ---
    
    function execute(
        address caller,
        bytes calldata data
    ) external payable override returns (bytes memory) {
        bytes4 action = bytes4(data[:4]);
        bytes calldata params = data[4:];

        if (action == ACTION_SCHEDULE) {
            return _schedule(caller, params);
        } else if (action == ACTION_EXECUTE) {
            return _executeTask(caller, params);
        } else if (action == ACTION_CANCEL) {
            return _cancel(caller, params);
        } else if (action == ACTION_STATUS) {
            return _status(params);
        }
        
        revert("ScheduledFlow: unsupported action");
    }

    function flowId() external pure override returns (bytes4) {
        return FLOW_ID;
    }

    function supportsAction(bytes4 action) external pure override returns (bool) {
        return action == ACTION_SCHEDULE ||
               action == ACTION_EXECUTE ||
               action == ACTION_CANCEL ||
               action == ACTION_STATUS;
    }

    function metadata() external pure override returns (string memory name, string memory version) {
        return ("ScheduledFlow", "1.0.0");
    }

    // --- Internal Functions ---

    function _schedule(
        address caller,
        bytes calldata params
    ) internal returns (bytes memory) {
        (
            address targetFlow,
            bytes4 targetAction,
            bytes memory targetParams,
            ConditionType conditionType,
            uint256 conditionValue,
            address priceFeed,
            int256 targetPrice
        ) = abi.decode(params, (address, bytes4, bytes, ConditionType, uint256, address, int256));

        bytes32 taskId = keccak256(abi.encodePacked(
            caller,
            targetFlow,
            targetAction,
            targetParams,
            block.timestamp,
            taskCount++
        ));

        tasks[taskId] = ScheduledTask({
            owner: caller,
            targetFlow: targetFlow,
            targetAction: targetAction,
            targetParams: targetParams,
            conditionType: conditionType,
            conditionValue: conditionValue,
            priceFeed: priceFeed,
            targetPrice: targetPrice,
            executed: false,
            cancelled: false,
            createdAt: block.timestamp
        });

        emit TaskScheduled(taskId, caller, targetFlow, conditionType, conditionValue);

        return abi.encode(taskId);
    }

    function _executeTask(
        address, // executor (anyone can trigger)
        bytes calldata params
    ) internal returns (bytes memory) {
        bytes32 taskId = abi.decode(params, (bytes32));
        ScheduledTask storage task = tasks[taskId];

        require(task.owner != address(0), "ScheduledFlow: task not found");
        require(!task.executed, "ScheduledFlow: already executed");
        require(!task.cancelled, "ScheduledFlow: task cancelled");

        // Check condition - return PAUSE_EXECUTION if not met
        if (!_checkCondition(task)) {
            emit TaskPaused(taskId, "condition not met");
            return abi.encode(DataTypes.PAUSE_EXECUTION);
        }

        // Execute the target flow
        task.executed = true;
        
        bytes memory callData = abi.encodePacked(task.targetAction, task.targetParams);
        bytes memory result = IFlow(task.targetFlow).execute(task.owner, callData);

        emit TaskExecuted(taskId, msg.sender);

        return result;
    }

    function _cancel(
        address caller,
        bytes calldata params
    ) internal returns (bytes memory) {
        bytes32 taskId = abi.decode(params, (bytes32));
        ScheduledTask storage task = tasks[taskId];

        require(task.owner == caller, "ScheduledFlow: not owner");
        require(!task.executed, "ScheduledFlow: already executed");
        require(!task.cancelled, "ScheduledFlow: already cancelled");

        task.cancelled = true;

        emit TaskCancelled(taskId);

        return abi.encode(true);
    }

    function _status(bytes calldata params) internal view returns (bytes memory) {
        bytes32 taskId = abi.decode(params, (bytes32));
        ScheduledTask storage task = tasks[taskId];

        bool conditionMet = _checkCondition(task);

        return abi.encode(
            task.owner,
            task.executed,
            task.cancelled,
            conditionMet,
            task.createdAt
        );
    }

    function _checkCondition(ScheduledTask storage task) internal view returns (bool) {
        if (task.conditionType == ConditionType.TIMESTAMP) {
            return block.timestamp >= task.conditionValue;
        } else if (task.conditionType == ConditionType.BLOCK) {
            return block.number >= task.conditionValue;
        } else if (task.conditionType == ConditionType.PRICE_GTE) {
            return _getPrice(task.priceFeed) >= task.targetPrice;
        } else if (task.conditionType == ConditionType.PRICE_LTE) {
            return _getPrice(task.priceFeed) <= task.targetPrice;
        }
        return false;
    }

    function _getPrice(address feed) internal view returns (int256) {
        // Chainlink AggregatorV3Interface
        (, int256 price,,,) = AggregatorV3Interface(feed).latestRoundData();
        return price;
    }
}

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
