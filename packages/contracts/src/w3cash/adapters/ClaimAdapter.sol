// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IAaveRewardsController
/// @notice Interface for Aave V3 rewards
interface IAaveRewardsController {
    function claimAllRewards(
        address[] calldata assets,
        address to
    ) external returns (address[] memory rewardsList, uint256[] memory claimedAmounts);
    
    function claimRewards(
        address[] calldata assets,
        uint256 amount,
        address to,
        address reward
    ) external returns (uint256);
}

/// @title ClaimAdapter
/// @notice Adapter for claiming rewards from various protocols
/// @dev Supports Aave rewards and generic reward claiming
contract ClaimAdapter is IAdapter {

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ClaimAdapter__CallerNotProcessor();
    error ClaimAdapter__InvalidProtocol();
    error ClaimAdapter__ClaimFailed();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("ClaimAdapter"));

    /// @notice Protocol identifiers
    uint8 public constant PROTOCOL_AAVE = 0;
    uint8 public constant PROTOCOL_GENERIC = 1;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The authorized Processor contract
    address public immutable processor;

    /// @notice Aave V3 rewards controller (optional)
    address public aaveRewardsController;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyProcessor() {
        if (msg.sender != processor) revert ClaimAdapter__CallerNotProcessor();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _processor The authorized Processor address
    /// @param _aaveRewardsController The Aave rewards controller (can be zero)
    constructor(address _processor, address _aaveRewardsController) {
        processor = _processor;
        aaveRewardsController = _aaveRewardsController;
    }

    /*//////////////////////////////////////////////////////////////
                           ADAPTER INTERFACE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAdapter
    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    /// @notice Execute a claim operation
    /// @param account The account claiming rewards
    /// @param data Protocol-specific encoded data
    ///        For AAVE: (uint8 protocol, address[] assets)
    ///        For GENERIC: (uint8 protocol, address target, bytes callData)
    /// @return ABI encoded result (varies by protocol)
    function execute(
        address account,
        bytes calldata data
    ) external payable override onlyProcessor returns (bytes memory) {
        uint8 protocol = uint8(data[0]);

        if (protocol == PROTOCOL_AAVE) {
            return _claimAave(account, data[1:]);
        } else if (protocol == PROTOCOL_GENERIC) {
            return _claimGeneric(data[1:]);
        } else {
            revert ClaimAdapter__InvalidProtocol();
        }
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Claim Aave rewards
    function _claimAave(address account, bytes calldata data) internal returns (bytes memory) {
        address[] memory assets = abi.decode(data, (address[]));

        (
            address[] memory rewardsList,
            uint256[] memory claimedAmounts
        ) = IAaveRewardsController(aaveRewardsController).claimAllRewards(assets, account);

        return abi.encode(rewardsList, claimedAmounts);
    }

    /// @notice Generic claim via arbitrary call
    function _claimGeneric(bytes calldata data) internal returns (bytes memory) {
        (address target, bytes memory callData) = abi.decode(data, (address, bytes));

        (bool success, bytes memory result) = target.call(callData);
        if (!success) revert ClaimAdapter__ClaimFailed();

        return result;
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Update Aave rewards controller
    function setAaveRewardsController(address _controller) external {
        // In production, add access control
        aaveRewardsController = _controller;
    }

    /// @inheritdoc IAdapter
    function send(bytes memory, uint8, uint64, uint112) external payable override returns (uint64) {
        revert("ClaimAdapter: send not supported");
    }

    /// @inheritdoc IAdapter
    function estimateFee(uint8, uint112, uint256) external pure override returns (uint256) {
        return 0;
    }
}
