// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title IAavePoolRepay
/// @notice Minimal interface for Aave V3 Pool repayment
interface IAavePoolRepay {
    function repay(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        address onBehalfOf
    ) external returns (uint256);
}

/// @title RepayAdapter
/// @notice Adapter for repaying Aave V3 loans
/// @dev User must have borrowed the asset and have tokens to repay
contract RepayAdapter is IAdapter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error RepayAdapter__CallerNotProcessor();
    error RepayAdapter__ZeroAmount();
    error RepayAdapter__InvalidRateMode();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("RepayAdapter"));

    /// @notice Interest rate modes
    uint256 public constant STABLE_RATE = 1;
    uint256 public constant VARIABLE_RATE = 2;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The Aave V3 Pool contract
    IAavePoolRepay public immutable pool;

    /// @notice The authorized Processor contract
    address public immutable processor;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyProcessor() {
        if (msg.sender != processor) revert RepayAdapter__CallerNotProcessor();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _pool The Aave V3 Pool address
    /// @param _processor The authorized Processor address
    constructor(address _pool, address _processor) {
        pool = IAavePoolRepay(_pool);
        processor = _processor;
    }

    /*//////////////////////////////////////////////////////////////
                           ADAPTER INTERFACE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAdapter
    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    /// @notice Execute a repay operation
    /// @param account The account repaying (must have debt)
    /// @param data ABI encoded (address asset, uint256 amount, uint256 interestRateMode)
    ///        Use type(uint256).max for amount to repay full debt
    /// @return ABI encoded amount actually repaid
    function execute(
        address account,
        bytes calldata data
    ) external payable override onlyProcessor returns (bytes memory) {
        (
            address asset,
            uint256 amount,
            uint256 interestRateMode
        ) = abi.decode(data, (address, uint256, uint256));

        if (amount == 0) revert RepayAdapter__ZeroAmount();
        if (interestRateMode != STABLE_RATE && interestRateMode != VARIABLE_RATE) {
            revert RepayAdapter__InvalidRateMode();
        }

        // Transfer tokens from user to adapter
        IERC20(asset).safeTransferFrom(account, address(this), amount);

        // Approve pool to spend tokens
        IERC20(asset).forceApprove(address(pool), amount);

        // Repay debt on behalf of user
        uint256 repaidAmount = pool.repay(asset, amount, interestRateMode, account);

        // Return any excess (if repaying more than debt)
        uint256 remaining = amount - repaidAmount;
        if (remaining > 0) {
            IERC20(asset).safeTransfer(account, remaining);
        }

        return abi.encode(repaidAmount);
    }

    /// @inheritdoc IAdapter
    function send(bytes memory, uint8, uint64, uint112) external payable override returns (uint64) {
        revert("RepayAdapter: send not supported");
    }

    /// @inheritdoc IAdapter
    function estimateFee(uint8, uint112, uint256) external pure override returns (uint256) {
        return 0;
    }
}
