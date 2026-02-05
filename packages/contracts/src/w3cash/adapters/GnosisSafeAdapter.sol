// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Safe transaction data
struct SafeTransaction {
    address to;
    uint256 value;
    bytes data;
    uint8 operation; // 0 = Call, 1 = DelegateCall
    uint256 safeTxGas;
    uint256 baseGas;
    uint256 gasPrice;
    address gasToken;
    address payable refundReceiver;
    uint256 nonce;
}

/// @title ISafe
/// @notice Minimal interface for Gnosis Safe
interface ISafe {
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures
    ) external payable returns (bool success);
    
    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 nonce
    ) external view returns (bytes32);
    
    function nonce() external view returns (uint256);
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
    function isOwner(address owner) external view returns (bool);
    
    function addOwnerWithThreshold(address owner, uint256 threshold) external;
    function removeOwner(address prevOwner, address owner, uint256 threshold) external;
    function changeThreshold(uint256 threshold) external;
    
    function enableModule(address module) external;
    function disableModule(address prevModule, address module) external;
    function isModuleEnabled(address module) external view returns (bool);
}

/// @title ISafeProxyFactory
/// @notice Interface for Safe Proxy Factory
interface ISafeProxyFactory {
    function createProxyWithNonce(
        address singleton,
        bytes memory initializer,
        uint256 saltNonce
    ) external returns (address proxy);
    
    function createProxy(
        address singleton,
        bytes memory data
    ) external returns (address proxy);
}

/**
 * @title GnosisSafeAdapter
 * @notice Action adapter for Gnosis Safe multisig operations
 * @dev Supports Safe creation, transaction execution, and management
 */
