// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title IAavePoolFlash
/// @notice Interface for Aave V3 flash loans
interface IAavePoolFlash {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
    
    function FLASHLOAN_PREMIUM_TOTAL() external view returns (uint128);
}

/// @title IFlashLoanSimpleReceiver
/// @notice Interface for flash loan receiver
interface IFlashLoanSimpleReceiver {
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool);
}

/// @title FlashLoanAdapter
/// @notice Adapter for executing Aave V3 flash loans
/// @dev Allows users to borrow and repay within a single transaction
contract FlashLoanAdapter is IAdapter, IFlashLoanSimpleReceiver {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error FlashLoanAdapter__CallerNotProcessor();
    error FlashLoanAdapter__CallerNotPool();
    error FlashLoanAdapter__ZeroAmount();
    error FlashLoanAdapter__ExecutionFailed();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("FlashLoanAdapter"));

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The Aave V3 Pool contract
    IAavePoolFlash public immutable pool;

    /// @notice The authorized Processor contract
    address public immutable processor;

    /// @notice Temporary storage for flash loan callback
    address private _currentInitiator;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyProcessor() {
        if (msg.sender != processor) revert FlashLoanAdapter__CallerNotProcessor();
        _;
    }

    modifier onlyPool() {
        if (msg.sender != address(pool)) revert FlashLoanAdapter__CallerNotPool();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _pool The Aave V3 Pool address
    /// @param _processor The authorized Processor address
    constructor(address _pool, address _processor) {
        pool = IAavePoolFlash(_pool);
        processor = _processor;
    }

    /*//////////////////////////////////////////////////////////////
                           ADAPTER INTERFACE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAdapter
    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    /// @notice Execute a flash loan
    /// @param account The account initiating the flash loan
    /// @param data ABI encoded (address asset, uint256 amount, bytes operations)
    ///        asset: Token to borrow
    ///        amount: Amount to borrow
    ///        operations: Encoded operations to execute with borrowed funds
    /// @return Empty bytes (result from callback)
    function execute(
        address account,
        bytes calldata data
    ) external payable override onlyProcessor returns (bytes memory) {
        (
            address asset,
            uint256 amount,
            bytes memory operations
        ) = abi.decode(data, (address, uint256, bytes));

        if (amount == 0) revert FlashLoanAdapter__ZeroAmount();

        // Store initiator for callback
        _currentInitiator = account;

        // Initiate flash loan
        pool.flashLoanSimple(
            address(this),  // receiver
            asset,
            amount,
            operations,     // params passed to callback
            0               // referral code
        );

        // Clear initiator
        _currentInitiator = address(0);

        return "";
    }

    /*//////////////////////////////////////////////////////////////
                         FLASH LOAN CALLBACK
    //////////////////////////////////////////////////////////////*/

    /// @notice Callback from Aave pool during flash loan
    /// @param asset The borrowed asset
    /// @param amount The borrowed amount
    /// @param premium The flash loan fee
    /// @param initiator The address that initiated (this contract)
    /// @param params The operations to execute
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external override onlyPool returns (bool) {
        // Verify initiator is this contract
        if (initiator != address(this)) revert FlashLoanAdapter__ExecutionFailed();

        address user = _currentInitiator;

        // Transfer borrowed funds to user
        IERC20(asset).safeTransfer(user, amount);

        // Execute user operations if any
        if (params.length > 0) {
            // params contains target + calldata for arbitrary execution
            (address target, bytes memory callData) = abi.decode(params, (address, bytes));
            (bool success, ) = target.call(callData);
            if (!success) revert FlashLoanAdapter__ExecutionFailed();
        }

        // User must have approved this adapter for repayment
        uint256 totalOwed = amount + premium;
        IERC20(asset).safeTransferFrom(user, address(this), totalOwed);

        // Approve pool to pull repayment
        IERC20(asset).forceApprove(address(pool), totalOwed);

        return true;
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get flash loan premium (in basis points)
    function getPremium() external view returns (uint128) {
        return pool.FLASHLOAN_PREMIUM_TOTAL();
    }

    /// @notice Calculate total amount owed for a flash loan
    function calculateOwed(uint256 amount) external view returns (uint256) {
        uint128 premium = pool.FLASHLOAN_PREMIUM_TOTAL();
        return amount + (amount * premium / 10000);
    }

    /// @inheritdoc IAdapter
    function send(bytes memory, uint8, uint64, uint112) external payable override returns (uint64) {
        revert("FlashLoanAdapter: send not supported");
    }

    /// @inheritdoc IAdapter
    function estimateFee(uint8, uint112, uint256) external pure override returns (uint256) {
        return 0;
    }
}
