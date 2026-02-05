// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";

/// @title IAdapterRegistry
/// @notice Interface for adapter registry
interface IAdapterRegistry {
    function getAdapter(uint8 adapterId) external view returns (address);
}

/// @title BatchAdapter
/// @notice Meta-adapter for executing multiple adapter calls in sequence
/// @dev Useful for complex flows that need multiple actions in one call
contract BatchAdapter is IAdapter {

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error BatchAdapter__CallerNotProcessor();
    error BatchAdapter__CallFailed(uint256 index);
    error BatchAdapter__EmptyBatch();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("BatchAdapter"));

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The authorized Processor contract
    address public immutable processor;

    /// @notice The adapter registry
    IAdapterRegistry public immutable registry;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyProcessor() {
        if (msg.sender != processor) revert BatchAdapter__CallerNotProcessor();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _processor The authorized Processor address
    /// @param _registry The adapter registry address
    constructor(address _processor, address _registry) {
        processor = _processor;
        registry = IAdapterRegistry(_registry);
    }

    /*//////////////////////////////////////////////////////////////
                           ADAPTER INTERFACE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAdapter
    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    /// @notice Execute multiple adapter calls in sequence
    /// @param account The account executing
    /// @param data ABI encoded (Call[] calls) where Call = (uint8 adapterId, bytes callData)
    /// @return ABI encoded array of results
    function execute(
        address account,
        bytes calldata data
    ) external payable override onlyProcessor returns (bytes memory) {
        (Call[] memory calls) = abi.decode(data, (Call[]));

        if (calls.length == 0) revert BatchAdapter__EmptyBatch();

        bytes[] memory results = new bytes[](calls.length);

        for (uint256 i = 0; i < calls.length; i++) {
            address adapter = registry.getAdapter(calls[i].adapterId);
            
            (bool success, bytes memory result) = adapter.call(
                abi.encodeWithSignature(
                    "execute(address,bytes)",
                    account,
                    calls[i].data
                )
            );

            if (!success) revert BatchAdapter__CallFailed(i);
            
            results[i] = abi.decode(result, (bytes));
        }

        return abi.encode(results);
    }

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    struct Call {
        uint8 adapterId;
        bytes data;
    }

    /// @inheritdoc IAdapter
    function send(bytes memory, uint8, uint64, uint112) external payable override returns (uint64) {
        revert("BatchAdapter: send not supported");
    }

    /// @inheritdoc IAdapter
    function estimateFee(uint8, uint112, uint256) external pure override returns (uint256) {
        return 0;
    }
}
