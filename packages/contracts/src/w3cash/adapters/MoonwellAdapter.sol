// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title IMoonwellComptroller
/// @notice Minimal interface for Moonwell Comptroller
interface IMoonwellComptroller {
    function enterMarkets(address[] calldata mTokens) external returns (uint256[] memory);
    function exitMarket(address mToken) external returns (uint256);
    function claimReward() external;
    function claimReward(address holder) external;
}

/// @title IMToken
/// @notice Minimal interface for Moonwell mTokens (Compound-style)
interface IMToken {
    function mint(uint256 mintAmount) external returns (uint256);
    function redeem(uint256 redeemTokens) external returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
    function borrow(uint256 borrowAmount) external returns (uint256);
    function repayBorrow(uint256 repayAmount) external returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function balanceOfUnderlying(address owner) external returns (uint256);
    function underlying() external view returns (address);
    function exchangeRateCurrent() external returns (uint256);
}

/**
 * @title MoonwellAdapter
 * @notice Action adapter for Moonwell lending protocol on Base
 * @dev Supports supply, withdraw, borrow, and repay operations
 */
contract MoonwellAdapter is IAdapter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error MoonwellAdapter__OnlyProcessor();
    error MoonwellAdapter__InvalidOperation();
    error MoonwellAdapter__OperationFailed(uint256 errorCode);
    error MoonwellAdapter__ZeroAmount();
    error MoonwellAdapter__InvalidMarket();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("MoonwellAdapter"));
    
    /// @notice Operation selectors
    bytes4 public constant OP_SUPPLY = 0x47e7ef24; // deposit(address,uint256)
    bytes4 public constant OP_WITHDRAW = 0xf3fef3a3; // withdraw(address,uint256)
    bytes4 public constant OP_BORROW = 0xc5ebeaec; // borrow(uint256)
    bytes4 public constant OP_REPAY = 0x0e752702; // repayBorrow(uint256)
    bytes4 public constant OP_ENTER_MARKET = 0xc2998238; // enterMarkets(address[])
    bytes4 public constant OP_CLAIM = 0x4e71d92d; // claimReward()

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    IMoonwellComptroller public immutable comptroller;
    address public immutable processor;
    
    /// @notice Mapping from underlying token to mToken
    mapping(address => address) public markets;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _comptroller, address _processor) {
        comptroller = IMoonwellComptroller(_comptroller);
        processor = _processor;
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Register a market (underlying -> mToken)
    function registerMarket(address underlying, address mToken) external {
        // In production, this should be access controlled
        markets[underlying] = mToken;
    }

    /*//////////////////////////////////////////////////////////////
                           ADAPTER INTERFACE
    //////////////////////////////////////////////////////////////*/

    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    function execute(address initiator, bytes calldata input) external payable override returns (bytes memory) {
        if (msg.sender != processor) revert MoonwellAdapter__OnlyProcessor();
        if (input.length < 4) revert MoonwellAdapter__InvalidOperation();

        bytes4 operation = bytes4(input[:4]);
        bytes calldata params = input[4:];

        if (operation == OP_SUPPLY) {
            return _executeSupply(initiator, params);
        } else if (operation == OP_WITHDRAW) {
            return _executeWithdraw(initiator, params);
        } else if (operation == OP_BORROW) {
            return _executeBorrow(initiator, params);
        } else if (operation == OP_REPAY) {
            return _executeRepay(initiator, params);
        } else if (operation == OP_ENTER_MARKET) {
            return _executeEnterMarket(initiator, params);
        } else if (operation == OP_CLAIM) {
            return _executeClaim(initiator);
        } else {
            revert MoonwellAdapter__InvalidOperation();
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

    /// @notice Supply tokens to Moonwell
    function _executeSupply(address initiator, bytes calldata params) internal returns (bytes memory) {
        (address token, uint256 amount) = abi.decode(params, (address, uint256));
        
        if (amount == 0) revert MoonwellAdapter__ZeroAmount();
        
        address mToken = markets[token];
        if (mToken == address(0)) revert MoonwellAdapter__InvalidMarket();

        // Transfer tokens from initiator
        IERC20(token).safeTransferFrom(initiator, address(this), amount);
        
        // Approve mToken
        IERC20(token).forceApprove(mToken, amount);
        
        // Mint mTokens (returns 0 on success)
        uint256 error = IMToken(mToken).mint(amount);
        if (error != 0) revert MoonwellAdapter__OperationFailed(error);
        
        // Transfer mTokens to initiator
        uint256 mTokenBalance = IMToken(mToken).balanceOf(address(this));
        IERC20(mToken).safeTransfer(initiator, mTokenBalance);

        return abi.encode(mTokenBalance);
    }

    /// @notice Withdraw tokens from Moonwell
    function _executeWithdraw(address initiator, bytes calldata params) internal returns (bytes memory) {
        (address token, uint256 amount) = abi.decode(params, (address, uint256));
        
        if (amount == 0) revert MoonwellAdapter__ZeroAmount();
        
        address mToken = markets[token];
        if (mToken == address(0)) revert MoonwellAdapter__InvalidMarket();

        // Calculate mTokens needed (use a bit more to ensure we get enough)
        uint256 exchangeRate = IMToken(mToken).exchangeRateCurrent();
        uint256 mTokensNeeded = (amount * 1e18 + exchangeRate - 1) / exchangeRate;
        
        // Transfer mTokens from initiator
        IERC20(mToken).safeTransferFrom(initiator, address(this), mTokensNeeded);
        
        // Redeem underlying
        uint256 error = IMToken(mToken).redeemUnderlying(amount);
        if (error != 0) revert MoonwellAdapter__OperationFailed(error);
        
        // Transfer underlying to initiator
        IERC20(token).safeTransfer(initiator, amount);
        
        // Return any excess mTokens
        uint256 excessMTokens = IERC20(mToken).balanceOf(address(this));
        if (excessMTokens > 0) {
            IERC20(mToken).safeTransfer(initiator, excessMTokens);
        }

        return abi.encode(amount);
    }

    /// @notice Borrow tokens from Moonwell
    function _executeBorrow(address initiator, bytes calldata params) internal returns (bytes memory) {
        (address token, uint256 amount) = abi.decode(params, (address, uint256));
        
        if (amount == 0) revert MoonwellAdapter__ZeroAmount();
        
        address mToken = markets[token];
        if (mToken == address(0)) revert MoonwellAdapter__InvalidMarket();

        // Note: initiator must have collateral deposited and market entered
        // This adapter executes the borrow on behalf of initiator
        
        uint256 error = IMToken(mToken).borrow(amount);
        if (error != 0) revert MoonwellAdapter__OperationFailed(error);
        
        // Transfer borrowed tokens to initiator
        IERC20(token).safeTransfer(initiator, amount);

        return abi.encode(amount);
    }

    /// @notice Repay borrowed tokens
    function _executeRepay(address initiator, bytes calldata params) internal returns (bytes memory) {
        (address token, uint256 amount) = abi.decode(params, (address, uint256));
        
        if (amount == 0) revert MoonwellAdapter__ZeroAmount();
        
        address mToken = markets[token];
        if (mToken == address(0)) revert MoonwellAdapter__InvalidMarket();

        // Transfer tokens from initiator
        IERC20(token).safeTransferFrom(initiator, address(this), amount);
        
        // Approve mToken
        IERC20(token).forceApprove(mToken, amount);
        
        // Repay borrow
        uint256 error = IMToken(mToken).repayBorrow(amount);
        if (error != 0) revert MoonwellAdapter__OperationFailed(error);

        return abi.encode(amount);
    }

    /// @notice Enter a market (enable as collateral)
    function _executeEnterMarket(address, bytes calldata params) internal returns (bytes memory) {
        address[] memory mTokens = abi.decode(params, (address[]));
        
        uint256[] memory errors = comptroller.enterMarkets(mTokens);
        
        for (uint256 i = 0; i < errors.length; i++) {
            if (errors[i] != 0) revert MoonwellAdapter__OperationFailed(errors[i]);
        }

        return abi.encode(true);
    }

    /// @notice Claim WELL rewards
    function _executeClaim(address initiator) internal returns (bytes memory) {
        comptroller.claimReward(initiator);
        return abi.encode(true);
    }
}
