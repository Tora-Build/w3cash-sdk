// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title IAavePool
/// @notice Minimal interface for Aave V3 Pool
interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
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

/// @title AaveAdapter
/// @notice Adapter for Aave V3 lending protocol operations
/// @dev Implements deposit, withdraw, and balance query operations for Aave V3
contract AaveAdapter is IAdapter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error AaveAdapter__InvalidOperation();
    error AaveAdapter__ZeroAmount();
    error AaveAdapter__InsufficientBalance();
    error AaveAdapter__TransferFailed();
    error AaveAdapter__CallerNotProcessor();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Adapter identifier: "AAVE" in bytes4
    bytes4 public constant ADAPTER_ID = 0x41415645; // "AAVE"

    /// @notice Operation selectors
    bytes4 public constant OP_DEPOSIT = 0x47e7ef24; // deposit(address,uint256)
    bytes4 public constant OP_WITHDRAW = 0xf3fef3a3; // withdraw(address,uint256)
    bytes4 public constant OP_WITHDRAW_ALL = 0xfa09e630; // withdrawAll(address)

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The Aave V3 Pool contract
    IAavePool public immutable pool;

    /// @notice The authorized Processor contract
    address public immutable processor;

    /// @notice Mapping of underlying token to aToken
    mapping(address => address) public aTokens;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Restricts calls to the Processor contract only
    modifier onlyProcessor() {
        if (msg.sender != processor) revert AaveAdapter__CallerNotProcessor();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize the adapter with the Aave V3 Pool and Processor
    /// @param _pool The Aave V3 Pool address
    /// @param _processor The authorized Processor address
    constructor(address _pool, address _processor) {
        pool = IAavePool(_pool);
        processor = _processor;
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Register an aToken for an underlying asset
    /// @param underlying The underlying token address
    /// @param aToken The corresponding aToken address
    function registerAToken(address underlying, address aToken) external {
        // In production, this should be access controlled
        aTokens[underlying] = aToken;
    }

    /*//////////////////////////////////////////////////////////////
                           ADAPTER INTERFACE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAdapter
    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    /// @inheritdoc IAdapter
    function execute(address account, bytes calldata data) external payable override onlyProcessor returns (bytes memory result) {
        if (data.length < 4) revert AaveAdapter__InvalidOperation();

        bytes4 operation = bytes4(data[:4]);
        bytes calldata params = data[4:];

        if (operation == OP_DEPOSIT) {
            return _executeDeposit(account, params);
        } else if (operation == OP_WITHDRAW) {
            return _executeWithdraw(account, params);
        } else if (operation == OP_WITHDRAW_ALL) {
            return _executeWithdrawAll(account, params);
        } else {
            revert AaveAdapter__InvalidOperation();
        }
    }

    /// @notice Check if operation is supported
    function supportsFunction(bytes4 selector) external pure returns (bool) {
        return selector == OP_DEPOSIT || selector == OP_WITHDRAW || selector == OP_WITHDRAW_ALL;
    }

    /// @inheritdoc IAdapter
    function send(bytes memory, uint8, uint64, uint112) external payable override returns (uint64) {
        revert("AaveAdapter: send not supported");
    }

    /// @inheritdoc IAdapter
    function estimateFee(uint8, uint112, uint256) external pure override returns (uint256) {
        return 0;
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Execute a deposit operation
    /// @param account The account making the deposit
    /// @param params ABI encoded (address token, uint256 amount)
    function _executeDeposit(address account, bytes calldata params) internal returns (bytes memory) {
        (address token, uint256 amount) = abi.decode(params, (address, uint256));

        if (amount == 0) revert AaveAdapter__ZeroAmount();

        // Transfer tokens from the account to this adapter
        IERC20(token).safeTransferFrom(account, address(this), amount);

        // Approve the pool to spend tokens
        IERC20(token).forceApprove(address(pool), amount);

        // Supply to Aave on behalf of the account
        pool.supply(token, amount, account, 0);

        return abi.encode(amount);
    }

    /// @notice Execute a withdraw operation
    /// @param account The account making the withdrawal
    /// @param params ABI encoded (address token, uint256 amount)
    function _executeWithdraw(address account, bytes calldata params) internal returns (bytes memory) {
        (address token, uint256 amount) = abi.decode(params, (address, uint256));

        if (amount == 0) revert AaveAdapter__ZeroAmount();

        address aToken = aTokens[token];
        if (aToken == address(0)) revert AaveAdapter__InvalidOperation();

        // Transfer aTokens from the account to this adapter
        IERC20(aToken).safeTransferFrom(account, address(this), amount);

        // Withdraw from Aave to the account
        uint256 withdrawn = pool.withdraw(token, amount, account);

        return abi.encode(withdrawn);
    }

    /// @notice Execute a withdraw all operation
    /// @param account The account making the withdrawal
    /// @param params ABI encoded (address token)
    function _executeWithdrawAll(address account, bytes calldata params) internal returns (bytes memory) {
        address token = abi.decode(params, (address));

        address aToken = aTokens[token];
        if (aToken == address(0)) revert AaveAdapter__InvalidOperation();

        // Get the full aToken balance
        uint256 aTokenBalance = IERC20(aToken).balanceOf(account);
        if (aTokenBalance == 0) revert AaveAdapter__ZeroAmount();

        // Transfer aTokens from the account to this adapter
        IERC20(aToken).safeTransferFrom(account, address(this), aTokenBalance);

        // Withdraw all from Aave (type(uint256).max signals withdraw all)
        uint256 withdrawn = pool.withdraw(token, type(uint256).max, account);

        return abi.encode(withdrawn);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the aToken balance for an account
    /// @param account The account to query
    /// @param underlying The underlying token address
    /// @return balance The aToken balance
    function getBalance(address account, address underlying) external view returns (uint256 balance) {
        address aToken = aTokens[underlying];
        if (aToken == address(0)) return 0;
        return IERC20(aToken).balanceOf(account);
    }

    /// @notice Get the user's Aave account data
    /// @param account The account to query
    /// @return totalCollateralBase Total collateral in base currency
    /// @return totalDebtBase Total debt in base currency
    /// @return availableBorrowsBase Available borrows in base currency
    /// @return currentLiquidationThreshold Current liquidation threshold
    /// @return ltv Loan-to-value ratio
    /// @return healthFactor Health factor
    function getUserAccountData(address account)
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
        return pool.getUserAccountData(account);
    }
}
