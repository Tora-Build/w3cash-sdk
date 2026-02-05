// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Struct for queueing withdrawals
struct QueuedWithdrawalParams {
    address[] strategies;
    uint256[] shares;
    address withdrawer;
}

/// @notice Withdrawal info
struct Withdrawal {
    address staker;
    address delegatedTo;
    address withdrawer;
    uint256 nonce;
    uint32 startBlock;
    address[] strategies;
    uint256[] shares;
}

/// @notice Signature with expiry
struct SignatureWithExpiry {
    bytes signature;
    uint256 expiry;
}

/// @title IEigenLayerStrategyManager
/// @notice Minimal interface for EigenLayer Strategy Manager
interface IEigenLayerStrategyManager {
    function depositIntoStrategy(
        address strategy,
        address token,
        uint256 amount
    ) external returns (uint256 shares);
    
    function stakerStrategyShares(address staker, address strategy) external view returns (uint256);
    function stakerStrategyList(address staker) external view returns (address[] memory);
}

/// @title IEigenLayerDelegationManager
/// @notice Minimal interface for EigenLayer Delegation Manager
interface IEigenLayerDelegationManager {
    function delegateTo(
        address operator,
        SignatureWithExpiry memory approverSignatureAndExpiry,
        bytes32 approverSalt
    ) external;
    
    function undelegate(address staker) external returns (bytes32[] memory withdrawalRoots);
    
    function queueWithdrawals(
        QueuedWithdrawalParams[] calldata queuedWithdrawalParams
    ) external returns (bytes32[] memory);
    
    function completeQueuedWithdrawals(
        Withdrawal[] calldata withdrawals,
        address[][] calldata tokens,
        uint256[] calldata middlewareTimesIndexes,
        bool[] calldata receiveAsTokens
    ) external;
    
    function delegatedTo(address staker) external view returns (address);
    function isDelegated(address staker) external view returns (bool);
    function operatorDetails(address operator) external view returns (
        address earningsReceiver,
        address delegationApprover,
        uint32 stakerOptOutWindowBlocks
    );
}

/// @title IEigenLayerRewardsCoordinator
/// @notice Minimal interface for EigenLayer Rewards Coordinator
interface IEigenLayerRewardsCoordinator {
    struct RewardsMerkleClaim {
        uint32 rootIndex;
        uint32 earnerIndex;
        bytes earnerTreeProof;
        address earnerLeaf;
        uint32[] tokenIndices;
        bytes[] tokenTreeProofs;
        address[] tokenLeaves;
        uint256[] tokenAmounts;
    }
    
    function processClaim(
        RewardsMerkleClaim calldata claim,
        address recipient
    ) external;
}

/**
 * @title EigenLayerAdapter
 * @notice Action adapter for EigenLayer restaking protocol
 * @dev Supports deposit, delegate, withdraw, and rewards claiming
 */
