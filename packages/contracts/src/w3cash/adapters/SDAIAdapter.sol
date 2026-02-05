// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title ISDAI
/// @notice Interface for sDAI (Savings DAI / ERC-4626)
interface ISDAI {
    // ERC-4626 functions
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function mint(uint256 shares, address receiver) external returns (uint256 assets);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    
    // View functions
    function totalAssets() external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function maxDeposit(address) external view returns (uint256);
    function maxMint(address) external view returns (uint256);
    function maxWithdraw(address owner) external view returns (uint256);
    function maxRedeem(address owner) external view returns (uint256);
    function previewDeposit(uint256 assets) external view returns (uint256);
    function previewMint(uint256 shares) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function asset() external view returns (address);
}

/// @title IPot
/// @notice Interface for MakerDAO Pot (DSR contract)
interface IPot {
    function chi() external view returns (uint256);
    function rho() external view returns (uint256);
    function dsr() external view returns (uint256);
    function drip() external returns (uint256);
}

/**
 * @title SDAIAdapter
 * @notice Action adapter for sDAI (Savings DAI / MakerDAO DSR)
 * @dev Supports deposit/withdraw via ERC-4626 interface
 */
contract SDAIAdapter is IAdapter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error SDAIAdapter__OnlyProcessor();
    error SDAIAdapter__InvalidOperation();
    error SDAIAdapter__ZeroAmount();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("SDAIAdapter"));
    
    /// @notice Operation selectors
    bytes4 public constant OP_DEPOSIT = 0x47e7ef24; // deposit(uint256,address)
    bytes4 public constant OP_MINT = 0x40c10f19; // mint(uint256,address)
    bytes4 public constant OP_WITHDRAW = 0xf3fef3a3; // withdraw(uint256,address,address)
    bytes4 public constant OP_REDEEM = 0xba087652; // redeem(uint256,address,address)

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    address public immutable processor;
    ISDAI public immutable sDAI;
    address public immutable dai;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _processor, address _sDAI, address _dai) {
        processor = _processor;
        sDAI = ISDAI(_sDAI);
        dai = _dai;
    }

    /*//////////////////////////////////////////////////////////////
                           ADAPTER INTERFACE
    //////////////////////////////////////////////////////////////*/

    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    function execute(address initiator, bytes calldata input) external payable override returns (bytes memory) {
        if (msg.sender != processor) revert SDAIAdapter__OnlyProcessor();
        if (input.length < 4) revert SDAIAdapter__InvalidOperation();

        bytes4 operation = bytes4(input[:4]);
        bytes calldata params = input[4:];

        if (operation == OP_DEPOSIT) {
            return _executeDeposit(initiator, params);
        } else if (operation == OP_MINT) {
            return _executeMint(initiator, params);
        } else if (operation == OP_WITHDRAW) {
            return _executeWithdraw(initiator, params);
        } else if (operation == OP_REDEEM) {
            return _executeRedeem(initiator, params);
        } else {
            revert SDAIAdapter__InvalidOperation();
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

    /// @notice Deposit DAI for sDAI
    function _executeDeposit(address initiator, bytes calldata params) internal returns (bytes memory) {
        uint256 daiAmount = abi.decode(params, (uint256));
        
        if (daiAmount == 0) revert SDAIAdapter__ZeroAmount();

        // Transfer DAI from initiator
        IERC20(dai).safeTransferFrom(initiator, address(this), daiAmount);
        IERC20(dai).forceApprove(address(sDAI), daiAmount);

        // Deposit DAI and receive sDAI
        uint256 shares = sDAI.deposit(daiAmount, initiator);

        return abi.encode(shares);
    }

    /// @notice Mint exact sDAI shares by depositing DAI
    function _executeMint(address initiator, bytes calldata params) internal returns (bytes memory) {
        uint256 shares = abi.decode(params, (uint256));
        
        if (shares == 0) revert SDAIAdapter__ZeroAmount();

        // Calculate DAI needed
        uint256 daiNeeded = sDAI.previewMint(shares);

        // Transfer DAI from initiator
        IERC20(dai).safeTransferFrom(initiator, address(this), daiNeeded);
        IERC20(dai).forceApprove(address(sDAI), daiNeeded);

        // Mint sDAI
        uint256 assets = sDAI.mint(shares, initiator);

        return abi.encode(assets);
    }

    /// @notice Withdraw exact DAI amount by burning sDAI
    function _executeWithdraw(address initiator, bytes calldata params) internal returns (bytes memory) {
        uint256 daiAmount = abi.decode(params, (uint256));
        
        if (daiAmount == 0) revert SDAIAdapter__ZeroAmount();

        // Calculate sDAI needed
        uint256 sharesNeeded = sDAI.previewWithdraw(daiAmount);

        // Transfer sDAI from initiator
        IERC20(address(sDAI)).safeTransferFrom(initiator, address(this), sharesNeeded);

        // Withdraw DAI
        uint256 shares = sDAI.withdraw(daiAmount, initiator, address(this));

        return abi.encode(shares);
    }

    /// @notice Redeem sDAI shares for DAI
    function _executeRedeem(address initiator, bytes calldata params) internal returns (bytes memory) {
        uint256 shares = abi.decode(params, (uint256));
        
        if (shares == 0) revert SDAIAdapter__ZeroAmount();

        // Transfer sDAI from initiator
        IERC20(address(sDAI)).safeTransferFrom(initiator, address(this), shares);

        // Redeem for DAI
        uint256 assets = sDAI.redeem(shares, initiator, address(this));

        return abi.encode(assets);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Preview deposit - how many sDAI for given DAI
    function previewDeposit(uint256 daiAmount) external view returns (uint256) {
        return sDAI.previewDeposit(daiAmount);
    }

    /// @notice Preview withdraw - how many sDAI needed for given DAI
    function previewWithdraw(uint256 daiAmount) external view returns (uint256) {
        return sDAI.previewWithdraw(daiAmount);
    }

    /// @notice Convert sDAI to DAI value
    function convertToAssets(uint256 shares) external view returns (uint256) {
        return sDAI.convertToAssets(shares);
    }

    /// @notice Convert DAI to sDAI shares
    function convertToShares(uint256 assets) external view returns (uint256) {
        return sDAI.convertToShares(assets);
    }

    /// @notice Get total assets in sDAI vault
    function totalAssets() external view returns (uint256) {
        return sDAI.totalAssets();
    }
}
