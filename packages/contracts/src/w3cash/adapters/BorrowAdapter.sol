// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title IAavePoolBorrow
/// @notice Minimal interface for Aave V3 Pool borrowing
interface IAavePoolBorrow {
    function borrow(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        uint16 referralCode,
        address onBehalfOf
    ) external;
}

/// @title BorrowAdapter
/// @notice Adapter for borrowing assets from Aave V3
/// @dev User must have collateral deposited and sufficient borrowing power
contract BorrowAdapter is IAdapter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error BorrowAdapter__CallerNotProcessor();
    error BorrowAdapter__ZeroAmount();
    error BorrowAdapter__InvalidRateMode();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("BorrowAdapter"));

    /// @notice Interest rate modes
    uint256 public constant STABLE_RATE = 1;
    uint256 public constant VARIABLE_RATE = 2;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The Aave V3 Pool contract
    IAavePoolBorrow public immutable pool;

    /// @notice The authorized Processor contract
    address public immutable processor;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyProcessor() {
        if (msg.sender != processor) revert BorrowAdapter__CallerNotProcessor();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _pool The Aave V3 Pool address
    /// @param _processor The authorized Processor address
    constructor(address _pool, address _processor) {
        pool = IAavePoolBorrow(_pool);
        processor = _processor;
    }

    /*//////////////////////////////////////////////////////////////
                           ADAPTER INTERFACE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAdapter
    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    /// @notice Execute a borrow operation
    /// @param account The account borrowing (must have collateral)
    /// @param data ABI encoded (address asset, uint256 amount, uint256 interestRateMode)
    /// @return ABI encoded borrowed amount
    function execute(
        address account,
        bytes calldata data
    ) external payable override onlyProcessor returns (bytes memory) {
        (
            address asset,
            uint256 amount,
            uint256 interestRateMode
        ) = abi.decode(data, (address, uint256, uint256));

        if (amount == 0) revert BorrowAdapter__ZeroAmount();
        if (interestRateMode != STABLE_RATE && interestRateMode != VARIABLE_RATE) {
            revert BorrowAdapter__InvalidRateMode();
        }

        // Borrow from Aave on behalf of the user
        // Borrowed tokens go directly to the user's wallet
        pool.borrow(asset, amount, interestRateMode, 0, account);

        return abi.encode(amount);
    }

    /// @inheritdoc IAdapter
    function send(bytes memory, uint8, uint64, uint112) external payable override returns (uint64) {
        revert("BorrowAdapter: send not supported");
    }

    /// @inheritdoc IAdapter
    function estimateFee(uint8, uint112, uint256) external pure override returns (uint256) {
        return 0;
    }
}
