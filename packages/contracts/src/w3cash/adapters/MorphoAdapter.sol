// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Morpho Blue market parameters
struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm; // Interest Rate Model
    uint256 lltv; // Liquidation LTV
}

/// @title IMorpho
/// @notice Minimal interface for Morpho Blue
interface IMorpho {
    function supply(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes memory data
    ) external returns (uint256 assetsSupplied, uint256 sharesSupplied);
    
    function withdraw(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn);
    
    function borrow(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsBorrowed, uint256 sharesBorrowed);
    
    function repay(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        bytes memory data
    ) external returns (uint256 assetsRepaid, uint256 sharesRepaid);
    
    function supplyCollateral(
        MarketParams memory marketParams,
        uint256 assets,
        address onBehalf,
        bytes memory data
    ) external;
    
    function withdrawCollateral(
        MarketParams memory marketParams,
        uint256 assets,
        address onBehalf,
        address receiver
    ) external;
    
    function setAuthorization(address authorized, bool isAuthorized) external;
    function isAuthorized(address owner, address authorized) external view returns (bool);
}

/**
 * @title MorphoAdapter
 * @notice Action adapter for Morpho Blue protocol
 * @dev Supports supply, withdraw, borrow, repay, and collateral operations
 */
contract MorphoAdapter is IAdapter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error MorphoAdapter__OnlyProcessor();
    error MorphoAdapter__InvalidOperation();
    error MorphoAdapter__ZeroAmount();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("MorphoAdapter"));
    
    /// @notice Operation selectors
    bytes4 public constant OP_SUPPLY = 0x47e7ef24; // deposit(address,uint256)
    bytes4 public constant OP_WITHDRAW = 0xf3fef3a3; // withdraw(address,uint256)
    bytes4 public constant OP_SUPPLY_COLLATERAL = 0x2505c3d9; // supplyCollateral(...)
    bytes4 public constant OP_WITHDRAW_COLLATERAL = 0x7f8661a1; // withdrawCollateral(...)
    bytes4 public constant OP_BORROW = 0xc5ebeaec; // borrow(uint256)
    bytes4 public constant OP_REPAY = 0x0e752702; // repayBorrow(uint256)

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    IMorpho public immutable morpho;
    address public immutable processor;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _morpho, address _processor) {
        morpho = IMorpho(_morpho);
        processor = _processor;
    }

    /*//////////////////////////////////////////////////////////////
                           ADAPTER INTERFACE
    //////////////////////////////////////////////////////////////*/

    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    function execute(address initiator, bytes calldata input) external payable override returns (bytes memory) {
        if (msg.sender != processor) revert MorphoAdapter__OnlyProcessor();
        if (input.length < 4) revert MorphoAdapter__InvalidOperation();

        bytes4 operation = bytes4(input[:4]);
        bytes calldata params = input[4:];

        if (operation == OP_SUPPLY) {
            return _executeSupply(initiator, params);
        } else if (operation == OP_WITHDRAW) {
            return _executeWithdraw(initiator, params);
        } else if (operation == OP_SUPPLY_COLLATERAL) {
            return _executeSupplyCollateral(initiator, params);
        } else if (operation == OP_WITHDRAW_COLLATERAL) {
            return _executeWithdrawCollateral(initiator, params);
        } else if (operation == OP_BORROW) {
            return _executeBorrow(initiator, params);
        } else if (operation == OP_REPAY) {
            return _executeRepay(initiator, params);
        } else {
            revert MorphoAdapter__InvalidOperation();
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

    /// @notice Supply loan tokens to Morpho Blue market
    function _executeSupply(address initiator, bytes calldata params) internal returns (bytes memory) {
        (MarketParams memory marketParams, uint256 amount) = abi.decode(params, (MarketParams, uint256));
        
        if (amount == 0) revert MorphoAdapter__ZeroAmount();

        // Transfer tokens from initiator
        IERC20(marketParams.loanToken).safeTransferFrom(initiator, address(this), amount);
        
        // Approve Morpho
        IERC20(marketParams.loanToken).forceApprove(address(morpho), amount);
        
        // Supply on behalf of initiator
        (uint256 assetsSupplied, uint256 sharesSupplied) = morpho.supply(
            marketParams,
            amount,
            0, // shares
            initiator,
            "" // callback data
        );

        return abi.encode(assetsSupplied, sharesSupplied);
    }

    /// @notice Withdraw loan tokens from Morpho Blue market
    function _executeWithdraw(address initiator, bytes calldata params) internal returns (bytes memory) {
        (MarketParams memory marketParams, uint256 amount) = abi.decode(params, (MarketParams, uint256));
        
        if (amount == 0) revert MorphoAdapter__ZeroAmount();

        // Initiator must have authorized this adapter
        // Withdraw to initiator
        (uint256 assetsWithdrawn, uint256 sharesWithdrawn) = morpho.withdraw(
            marketParams,
            amount,
            0, // shares
            initiator,
            initiator
        );

        return abi.encode(assetsWithdrawn, sharesWithdrawn);
    }

    /// @notice Supply collateral to Morpho Blue market
    function _executeSupplyCollateral(address initiator, bytes calldata params) internal returns (bytes memory) {
        (MarketParams memory marketParams, uint256 amount) = abi.decode(params, (MarketParams, uint256));
        
        if (amount == 0) revert MorphoAdapter__ZeroAmount();

        // Transfer collateral from initiator
        IERC20(marketParams.collateralToken).safeTransferFrom(initiator, address(this), amount);
        
        // Approve Morpho
        IERC20(marketParams.collateralToken).forceApprove(address(morpho), amount);
        
        // Supply collateral on behalf of initiator
        morpho.supplyCollateral(
            marketParams,
            amount,
            initiator,
            "" // callback data
        );

        return abi.encode(amount);
    }

    /// @notice Withdraw collateral from Morpho Blue market
    function _executeWithdrawCollateral(address initiator, bytes calldata params) internal returns (bytes memory) {
        (MarketParams memory marketParams, uint256 amount) = abi.decode(params, (MarketParams, uint256));
        
        if (amount == 0) revert MorphoAdapter__ZeroAmount();

        // Initiator must have authorized this adapter
        // Withdraw collateral to initiator
        morpho.withdrawCollateral(
            marketParams,
            amount,
            initiator,
            initiator
        );

        return abi.encode(amount);
    }

    /// @notice Borrow loan tokens from Morpho Blue market
    function _executeBorrow(address initiator, bytes calldata params) internal returns (bytes memory) {
        (MarketParams memory marketParams, uint256 amount) = abi.decode(params, (MarketParams, uint256));
        
        if (amount == 0) revert MorphoAdapter__ZeroAmount();

        // Initiator must have collateral supplied and authorized this adapter
        // Borrow to initiator
        (uint256 assetsBorrowed, uint256 sharesBorrowed) = morpho.borrow(
            marketParams,
            amount,
            0, // shares
            initiator,
            initiator
        );

        return abi.encode(assetsBorrowed, sharesBorrowed);
    }

    /// @notice Repay borrowed loan tokens
    function _executeRepay(address initiator, bytes calldata params) internal returns (bytes memory) {
        (MarketParams memory marketParams, uint256 amount) = abi.decode(params, (MarketParams, uint256));
        
        if (amount == 0) revert MorphoAdapter__ZeroAmount();

        // Transfer tokens from initiator
        IERC20(marketParams.loanToken).safeTransferFrom(initiator, address(this), amount);
        
        // Approve Morpho
        IERC20(marketParams.loanToken).forceApprove(address(morpho), amount);
        
        // Repay on behalf of initiator
        (uint256 assetsRepaid, uint256 sharesRepaid) = morpho.repay(
            marketParams,
            amount,
            0, // shares
            initiator,
            "" // callback data
        );

        return abi.encode(assetsRepaid, sharesRepaid);
    }
}
