// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title IComet
/// @notice Minimal interface for Compound V3 (Comet)
interface IComet {
    function supply(address asset, uint256 amount) external;
    function supplyTo(address dst, address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount) external;
    function withdrawTo(address to, address asset, uint256 amount) external;
    function borrowBalanceOf(address account) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function baseToken() external view returns (address);
    function collateralBalanceOf(address account, address asset) external view returns (uint128);
}

/// @title CompoundAdapter
/// @notice Adapter for Compound V3 (Comet) protocol operations
/// @dev Supports supply, withdraw for base token and collateral
contract CompoundAdapter is IAdapter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error CompoundAdapter__CallerNotProcessor();
    error CompoundAdapter__ZeroAmount();
    error CompoundAdapter__InvalidOperation();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("CompoundAdapter"));

    /// @notice Operation selectors
    bytes4 public constant OP_SUPPLY = 0x53555050;    // "SUPP"
    bytes4 public constant OP_WITHDRAW = 0x57495448;  // "WITH"

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The Compound V3 Comet contract
    IComet public immutable comet;

    /// @notice The authorized Processor contract
    address public immutable processor;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyProcessor() {
        if (msg.sender != processor) revert CompoundAdapter__CallerNotProcessor();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _comet The Compound V3 Comet address
    /// @param _processor The authorized Processor address
    constructor(address _comet, address _processor) {
        comet = IComet(_comet);
        processor = _processor;
    }

    /*//////////////////////////////////////////////////////////////
                           ADAPTER INTERFACE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAdapter
    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    /// @notice Execute a Compound V3 operation
    /// @param account The account performing the operation
    /// @param data ABI encoded based on operation:
    ///        SUPPLY: (bytes4 op, address asset, uint256 amount)
    ///        WITHDRAW: (bytes4 op, address asset, uint256 amount)
    /// @return ABI encoded amount
    function execute(
        address account,
        bytes calldata data
    ) external payable override onlyProcessor returns (bytes memory) {
        bytes4 operation = bytes4(data[:4]);

        if (operation == OP_SUPPLY) {
            return _supply(account, data[4:]);
        } else if (operation == OP_WITHDRAW) {
            return _withdraw(account, data[4:]);
        } else {
            revert CompoundAdapter__InvalidOperation();
        }
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _supply(address account, bytes calldata data) internal returns (bytes memory) {
        (address asset, uint256 amount) = abi.decode(data, (address, uint256));

        if (amount == 0) revert CompoundAdapter__ZeroAmount();

        // Transfer tokens from user to adapter
        IERC20(asset).safeTransferFrom(account, address(this), amount);

        // Approve Comet to spend tokens
        IERC20(asset).forceApprove(address(comet), amount);

        // Supply to Comet on behalf of user
        comet.supplyTo(account, asset, amount);

        return abi.encode(amount);
    }

    function _withdraw(address account, bytes calldata data) internal returns (bytes memory) {
        (address asset, uint256 amount) = abi.decode(data, (address, uint256));

        if (amount == 0) revert CompoundAdapter__ZeroAmount();

        // Withdraw from Comet to user
        // Note: User must have allowed this adapter to manage their position
        comet.withdrawTo(account, asset, amount);

        return abi.encode(amount);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get user's balance of base token
    function getBalance(address account) external view returns (uint256) {
        return comet.balanceOf(account);
    }

    /// @notice Get user's borrow balance
    function getBorrowBalance(address account) external view returns (uint256) {
        return comet.borrowBalanceOf(account);
    }

    /// @notice Get user's collateral balance for an asset
    function getCollateralBalance(address account, address asset) external view returns (uint128) {
        return comet.collateralBalanceOf(account, asset);
    }

    /// @notice Get the base token address
    function getBaseToken() external view returns (address) {
        return comet.baseToken();
    }

    /// @inheritdoc IAdapter
    function send(bytes memory, uint8, uint64, uint112) external payable override returns (uint64) {
        revert("CompoundAdapter: send not supported");
    }

    /// @inheritdoc IAdapter
    function estimateFee(uint8, uint112, uint256) external pure override returns (uint256) {
        return 0;
    }
}
