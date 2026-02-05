// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { DataTypes } from "../utils/DataTypes.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title SignatureAdapter
/// @notice Condition adapter requiring additional signature(s) to proceed
/// @dev Useful for multisig-like approval flows
contract SignatureAdapter is IAdapter {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error SignatureAdapter__CallerNotProcessor();
    error SignatureAdapter__InvalidSignature();
    error SignatureAdapter__SignatureExpired();
    error SignatureAdapter__SignatureUsed();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("SignatureAdapter"));

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The authorized Processor contract
    address public immutable processor;

    /// @notice Mapping of signature hash => used
    mapping(bytes32 => bool) public usedSignatures;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event SignatureVerified(
        address indexed signer,
        bytes32 indexed messageHash,
        uint256 deadline
    );

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyProcessor() {
        if (msg.sender != processor) revert SignatureAdapter__CallerNotProcessor();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _processor The authorized Processor address
    constructor(address _processor) {
        processor = _processor;
    }

    /*//////////////////////////////////////////////////////////////
                           ADAPTER INTERFACE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAdapter
    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    /// @notice Verify a signature condition
    /// @param account The account executing (used in message hash)
    /// @param data ABI encoded (address requiredSigner, bytes32 actionHash, uint256 deadline, bytes signature)
    ///        requiredSigner: Address that must sign
    ///        actionHash: Hash of the action being authorized
    ///        deadline: Signature expiry timestamp
    ///        signature: ECDSA signature
    /// @return PAUSE_EXECUTION if signature invalid/expired, empty bytes if valid
    function execute(
        address account,
        bytes calldata data
    ) external payable override onlyProcessor returns (bytes memory) {
        (
            address requiredSigner,
            bytes32 actionHash,
            uint256 deadline,
            bytes memory signature
        ) = abi.decode(data, (address, bytes32, uint256, bytes));

        // Check deadline
        if (block.timestamp > deadline) {
            return abi.encode(DataTypes.PAUSE_EXECUTION);
        }

        // Build message hash
        bytes32 messageHash = keccak256(abi.encodePacked(
            account,
            actionHash,
            deadline,
            block.chainid,
            address(this)
        ));

        // Check if signature already used
        bytes32 sigHash = keccak256(signature);
        if (usedSignatures[sigHash]) {
            return abi.encode(DataTypes.PAUSE_EXECUTION);
        }

        // Verify signature
        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();
        address recoveredSigner = ethSignedHash.recover(signature);

        if (recoveredSigner != requiredSigner) {
            return abi.encode(DataTypes.PAUSE_EXECUTION);
        }

        // Mark signature as used
        usedSignatures[sigHash] = true;

        emit SignatureVerified(requiredSigner, messageHash, deadline);

        return "";
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the message hash that needs to be signed
    function getMessageHash(
        address account,
        bytes32 actionHash,
        uint256 deadline
    ) external view returns (bytes32) {
        return keccak256(abi.encodePacked(
            account,
            actionHash,
            deadline,
            block.chainid,
            address(this)
        ));
    }

    /// @notice Check if a signature has been used
    function isSignatureUsed(bytes memory signature) external view returns (bool) {
        return usedSignatures[keccak256(signature)];
    }

    /// @inheritdoc IAdapter
    function send(bytes memory, uint8, uint64, uint112) external payable override returns (uint64) {
        return 0;
    }

    /// @inheritdoc IAdapter
    function estimateFee(uint8, uint112, uint256) external pure override returns (uint256) {
        return 0;
    }
}
