// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapterRegistry } from "./interfaces/IAdapterRegistry.sol";
import { IAdapter } from "./adapters/interfaces/IAdapter.sol";
import { DataTypes } from "./utils/DataTypes.sol";
import { Errors } from "./utils/Errors.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

/**
 * @title PocaProcessor
 * @notice Protocol Oriented Chain Abstraction - Core processor for resumable workflows
 * @dev Executes signed payloads with PAUSE_EXECUTION support for conditional/scheduled actions
 *
 * Key features:
 * - SignedPayload verification (user signs once, execution can happen later)
 * - PAUSE_EXECUTION pattern (non-reverting condition checks)
 * - Adapter-based architecture (WaitAdapter, SwapAdapter, etc.)
 * - Cross-chain support via AMB adapters
 *
 * Trust Model:
 * - This contract is IMMUTABLE (no admin functions, no Ownable)
 * - Cross-chain: AMB adapter and chain lookups go through AdapterRegistry
 * - Local: Adapter addresses are user-specified in signed payloads (user's authorization)
 * - Security depends on user signatures + registry's freeze mechanism
 * - See docs/POCA_SECURITY_MODEL.md for full trust model
 */
contract PocaProcessor {
    using ECDSA for bytes32;

    // --- Immutable State ---

    /// @notice External registry for adapter and chain lookups (set once at deploy)
    IAdapterRegistry public immutable registry;

    // --- Mutable State ---

    /// @notice Authorized cross-chain endpoints (for receiving messages)
    mapping(bytes32 => bool) public authorizedEndpoints;

    // --- Events ---
    event WorkflowPaused(uint256 seq, bytes32 payloadHash);
    event LocalCommandProcessed(uint256 seq, bytes32 payloadHash);
    event CrossChainMessageSent(bytes instruction);

    // --- Constructor ---

    /**
     * @notice Deploy immutable processor with registry reference
     * @param _registry AdapterRegistry contract address
     */
    constructor(address _registry) {
        require(_registry != address(0), "Invalid registry");
        registry = IAdapterRegistry(_registry);
    }

    receive() external payable {}

    // --- Public Functions ---

    /**
     * @notice Execute a signed payload
     * @param encodedSignedPayload ABI-encoded SignedPayload struct
     */
    function execute(bytes memory encodedSignedPayload) external payable {
        DataTypes.SignedPayload memory sp = abi.decode(
            encodedSignedPayload, 
            (DataTypes.SignedPayload)
        );
        _verifySignature(sp);
        _execute(sp.instruction, sp.initiator, sp.signature);
    }

    /**
     * @notice Get fee estimate for cross-chain execution
     * @param amb AMB adapter ID
     * @param chain Target chain index
     * @param value Value to send
     * @param gasLimit Gas limit for execution
     * @return Fee estimate in native currency
     */
    function estimateFee(
        uint8 amb,
        uint8 chain,
        uint112 value,
        uint256 gasLimit
    ) external view returns (uint256) {
        return registry.getAdapter(amb).estimateFee(chain, value, gasLimit);
    }

    /**
     * @notice Set authorized endpoint for cross-chain message reception
     * @dev This is the only mutable state - required for cross-chain security
     * @param endpoint Endpoint hash to authorize/deauthorize
     * @param authorized Whether the endpoint is authorized
     */
    function setAuthorizedEndpoint(bytes32 endpoint, bool authorized) external {
        // Only the registry owner can set authorized endpoints
        // This maintains admin control for cross-chain security while keeping processor immutable
        require(msg.sender == registry.owner(), "Only registry owner");
        authorizedEndpoints[endpoint] = authorized;
    }

    // --- Internal Functions ---

    function _verifySignature(DataTypes.SignedPayload memory sp) internal view {
        (, bytes memory payload) = _splitHeaderAndPayload(sp.instruction);
        bytes32 payloadHash = keccak256(payload);
        
        address recovered = ECDSA.recover(
            MessageHashUtils.toEthSignedMessageHash(payloadHash), 
            sp.signature
        );
        
        if (recovered != sp.initiator) revert Errors.CallerNotAuthorized();
    }

    function _execute(
        bytes memory instruction, 
        address initiator, 
        bytes memory signature
    ) internal {
        (bytes memory header, bytes memory payload) = _splitHeaderAndPayload(instruction);
        (uint256 seq, uint256 length, bytes32 payloadHash) = _decodeHeader(header);

        require(keccak256(payload) == payloadHash, "Invalid payload hash");

        (bytes[] memory operations, bytes[] memory inputs) = _splitPayload(payload);

        for (; seq < length;) {
            (
                uint8 chain,
                uint8 amb,
                uint64 fee,
                address targetAddress,
                , // selector (unused)
                uint112 value
            ) = abi.decode(
                operations[seq], 
                (uint8, uint8, uint64, address, bytes8, uint112)
            );

            if (registry.getChain(chain) != block.chainid) {
                // Cross-chain: forward to AMB adapter
                _sendCrossChainMessage(
                    instruction, initiator, signature, 
                    seq, chain, amb, fee, value
                );
                emit CrossChainMessageSent(instruction);
                break;
            } else {
                // Local: execute through adapter
                bytes memory result = IAdapter(targetAddress).execute{value: value}(
                    initiator, 
                    inputs[seq]
                );

                // Check for PAUSE_EXECUTION
                if (keccak256(result) == keccak256(abi.encode(DataTypes.PAUSE_EXECUTION))) {
                    emit WorkflowPaused(seq, payloadHash);
                    return; // Exit successfully, allowing resumption later
                }

                emit LocalCommandProcessed(seq, payloadHash);

                unchecked { ++seq; }
            }
        }
    }

    function _sendCrossChainMessage(
        bytes memory instruction,
        address initiator,
        bytes memory signature,
        uint256 seq,
        uint8 chain,
        uint8 amb,
        uint64 fee,
        uint112 value
    ) internal {
        bytes memory updatedInstruction = _updateHeader(instruction, seq);

        DataTypes.SignedPayload memory sp = DataTypes.SignedPayload({
            instruction: updatedInstruction,
            initiator: initiator,
            signature: signature
        });
        
        bytes memory dataToSend = abi.encode(sp);
        registry.getAdapter(amb).send{value: msg.value}(dataToSend, chain, fee, value);
    }

    // --- Encoding/Decoding Helpers ---

    function _splitHeaderAndPayload(bytes memory input)
        internal pure returns (bytes memory header, bytes memory payload)
    {
        (header, payload) = abi.decode(input, (bytes, bytes));
    }

    function _decodeHeader(bytes memory header)
        internal pure returns (uint256 seq, uint256 length, bytes32 payloadHash)
    {
        (seq, length, payloadHash) = abi.decode(header, (uint256, uint256, bytes32));
    }

    function _splitPayload(bytes memory payload)
        internal pure returns (bytes[] memory commands, bytes[] memory inputs)
    {
        (commands, inputs) = abi.decode(payload, (bytes[], bytes[]));
    }

    function _updateHeader(bytes memory instruction, uint256 seq)
        internal pure returns (bytes memory)
    {
        assembly {
            let headerOffset := mload(add(instruction, 0x20))
            let headerLenPtr := add(add(instruction, 0x20), headerOffset)
            let seqPtr := add(headerLenPtr, 0x20)
            mstore(seqPtr, seq)
        }
        return instruction;
    }
}
