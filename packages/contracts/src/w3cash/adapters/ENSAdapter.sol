// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title IENSRegistrarController
/// @notice Interface for ENS ETHRegistrarController
interface IENSRegistrarController {
    struct Price {
        uint256 base;
        uint256 premium;
    }
    
    function rentPrice(string memory name, uint256 duration) external view returns (Price memory);
    function available(string memory name) external view returns (bool);
    function makeCommitment(
        string memory name,
        address owner,
        uint256 duration,
        bytes32 secret,
        address resolver,
        bytes[] calldata data,
        bool reverseRecord,
        uint16 ownerControlledFuses
    ) external pure returns (bytes32);
    
    function commit(bytes32 commitment) external;
    
    function register(
        string calldata name,
        address owner,
        uint256 duration,
        bytes32 secret,
        address resolver,
        bytes[] calldata data,
        bool reverseRecord,
        uint16 ownerControlledFuses
    ) external payable;
    
    function renew(string calldata name, uint256 duration) external payable;
}

/// @title IENSRegistry
/// @notice Interface for ENS Registry
interface IENSRegistry {
    function setResolver(bytes32 node, address resolver) external;
    function setOwner(bytes32 node, address owner) external;
    function owner(bytes32 node) external view returns (address);
    function resolver(bytes32 node) external view returns (address);
}

/// @title IENSResolver
/// @notice Interface for ENS Public Resolver
interface IENSResolver {
    function setAddr(bytes32 node, address addr) external;
    function setAddr(bytes32 node, uint256 coinType, bytes memory addr) external;
    function setText(bytes32 node, string calldata key, string calldata value) external;
    function setContenthash(bytes32 node, bytes calldata hash) external;
    function addr(bytes32 node) external view returns (address);
    function text(bytes32 node, string calldata key) external view returns (string memory);
}

/**
 * @title ENSAdapter
 * @notice Action adapter for ENS (Ethereum Name Service)
 * @dev Supports registration, renewal, and resolver configuration
 */
