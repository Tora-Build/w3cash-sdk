// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title Errors
 * @notice Shared error definitions for POCA protocol
 */
library Errors {
    /// @notice Caller is not authorized to execute this action
    error CallerNotAuthorized();
    
    /// @notice Insufficient USDC balance for operation
    error InsufficientUSDCBalance();
    
    /// @notice Invalid instruction format
    error InvalidInstruction();
    
    /// @notice Adapter not found
    error AdapterNotFound();
    
    /// @notice Chain not supported
    error ChainNotSupported();
    
    /// @notice Invalid signature
    error InvalidSignature();
    
    /// @notice Payload hash mismatch
    error PayloadHashMismatch();
}
