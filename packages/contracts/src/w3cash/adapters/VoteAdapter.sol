// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";

/// @title IGovernor
/// @notice Minimal interface for OpenZeppelin Governor voting
interface IGovernor {
    function castVote(uint256 proposalId, uint8 support) external returns (uint256);
    function castVoteWithReason(uint256 proposalId, uint8 support, string calldata reason) external returns (uint256);
}

/// @title VoteAdapter
/// @notice Adapter for casting votes in governance proposals
/// @dev Works with OpenZeppelin Governor and compatible contracts
contract VoteAdapter is IAdapter {

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error VoteAdapter__CallerNotProcessor();
    error VoteAdapter__InvalidSupport();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("VoteAdapter"));

    /// @notice Vote options (OpenZeppelin standard)
    uint8 public constant AGAINST = 0;
    uint8 public constant FOR = 1;
    uint8 public constant ABSTAIN = 2;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The authorized Processor contract
    address public immutable processor;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyProcessor() {
        if (msg.sender != processor) revert VoteAdapter__CallerNotProcessor();
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

    /// @notice Execute a vote on a governance proposal
    /// @param account The account voting (unused - adapter votes)
    /// @param data ABI encoded (address governor, uint256 proposalId, uint8 support, string reason)
    ///        support: 0 = Against, 1 = For, 2 = Abstain
    ///        reason: Optional reason string (can be empty)
    /// @return ABI encoded vote weight
    function execute(
        address account,
        bytes calldata data
    ) external payable override onlyProcessor returns (bytes memory) {
        (
            address governor,
            uint256 proposalId,
            uint8 support,
            string memory reason
        ) = abi.decode(data, (address, uint256, uint8, string));

        if (support > ABSTAIN) revert VoteAdapter__InvalidSupport();

        uint256 weight;

        if (bytes(reason).length > 0) {
            weight = IGovernor(governor).castVoteWithReason(proposalId, support, reason);
        } else {
            weight = IGovernor(governor).castVote(proposalId, support);
        }

        return abi.encode(weight);
    }

    /// @inheritdoc IAdapter
    function send(bytes memory, uint8, uint64, uint112) external payable override returns (uint64) {
        revert("VoteAdapter: send not supported");
    }

    /// @inheritdoc IAdapter
    function estimateFee(uint8, uint112, uint256) external pure override returns (uint256) {
        return 0;
    }
}