contract GnosisSafeAdapter is IAdapter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error GnosisSafeAdapter__OnlyProcessor();
    error GnosisSafeAdapter__InvalidOperation();
    error GnosisSafeAdapter__ExecutionFailed();
    error GnosisSafeAdapter__InvalidSafe();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("GnosisSafeAdapter"));
    
    /// @notice Operation selectors
    bytes4 public constant OP_CREATE_SAFE = 0x1688f0b9; // createProxy(...)
    bytes4 public constant OP_EXEC_TX = 0x6a761202; // execTransaction(...)
    bytes4 public constant OP_ADD_OWNER = 0x0d582f13; // addOwnerWithThreshold(...)
    bytes4 public constant OP_REMOVE_OWNER = 0xf8dc5dd9; // removeOwner(...)
    bytes4 public constant OP_CHANGE_THRESHOLD = 0x694e80c3; // changeThreshold(...)
    bytes4 public constant OP_ENABLE_MODULE = 0x610b5925; // enableModule(...)

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    address public immutable processor;
    ISafeProxyFactory public immutable proxyFactory;
    address public immutable safeSingleton;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _processor, address _proxyFactory, address _safeSingleton) {
        processor = _processor;
        proxyFactory = ISafeProxyFactory(_proxyFactory);
        safeSingleton = _safeSingleton;
    }

    /*//////////////////////////////////////////////////////////////
                           ADAPTER INTERFACE
    //////////////////////////////////////////////////////////////*/

    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    function execute(address initiator, bytes calldata input) external payable override returns (bytes memory) {
        if (msg.sender != processor) revert GnosisSafeAdapter__OnlyProcessor();
        if (input.length < 4) revert GnosisSafeAdapter__InvalidOperation();

        bytes4 operation = bytes4(input[:4]);
        bytes calldata params = input[4:];

        if (operation == OP_CREATE_SAFE) {
            return _executeCreateSafe(initiator, params);
        } else if (operation == OP_EXEC_TX) {
            return _executeTransaction(params);
        } else if (operation == OP_ADD_OWNER) {
            return _executeAddOwner(params);
        } else if (operation == OP_REMOVE_OWNER) {
            return _executeRemoveOwner(params);
        } else if (operation == OP_CHANGE_THRESHOLD) {
            return _executeChangeThreshold(params);
        } else if (operation == OP_ENABLE_MODULE) {
            return _executeEnableModule(params);
        } else {
            revert GnosisSafeAdapter__InvalidOperation();
        }
    }

    function send(bytes memory, uint8, uint64, uint112) external payable override returns (uint64) {
        return 0;
    }

    function estimateFee(uint8, uint112, uint256) external pure override returns (uint256) {
        return 0;
    }

    /// @notice Allow receiving ETH
    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                          INTERNAL OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new Gnosis Safe
    function _executeCreateSafe(address initiator, bytes calldata params) internal returns (bytes memory) {
        (
            address[] memory owners,
            uint256 threshold,
            address to,
            bytes memory data,
            address fallbackHandler,
            address paymentToken,
            uint256 payment,
            address payable paymentReceiver,
            uint256 saltNonce
        ) = abi.decode(params, (address[], uint256, address, bytes, address, address, uint256, address, uint256));

        // Build initializer data for Safe.setup()
        bytes memory initializer = abi.encodeWithSignature(
            "setup(address[],uint256,address,bytes,address,address,uint256,address)",
            owners,
            threshold,
            to,
            data,
            fallbackHandler,
            paymentToken,
            payment,
            paymentReceiver
        );

        // Create proxy
        address safeProxy = proxyFactory.createProxyWithNonce(
            safeSingleton,
            initializer,
            saltNonce
        );

        return abi.encode(safeProxy);
    }

    /// @notice Execute a transaction on a Safe
    function _executeTransaction(bytes calldata params) internal returns (bytes memory) {
        (
            address safe,
            address to,
            uint256 value,
            bytes memory data,
            uint8 operation,
            uint256 safeTxGas,
            uint256 baseGas,
            uint256 gasPrice,
            address gasToken,
            address payable refundReceiver,
            bytes memory signatures
        ) = abi.decode(params, (address, address, uint256, bytes, uint8, uint256, uint256, uint256, address, address, bytes));

        bool success = ISafe(safe).execTransaction(
            to,
            value,
            data,
            operation,
            safeTxGas,
            baseGas,
            gasPrice,
            gasToken,
            refundReceiver,
            signatures
        );

        if (!success) revert GnosisSafeAdapter__ExecutionFailed();

        return abi.encode(true);
    }

    /// @notice Add an owner to a Safe
    function _executeAddOwner(bytes calldata params) internal returns (bytes memory) {
        (address safe, address owner, uint256 threshold) = abi.decode(params, (address, address, uint256));

        ISafe(safe).addOwnerWithThreshold(owner, threshold);

        return abi.encode(true);
    }

    /// @notice Remove an owner from a Safe
    function _executeRemoveOwner(bytes calldata params) internal returns (bytes memory) {
        (address safe, address prevOwner, address owner, uint256 threshold) = 
            abi.decode(params, (address, address, address, uint256));

        ISafe(safe).removeOwner(prevOwner, owner, threshold);

        return abi.encode(true);
    }

    /// @notice Change the threshold of a Safe
    function _executeChangeThreshold(bytes calldata params) internal returns (bytes memory) {
        (address safe, uint256 threshold) = abi.decode(params, (address, uint256));

        ISafe(safe).changeThreshold(threshold);

        return abi.encode(true);
    }

    /// @notice Enable a module on a Safe
    function _executeEnableModule(bytes calldata params) internal returns (bytes memory) {
        (address safe, address module) = abi.decode(params, (address, address));

        ISafe(safe).enableModule(module);

        return abi.encode(true);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the transaction hash for signing
    function getTransactionHash(
        address safe,
        SafeTransaction memory tx
    ) external view returns (bytes32) {
        return ISafe(safe).getTransactionHash(
            tx.to,
            tx.value,
            tx.data,
            tx.operation,
            tx.safeTxGas,
            tx.baseGas,
            tx.gasPrice,
            tx.gasToken,
            tx.refundReceiver,
            tx.nonce
        );
    }

    /// @notice Get the current nonce of a Safe
    function getNonce(address safe) external view returns (uint256) {
        return ISafe(safe).nonce();
    }

    /// @notice Get the owners of a Safe
    function getOwners(address safe) external view returns (address[] memory) {
        return ISafe(safe).getOwners();
    }

    /// @notice Get the threshold of a Safe
    function getThreshold(address safe) external view returns (uint256) {
        return ISafe(safe).getThreshold();
    }
}
