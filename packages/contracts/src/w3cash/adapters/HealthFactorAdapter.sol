// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { DataTypes } from "../utils/DataTypes.sol";

/// @title IAavePoolHealth
/// @notice Interface for Aave V3 Pool health checks
interface IAavePoolHealth {
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

/// @title HealthFactorAdapter
/// @notice Condition adapter for monitoring Aave V3 health factors
/// @dev Used for emergency exits and liquidation protection
contract HealthFactorAdapter is IAdapter {

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error HealthFactorAdapter__CallerNotProcessor();
    error HealthFactorAdapter__InvalidOperator();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("HealthFactorAdapter"));

    // Operators
    uint8 public constant OP_LT = 0;   // <
    uint8 public constant OP_GT = 1;   // >
    uint8 public constant OP_LTE = 2;  // <=
    uint8 public constant OP_GTE = 3;  // >=

    /// @notice 1e18 = health factor of 1.0
    uint256 public constant HEALTH_FACTOR_ONE = 1e18;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The Aave V3 Pool contract
    IAavePoolHealth public immutable pool;

    /// @notice The authorized Processor contract
    address public immutable processor;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyProcessor() {
        if (msg.sender != processor) revert HealthFactorAdapter__CallerNotProcessor();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _pool The Aave V3 Pool address
    /// @param _processor The authorized Processor address
    constructor(address _pool, address _processor) {
        pool = IAavePoolHealth(_pool);
        processor = _processor;
    }

    /*//////////////////////////////////////////////////////////////
                           ADAPTER INTERFACE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAdapter
    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    /// @notice Check if health factor condition is met
    /// @param account The account to check (or override in data)
    /// @param data ABI encoded (address user, uint8 operator, uint256 threshold)
    ///        user: Address to check health factor for
    ///        operator: Comparison operator (0-3)
    ///        threshold: Health factor threshold (1e18 = 1.0)
    /// @return PAUSE_EXECUTION if condition not met, empty bytes if met
    function execute(
        address account,
        bytes calldata data
    ) external payable override onlyProcessor returns (bytes memory) {
        (
            address user,
            uint8 operator,
            uint256 threshold
        ) = abi.decode(data, (address, uint8, uint256));

        // Get health factor from Aave
        (,,,,,uint256 healthFactor) = pool.getUserAccountData(user);

        // Check condition
        bool conditionMet = _compare(healthFactor, operator, threshold);

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
        revert HealthFactorAdapter__InvalidOperator();
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get user's current health factor
    function getHealthFactor(address user) external view returns (uint256) {
        (,,,,,uint256 healthFactor) = pool.getUserAccountData(user);
        return healthFactor;
    }

    /// @notice Get user's full Aave account data
    function getAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        )
    {
        return pool.getUserAccountData(user);
    }

    /// @notice Check if user is at liquidation risk (health factor < 1.1)
    function isAtRisk(address user) external view returns (bool) {
        (,,,,,uint256 healthFactor) = pool.getUserAccountData(user);
        return healthFactor < (11 * HEALTH_FACTOR_ONE / 10); // < 1.1
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
