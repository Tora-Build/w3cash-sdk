// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title IYearnVault
/// @notice Interface for Yearn V3 Vaults (ERC-4626)
interface IYearnVault {
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function mint(uint256 shares, address receiver) external returns (uint256);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256);
    function withdraw(uint256 assets, address receiver, address owner, uint256 maxLoss) external returns (uint256);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
    function redeem(uint256 shares, address receiver, address owner, uint256 maxLoss) external returns (uint256);
    
    function totalAssets() external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function previewDeposit(uint256 assets) external view returns (uint256);
    function previewMint(uint256 shares) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function maxDeposit(address) external view returns (uint256);
    function maxWithdraw(address owner) external view returns (uint256);
    function asset() external view returns (address);
    function pricePerShare() external view returns (uint256);
}

/// @title IYearnRegistry
/// @notice Interface for Yearn Registry
interface IYearnRegistry {
    function latestVault(address token) external view returns (address);
    function numVaults(address token) external view returns (uint256);
    function vaults(address token, uint256 index) external view returns (address);
}

/**
 * @title YearnAdapter
 * @notice Action adapter for Yearn Finance V3 Vaults
 * @dev Supports deposit, withdraw, and vault querying
 */
contract YearnAdapter is IAdapter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error YearnAdapter__OnlyProcessor();
    error YearnAdapter__InvalidOperation();
    error YearnAdapter__ZeroAmount();
    error YearnAdapter__InvalidVault();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("YearnAdapter"));
    
    /// @notice Operation selectors
    bytes4 public constant OP_DEPOSIT = 0x47e7ef24; // deposit(uint256,address)
    bytes4 public constant OP_WITHDRAW = 0xf3fef3a3; // withdraw(uint256,address,address)
    bytes4 public constant OP_REDEEM = 0xba087652; // redeem(uint256,address,address)
    bytes4 public constant OP_WITHDRAW_WITH_LOSS = 0x00f714ce; // withdraw with maxLoss

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    address public immutable processor;
    IYearnRegistry public immutable registry;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _processor, address _registry) {
        processor = _processor;
        registry = IYearnRegistry(_registry);
    }

    /*//////////////////////////////////////////////////////////////
                           ADAPTER INTERFACE
    //////////////////////////////////////////////////////////////*/

    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    function execute(address initiator, bytes calldata input) external payable override returns (bytes memory) {
        if (msg.sender != processor) revert YearnAdapter__OnlyProcessor();
        if (input.length < 4) revert YearnAdapter__InvalidOperation();

        bytes4 operation = bytes4(input[:4]);
        bytes calldata params = input[4:];

        if (operation == OP_DEPOSIT) {
            return _executeDeposit(initiator, params);
        } else if (operation == OP_WITHDRAW) {
            return _executeWithdraw(initiator, params);
        } else if (operation == OP_REDEEM) {
            return _executeRedeem(initiator, params);
        } else if (operation == OP_WITHDRAW_WITH_LOSS) {
            return _executeWithdrawWithLoss(initiator, params);
        } else {
            revert YearnAdapter__InvalidOperation();
        }
    }

    function send(bytes memory, uint8, uint64, uint112) external payable override returns (uint64) {
        return 0;
    }

    function estimateFee(uint8, uint112, uint256) external pure override returns (uint256) {
        return 0;
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit assets into a Yearn vault
    function _executeDeposit(address initiator, bytes calldata params) internal returns (bytes memory) {
        (address vault, uint256 amount) = abi.decode(params, (address, uint256));
        
        if (amount == 0) revert YearnAdapter__ZeroAmount();
        if (vault == address(0)) revert YearnAdapter__InvalidVault();

        // Get underlying asset
        address asset = IYearnVault(vault).asset();

        // Transfer assets from initiator
        IERC20(asset).safeTransferFrom(initiator, address(this), amount);
        IERC20(asset).forceApprove(vault, amount);

        // Deposit to vault - shares go to initiator
        uint256 shares = IYearnVault(vault).deposit(amount, initiator);

        return abi.encode(shares);
    }

    /// @notice Withdraw exact assets from a Yearn vault
    function _executeWithdraw(address initiator, bytes calldata params) internal returns (bytes memory) {
        (address vault, uint256 amount) = abi.decode(params, (address, uint256));
        
        if (amount == 0) revert YearnAdapter__ZeroAmount();
        if (vault == address(0)) revert YearnAdapter__InvalidVault();

        // Calculate shares needed
        uint256 sharesNeeded = IYearnVault(vault).previewWithdraw(amount);

        // Transfer vault shares from initiator
        IERC20(vault).safeTransferFrom(initiator, address(this), sharesNeeded);

        // Withdraw - assets go to initiator
        uint256 shares = IYearnVault(vault).withdraw(amount, initiator, address(this));

        return abi.encode(shares);
    }

    /// @notice Redeem vault shares for assets
    function _executeRedeem(address initiator, bytes calldata params) internal returns (bytes memory) {
        (address vault, uint256 shares) = abi.decode(params, (address, uint256));
        
        if (shares == 0) revert YearnAdapter__ZeroAmount();
        if (vault == address(0)) revert YearnAdapter__InvalidVault();

        // Transfer vault shares from initiator
        IERC20(vault).safeTransferFrom(initiator, address(this), shares);

        // Redeem - assets go to initiator
        uint256 assets = IYearnVault(vault).redeem(shares, initiator, address(this));

        return abi.encode(assets);
    }

    /// @notice Withdraw with max loss tolerance (for illiquid situations)
    function _executeWithdrawWithLoss(address initiator, bytes calldata params) internal returns (bytes memory) {
        (address vault, uint256 amount, uint256 maxLoss) = abi.decode(params, (address, uint256, uint256));
        
        if (amount == 0) revert YearnAdapter__ZeroAmount();
        if (vault == address(0)) revert YearnAdapter__InvalidVault();

        // Calculate shares needed
        uint256 sharesNeeded = IYearnVault(vault).previewWithdraw(amount);

        // Transfer vault shares from initiator
        IERC20(vault).safeTransferFrom(initiator, address(this), sharesNeeded);

        // Withdraw with max loss - assets go to initiator
        uint256 shares = IYearnVault(vault).withdraw(amount, initiator, address(this), maxLoss);

        return abi.encode(shares);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the latest vault for a token
    function getLatestVault(address token) external view returns (address) {
        return registry.latestVault(token);
    }

    /// @notice Get price per share of a vault
    function getPricePerShare(address vault) external view returns (uint256) {
        return IYearnVault(vault).pricePerShare();
    }

    /// @notice Get total assets in a vault
    function getTotalAssets(address vault) external view returns (uint256) {
        return IYearnVault(vault).totalAssets();
    }

    /// @notice Preview deposit - how many shares for given assets
    function previewDeposit(address vault, uint256 assets) external view returns (uint256) {
        return IYearnVault(vault).previewDeposit(assets);
    }

    /// @notice Preview redeem - how many assets for given shares
    function previewRedeem(address vault, uint256 shares) external view returns (uint256) {
        return IYearnVault(vault).previewRedeem(shares);
    }

    /// @notice Convert shares to assets
    function convertToAssets(address vault, uint256 shares) external view returns (uint256) {
        return IYearnVault(vault).convertToAssets(shares);
    }

    /// @notice Convert assets to shares
    function convertToShares(address vault, uint256 assets) external view returns (uint256) {
        return IYearnVault(vault).convertToShares(assets);
    }
}
