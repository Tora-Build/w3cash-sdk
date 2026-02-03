// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./adapters/interfaces/IAdapter.sol";
import { DataTypes } from "./utils/DataTypes.sol";
import { Errors } from "./utils/Errors.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
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
 */
contract PocaProcessor is Ownable {
    using ECDSA for bytes32;

    // --- State ---
    mapping(uint8 => IAdapter) public adapters;
    mapping(uint8 => uint256) public chains;
    mapping(bytes32 => bool) public authorizedEndpoints;

    // --- Events ---
    event WorkflowPaused(uint256 seq, bytes32 payloadHash);
    event LocalCommandProcessed(uint256 seq, bytes32 payloadHash);
    event CrossChainMessageSent(bytes instruction);
    event AdapterSet(uint8 indexed amb, address adapter);
    event ChainSet(uint8 indexed chain, uint256 chainId);

    // --- Constructor ---
    constructor(address initialOwner) Ownable(initialOwner) {}

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
     */
    function estimateFee(
        uint8 amb, 
        uint8 chain, 
        uint112 value, 
        uint256 gasLimit
    ) external view returns (uint256) {
        return adapters[amb].estimateFee(chain, value, gasLimit);
    }

    // --- Admin Functions ---

    function setAdapter(uint8 amb, address adapter) external onlyOwner {
        adapters[amb] = IAdapter(adapter);
        emit AdapterSet(amb, adapter);
    }

    function setChain(uint8 chain, uint256 chainId) external onlyOwner {
        chains[chain] = chainId;
        emit ChainSet(chain, chainId);
    }

    function setAuthorizedEndpoint(bytes32 endpoint, bool authorized) external onlyOwner {
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

            if (chains[chain] != block.chainid) {
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
        adapters[amb].send{value: msg.value}(dataToSend, chain, fee, value);
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