contract EigenLayerAdapter is IAdapter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error EigenLayerAdapter__OnlyProcessor();
    error EigenLayerAdapter__InvalidOperation();
    error EigenLayerAdapter__ZeroAmount();
    error EigenLayerAdapter__InvalidStrategy();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("EigenLayerAdapter"));
    
    /// @notice Operation selectors
    bytes4 public constant OP_DEPOSIT = 0x47e7ef24; // deposit(address,uint256)
    bytes4 public constant OP_DELEGATE = 0x5c19a95c; // delegate(address)
    bytes4 public constant OP_UNDELEGATE = 0xda8be864; // undelegate(address)
    bytes4 public constant OP_QUEUE_WITHDRAWAL = 0x0dd8dd02; // queueWithdrawals(...)
    bytes4 public constant OP_COMPLETE_WITHDRAWAL = 0x60d7faed; // completeQueuedWithdrawals(...)
    bytes4 public constant OP_CLAIM_REWARDS = 0x4e71d92d; // processClaim(...)

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    address public immutable processor;
    IEigenLayerStrategyManager public immutable strategyManager;
    IEigenLayerDelegationManager public immutable delegationManager;
    IEigenLayerRewardsCoordinator public immutable rewardsCoordinator;
    
    /// @notice Mapping from token to strategy
    mapping(address => address) public strategies;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address _processor,
        address _strategyManager,
        address _delegationManager,
        address _rewardsCoordinator
    ) {
        processor = _processor;
        strategyManager = IEigenLayerStrategyManager(_strategyManager);
        delegationManager = IEigenLayerDelegationManager(_delegationManager);
        rewardsCoordinator = IEigenLayerRewardsCoordinator(_rewardsCoordinator);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Register a strategy for a token
    function registerStrategy(address token, address strategy) external {
        // In production, this should be access controlled
        strategies[token] = strategy;
    }

    /*//////////////////////////////////////////////////////////////
                           ADAPTER INTERFACE
    //////////////////////////////////////////////////////////////*/

    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    function execute(address initiator, bytes calldata input) external payable override returns (bytes memory) {
        if (msg.sender != processor) revert EigenLayerAdapter__OnlyProcessor();
        if (input.length < 4) revert EigenLayerAdapter__InvalidOperation();

        bytes4 operation = bytes4(input[:4]);
        bytes calldata params = input[4:];

        if (operation == OP_DEPOSIT) {
            return _executeDeposit(initiator, params);
        } else if (operation == OP_DELEGATE) {
            return _executeDelegate(initiator, params);
        } else if (operation == OP_UNDELEGATE) {
            return _executeUndelegate(initiator, params);
        } else if (operation == OP_QUEUE_WITHDRAWAL) {
            return _executeQueueWithdrawal(initiator, params);
        } else if (operation == OP_COMPLETE_WITHDRAWAL) {
            return _executeCompleteWithdrawal(initiator, params);
        } else if (operation == OP_CLAIM_REWARDS) {
            return _executeClaimRewards(initiator, params);
        } else {
            revert EigenLayerAdapter__InvalidOperation();
        }
    }

    function send(bytes memory, uint8, uint64, uint112) external payable override returns (uint64) {
        return 0;
    }

    function estimateFee(uint8, uint112, uint256) external pure override returns (uint256) {
        return 0;
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit tokens into an EigenLayer strategy
    function _executeDeposit(address initiator, bytes calldata params) internal returns (bytes memory) {
        (address token, uint256 amount) = abi.decode(params, (address, uint256));
        
        if (amount == 0) revert EigenLayerAdapter__ZeroAmount();
        
        address strategy = strategies[token];
        if (strategy == address(0)) revert EigenLayerAdapter__InvalidStrategy();

        // Transfer tokens from initiator
        IERC20(token).safeTransferFrom(initiator, address(this), amount);
        
        // Approve strategy manager
        IERC20(token).forceApprove(address(strategyManager), amount);
        
        // Deposit - shares are credited to the initiator
        // Note: In production, the initiator would need to approve this adapter
        // or use the depositIntoStrategyWithSignature function
        uint256 shares = strategyManager.depositIntoStrategy(strategy, token, amount);

        return abi.encode(shares);
    }

    /// @notice Delegate to an operator
    function _executeDelegate(address initiator, bytes calldata params) internal returns (bytes memory) {
        (
            address operator,
            bytes memory approverSignature,
            uint256 expiry,
            bytes32 approverSalt
        ) = abi.decode(params, (address, bytes, uint256, bytes32));

        SignatureWithExpiry memory sig = SignatureWithExpiry({
            signature: approverSignature,
            expiry: expiry
        });

        // Delegate - initiator must have called this directly or via executor
        delegationManager.delegateTo(operator, sig, approverSalt);

        return abi.encode(true);
    }

    /// @notice Undelegate from operator
    function _executeUndelegate(address initiator, bytes calldata params) internal returns (bytes memory) {
        address staker = abi.decode(params, (address));
        
        bytes32[] memory withdrawalRoots = delegationManager.undelegate(staker);

        return abi.encode(withdrawalRoots);
    }

    /// @notice Queue a withdrawal
    function _executeQueueWithdrawal(address initiator, bytes calldata params) internal returns (bytes memory) {
        QueuedWithdrawalParams[] memory withdrawalParams = abi.decode(params, (QueuedWithdrawalParams[]));

        bytes32[] memory withdrawalRoots = delegationManager.queueWithdrawals(withdrawalParams);

        return abi.encode(withdrawalRoots);
    }

    /// @notice Complete queued withdrawals
    function _executeCompleteWithdrawal(address initiator, bytes calldata params) internal returns (bytes memory) {
        (
            Withdrawal[] memory withdrawals,
            address[][] memory tokens,
            uint256[] memory middlewareTimesIndexes,
            bool[] memory receiveAsTokens
        ) = abi.decode(params, (Withdrawal[], address[][], uint256[], bool[]));

        delegationManager.completeQueuedWithdrawals(
            withdrawals,
            tokens,
            middlewareTimesIndexes,
            receiveAsTokens
        );

        return abi.encode(true);
    }

    /// @notice Claim rewards
    function _executeClaimRewards(address initiator, bytes calldata params) internal returns (bytes memory) {
        IEigenLayerRewardsCoordinator.RewardsMerkleClaim memory claim = 
            abi.decode(params, (IEigenLayerRewardsCoordinator.RewardsMerkleClaim));

        rewardsCoordinator.processClaim(claim, initiator);

        return abi.encode(true);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the shares of a staker in a strategy
    function getShares(address staker, address strategy) external view returns (uint256) {
        return strategyManager.stakerStrategyShares(staker, strategy);
    }

    /// @notice Get the operator a staker is delegated to
    function getDelegatedTo(address staker) external view returns (address) {
        return delegationManager.delegatedTo(staker);
    }

    /// @notice Check if a staker is delegated
    function isDelegated(address staker) external view returns (bool) {
        return delegationManager.isDelegated(staker);
    }
}