contract ENSAdapter is IAdapter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ENSAdapter__OnlyProcessor();
    error ENSAdapter__InvalidOperation();
    error ENSAdapter__NameNotAvailable();
    error ENSAdapter__InsufficientValue();
    error ENSAdapter__RegistrationFailed();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("ENSAdapter"));
    
    /// @notice Operation selectors
    bytes4 public constant OP_COMMIT = 0xf14fcbc8; // commit(bytes32)
    bytes4 public constant OP_REGISTER = 0x74694a2b; // register(...)
    bytes4 public constant OP_RENEW = 0xacf1a841; // renew(string,uint256)
    bytes4 public constant OP_SET_ADDR = 0xd5fa2b00; // setAddr(bytes32,address)
    bytes4 public constant OP_SET_TEXT = 0x10f13a8c; // setText(bytes32,string,string)
    bytes4 public constant OP_SET_RESOLVER = 0x1896f70a; // setResolver(bytes32,address)

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    address public immutable processor;
    IENSRegistrarController public immutable controller;
    IENSRegistry public immutable registry;
    address public immutable publicResolver;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address _processor,
        address _controller,
        address _registry,
        address _publicResolver
    ) {
        processor = _processor;
        controller = IENSRegistrarController(_controller);
        registry = IENSRegistry(_registry);
        publicResolver = _publicResolver;
    }

    /*//////////////////////////////////////////////////////////////
                           ADAPTER INTERFACE
    //////////////////////////////////////////////////////////////*/

    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    function execute(address initiator, bytes calldata input) external payable override returns (bytes memory) {
        if (msg.sender != processor) revert ENSAdapter__OnlyProcessor();
        if (input.length < 4) revert ENSAdapter__InvalidOperation();

        bytes4 operation = bytes4(input[:4]);
        bytes calldata params = input[4:];

        if (operation == OP_COMMIT) {
            return _executeCommit(params);
        } else if (operation == OP_REGISTER) {
            return _executeRegister(initiator, params);
        } else if (operation == OP_RENEW) {
            return _executeRenew(params);
        } else if (operation == OP_SET_ADDR) {
            return _executeSetAddr(params);
        } else if (operation == OP_SET_TEXT) {
            return _executeSetText(params);
        } else if (operation == OP_SET_RESOLVER) {
            return _executeSetResolver(params);
        } else {
            revert ENSAdapter__InvalidOperation();
        }
    }

    function send(bytes memory, uint8, uint64, uint112) external payable override returns (uint64) {
        return 0;
    }

    function estimateFee(uint8, uint112, uint256) external pure override returns (uint256) {
        return 0;
    }

    /// @notice Allow receiving ETH refunds
    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                          INTERNAL OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Submit a commitment hash (step 1 of registration)
    function _executeCommit(bytes calldata params) internal returns (bytes memory) {
        bytes32 commitment = abi.decode(params, (bytes32));
        
        controller.commit(commitment);
        
        return abi.encode(commitment);
    }

    /// @notice Register an ENS name (step 2 of registration, after commitment)
    function _executeRegister(address initiator, bytes calldata params) internal returns (bytes memory) {
        (
            string memory name,
            uint256 duration,
            bytes32 secret,
            bool reverseRecord,
            uint16 ownerControlledFuses
        ) = abi.decode(params, (string, uint256, bytes32, bool, uint16));

        // Check availability
        if (!controller.available(name)) revert ENSAdapter__NameNotAvailable();

        // Get price
        IENSRegistrarController.Price memory price = controller.rentPrice(name, duration);
        uint256 totalPrice = price.base + price.premium;
        
        if (msg.value < totalPrice) revert ENSAdapter__InsufficientValue();

        // Prepare resolver data (empty for now, can be extended)
        bytes[] memory data = new bytes[](0);

        // Register - owner is the initiator
        controller.register{ value: totalPrice }(
            name,
            initiator,
            duration,
            secret,
            publicResolver,
            data,
            reverseRecord,
            ownerControlledFuses
        );

        // Refund excess ETH
        if (msg.value > totalPrice) {
            (bool success, ) = initiator.call{ value: msg.value - totalPrice }("");
            require(success, "Refund failed");
        }

        return abi.encode(true);
    }

    /// @notice Renew an ENS name
    function _executeRenew(bytes calldata params) internal returns (bytes memory) {
        (string memory name, uint256 duration) = abi.decode(params, (string, uint256));

        // Get price
        IENSRegistrarController.Price memory price = controller.rentPrice(name, duration);
        uint256 totalPrice = price.base + price.premium;
        
        if (msg.value < totalPrice) revert ENSAdapter__InsufficientValue();

        // Renew
        controller.renew{ value: totalPrice }(name, duration);

        // Refund excess
        if (msg.value > totalPrice) {
            (bool success, ) = msg.sender.call{ value: msg.value - totalPrice }("");
            require(success, "Refund failed");
        }

        return abi.encode(true);
    }

    /// @notice Set the address record for a name
    function _executeSetAddr(bytes calldata params) internal returns (bytes memory) {
        (bytes32 node, address addr) = abi.decode(params, (bytes32, address));

        address resolver = registry.resolver(node);
        IENSResolver(resolver).setAddr(node, addr);

        return abi.encode(true);
    }

    /// @notice Set a text record for a name
    function _executeSetText(bytes calldata params) internal returns (bytes memory) {
        (bytes32 node, string memory key, string memory value) = abi.decode(params, (bytes32, string, string));

        address resolver = registry.resolver(node);
        IENSResolver(resolver).setText(node, key, value);

        return abi.encode(true);
    }

    /// @notice Set the resolver for a name
    function _executeSetResolver(bytes calldata params) internal returns (bytes memory) {
        (bytes32 node, address resolver) = abi.decode(params, (bytes32, address));

        registry.setResolver(node, resolver);

        return abi.encode(true);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the commitment hash for registration
    function getCommitment(
        string memory name,
        address owner,
        uint256 duration,
        bytes32 secret,
        bool reverseRecord,
        uint16 ownerControlledFuses
    ) external view returns (bytes32) {
        bytes[] memory data = new bytes[](0);
        return controller.makeCommitment(
            name,
            owner,
            duration,
            secret,
            publicResolver,
            data,
            reverseRecord,
            ownerControlledFuses
        );
    }

    /// @notice Get the rent price for a name
    function getRentPrice(string memory name, uint256 duration) external view returns (uint256 base, uint256 premium) {
        IENSRegistrarController.Price memory price = controller.rentPrice(name, duration);
        return (price.base, price.premium);
    }

    /// @notice Check if a name is available
    function isAvailable(string memory name) external view returns (bool) {
        return controller.available(name);
    }
}
