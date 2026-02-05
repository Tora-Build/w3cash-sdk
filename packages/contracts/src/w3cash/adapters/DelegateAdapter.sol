// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";

/// @title IVotesToken
/// @notice Minimal interface for ERC20Votes delegation
interface IVotesToken {
    function delegate(address delegatee) external;
    function delegates(address account) external view returns (address);
}

/// @title DelegateAdapter
/// @notice Adapter for delegating voting power in governance tokens
/// @dev Works with ERC20Votes (Compound-style) delegation
contract DelegateAdapter is IAdapter {

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error DelegateAdapter__CallerNotProcessor();
    error DelegateAdapter__ZeroDelegatee();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("DelegateAdapter"));

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The authorized Processor contract
    address public immutable processor;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyProcessor() {
        if (msg.sender != processor) revert DelegateAdapter__CallerNotProcessor();
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

    /// @notice Execute a delegation
    /// @param account The account delegating (currently unused - user calls token directly)
    /// @param data ABI encoded (address token, address delegatee)
    /// @return ABI encoded delegatee address
    function execute(
        address account,
        bytes calldata data
    ) external payable override onlyProcessor returns (bytes memory) {
        (address token, address delegatee) = abi.decode(data, (address, address));

        if (delegatee == address(0)) revert DelegateAdapter__ZeroDelegatee();

        // Note: This delegates FROM the adapter, not from the user
        // For user-level delegation, the user would need to call the token directly
        // or we'd need a delegateBySig pattern
        
        // For now, this demonstrates the pattern - actual implementation might need
        // the user to approve delegation or use a permit-style signature
        
        // Call delegate on the token
        // In a real scenario, user would hold tokens in this adapter or use delegateBySig
        IVotesToken(token).delegate(delegatee);

        return abi.encode(delegatee);
    }

    /// @inheritdoc IAdapter
    function send(bytes memory, uint8, uint64, uint112) external payable override returns (uint64) {
        revert("DelegateAdapter: send not supported");
    }

    /// @inheritdoc IAdapter
    function estimateFee(uint8, uint112, uint256) external pure override returns (uint256) {
        return 0;
    }
}
