// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IFlow } from "../core/IFlow.sol";
import { DataTypes } from "../poca/utils/DataTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title DCAFlow
 * @notice Dollar-Cost Averaging flow powered by POCA's resumable execution
 * @dev Enables recurring purchases that pause and resume on schedule
 * 
 * Example: Buy $100 of ETH every week for 10 weeks
 * - User deposits $1000 USDC
 * - Every 7 days, $100 is swapped to ETH
 * - Uses PAUSE_EXECUTION to wait between purchases
 */
contract DCAFlow is IFlow {
    using SafeERC20 for IERC20;

    // --- Constants ---
    bytes4 public constant FLOW_ID = bytes4(keccak256("DCAFlow"));
    
    bytes4 public constant ACTION_CREATE = bytes4(keccak256("create"));
    bytes4 public constant ACTION_EXECUTE = bytes4(keccak256("execute"));
    bytes4 public constant ACTION_CANCEL = bytes4(keccak256("cancel"));
    bytes4 public constant ACTION_WITHDRAW = bytes4(keccak256("withdraw"));
    bytes4 public constant ACTION_STATUS = bytes4(keccak256("status"));

    // --- Types ---
    struct DCAPosition {
        address owner;
        address tokenIn;         // Token to spend (e.g., USDC)
        address tokenOut;        // Token to buy (e.g., WETH)
        uint256 amountPerPeriod; // Amount to swap each period
        uint256 intervalSeconds; // Time between swaps
        uint256 totalPeriods;    // Total number of swaps
        uint256 periodsExecuted; // Swaps completed
        uint256 nextExecuteTime; // When next swap can happen
        uint256 deposited;       // Total deposited
        uint256 spent;           // Total spent
        uint256 received;        // Total received
        bool active;
        address swapFlow;        // SwapFlow address to use
        uint24 poolFee;          // Uniswap pool fee
    }

    // --- Storage ---
    mapping(bytes32 => DCAPosition) public positions;
    uint256 public positionCount;

    // --- Events ---
    event DCACreated(
        bytes32 indexed positionId,
        address indexed owner,
        address tokenIn,
        address tokenOut,
        uint256 amountPerPeriod,
        uint256 intervalSeconds,
        uint256 totalPeriods
    );
    event DCAExecuted(bytes32 indexed positionId, uint256 period, uint256 amountIn, uint256 amountOut);
    event DCACancelled(bytes32 indexed positionId);
    event DCACompleted(bytes32 indexed positionId);
    event Withdrawn(bytes32 indexed positionId, address token, uint256 amount);

    // --- IFlow Implementation ---

    function execute(
        address caller,
        bytes calldata data
    ) external payable override returns (bytes memory) {
        bytes4 action = bytes4(data[:4]);
        bytes calldata params = data[4:];

        if (action == ACTION_CREATE) {
            return _create(caller, params);
        } else if (action == ACTION_EXECUTE) {
            return _executeDCA(caller, params);
        } else if (action == ACTION_CANCEL) {
            return _cancel(caller, params);
        } else if (action == ACTION_WITHDRAW) {
            return _withdraw(caller, params);
        } else if (action == ACTION_STATUS) {
            return _status(params);
        }

        revert("DCAFlow: unsupported action");
    }

    function flowId() external pure override returns (bytes4) {
        return FLOW_ID;
    }

    function supportsAction(bytes4 action) external pure override returns (bool) {
        return action == ACTION_CREATE ||
               action == ACTION_EXECUTE ||
               action == ACTION_CANCEL ||
               action == ACTION_WITHDRAW ||
               action == ACTION_STATUS;
    }

    function metadata() external pure override returns (string memory name, string memory version) {
        return ("DCAFlow", "1.0.0");
    }

    // --- Internal Functions ---

    function _create(
        address caller,
        bytes calldata params
    ) internal returns (bytes memory) {
        (
            address tokenIn,
            address tokenOut,
            uint256 amountPerPeriod,
            uint256 intervalSeconds,
            uint256 totalPeriods,
            address swapFlow,
            uint24 poolFee
        ) = abi.decode(params, (address, address, uint256, uint256, uint256, address, uint24));

        uint256 totalRequired = amountPerPeriod * totalPeriods;
        
        // Transfer tokens from caller
        IERC20(tokenIn).safeTransferFrom(caller, address(this), totalRequired);

        bytes32 positionId = keccak256(abi.encodePacked(
            caller,
            tokenIn,
            tokenOut,
            block.timestamp,
            positionCount++
        ));

        positions[positionId] = DCAPosition({
            owner: caller,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountPerPeriod: amountPerPeriod,
            intervalSeconds: intervalSeconds,
            totalPeriods: totalPeriods,
            periodsExecuted: 0,
            nextExecuteTime: block.timestamp, // Can execute immediately
            deposited: totalRequired,
            spent: 0,
            received: 0,
            active: true,
            swapFlow: swapFlow,
            poolFee: poolFee
        });

        emit DCACreated(
            positionId,
            caller,
            tokenIn,
            tokenOut,
            amountPerPeriod,
            intervalSeconds,
            totalPeriods
        );

        return abi.encode(positionId);
    }

    function _executeDCA(
        address, // anyone can trigger
        bytes calldata params
    ) internal returns (bytes memory) {
        bytes32 positionId = abi.decode(params, (bytes32));
        DCAPosition storage pos = positions[positionId];

        require(pos.owner != address(0), "DCAFlow: position not found");
        require(pos.active, "DCAFlow: position not active");
        require(pos.periodsExecuted < pos.totalPeriods, "DCAFlow: all periods executed");

        // Check if enough time has passed - PAUSE if not
        if (block.timestamp < pos.nextExecuteTime) {
            return abi.encode(DataTypes.PAUSE_EXECUTION);
        }

        // Execute swap via SwapFlow
        IERC20(pos.tokenIn).approve(pos.swapFlow, pos.amountPerPeriod);
        
        bytes memory swapParams = abi.encode(
            pos.tokenIn,
            pos.tokenOut,
            pos.poolFee,
            pos.amountPerPeriod,
            uint256(0) // minAmountOut - should be calculated properly in production
        );
        
        bytes memory swapCall = abi.encodePacked(
            bytes4(keccak256("swapExactIn")),
            swapParams
        );
        
        bytes memory result = IFlow(pos.swapFlow).execute(address(this), swapCall);
        uint256 amountOut = abi.decode(result, (uint256));

        // Update position
        pos.periodsExecuted++;
        pos.spent += pos.amountPerPeriod;
        pos.received += amountOut;
        pos.nextExecuteTime = block.timestamp + pos.intervalSeconds;

        // Transfer received tokens to owner
        IERC20(pos.tokenOut).safeTransfer(pos.owner, amountOut);

        emit DCAExecuted(positionId, pos.periodsExecuted, pos.amountPerPeriod, amountOut);

        // Check if completed
        if (pos.periodsExecuted >= pos.totalPeriods) {
            pos.active = false;
            emit DCACompleted(positionId);
        }

        return abi.encode(amountOut);
    }

    function _cancel(
        address caller,
        bytes calldata params
    ) internal returns (bytes memory) {
        bytes32 positionId = abi.decode(params, (bytes32));
        DCAPosition storage pos = positions[positionId];

        require(pos.owner == caller, "DCAFlow: not owner");
        require(pos.active, "DCAFlow: not active");

        pos.active = false;

        // Return remaining funds
        uint256 remaining = pos.deposited - pos.spent;
        if (remaining > 0) {
            IERC20(pos.tokenIn).safeTransfer(caller, remaining);
        }

        emit DCACancelled(positionId);

        return abi.encode(remaining);
    }

    function _withdraw(
        address caller,
        bytes calldata params
    ) internal returns (bytes memory) {
        (bytes32 positionId, address token) = abi.decode(params, (bytes32, address));
        DCAPosition storage pos = positions[positionId];

        require(pos.owner == caller, "DCAFlow: not owner");

        uint256 balance = IERC20(token).balanceOf(address(this));
        // Only allow withdrawing tokens that belong to this position
        // In production, need proper accounting per position
        
        if (balance > 0) {
            IERC20(token).safeTransfer(caller, balance);
        }

        emit Withdrawn(positionId, token, balance);

        return abi.encode(balance);
    }

    function _status(bytes calldata params) internal view returns (bytes memory) {
        bytes32 positionId = abi.decode(params, (bytes32));
        DCAPosition storage pos = positions[positionId];

        return abi.encode(
            pos.owner,
            pos.active,
            pos.periodsExecuted,
            pos.totalPeriods,
            pos.nextExecuteTime,
            pos.spent,
            pos.received
        );
    }
}
