// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title DataTypes
 * @notice Shared data types for POCA protocol
 */
library DataTypes {
    /**
     * @notice Magic bytes returned by adapters to pause workflow execution
     * @dev When an adapter returns this, the Processor saves state and exits successfully
     */
    bytes32 public constant PAUSE_EXECUTION = keccak256("PAUSE_EXECUTION");

    /**
     * @notice Signed payload for authorized workflow execution
     * @param instruction Encoded workflow (header + payload)
     * @param initiator Address that authorized this workflow
     * @param signature ECDSA signature over the payload hash
     */
    struct SignedPayload {
        bytes instruction;
        address initiator;
        bytes signature;
    }

    /**
     * @notice Supported Arbitrary Message Bridges
     */
    enum AMB {
        WORMHOLE,
        LAYERZERO,
        AXELAR,
        CCTP,
        HYPERLANE
    }

    /**
     * @notice Command structure within a workflow
     * @param chain Target chain ID
     * @param amb Bridge to use for cross-chain
     * @param fee Fee for cross-chain message
     * @param target Target contract address
     * @param selector Function selector (optional)
     * @param value Native value to send
     */
    struct Command {
        uint8 chain;
        uint8 amb;
        uint64 fee;
        address target;
        bytes8 selector;
        uint112 value;
    }
}
