// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title IConvexBooster
/// @notice Interface for Convex Booster
interface IConvexBooster {
    function deposit(uint256 _pid, uint256 _amount, bool _stake) external returns (bool);
    function withdraw(uint256 _pid, uint256 _amount) external returns (bool);
    function poolInfo(uint256 _pid) external view returns (
        address lptoken,
        address token,
        address gauge,
        address crvRewards,
        address stash,
        bool shutdown
    );
    function poolLength() external view returns (uint256);
}

/// @title IConvexRewardPool
/// @notice Interface for Convex Reward Pool (BaseRewardPool)
interface IConvexRewardPool {
    function stake(uint256 _amount) external returns (bool);
    function withdraw(uint256 _amount, bool claim) external returns (bool);
    function withdrawAndUnwrap(uint256 _amount, bool claim) external returns (bool);
    function getReward(address _account, bool _claimExtras) external returns (bool);
    function balanceOf(address _account) external view returns (uint256);
    function earned(address _account) external view returns (uint256);
    function stakingToken() external view returns (address);
    function rewardToken() external view returns (address);
}

/// @title ICvxLocker
/// @notice Interface for CVX Vote Locker
interface ICvxLocker {
    function lock(address _account, uint256 _amount, uint256 _spendRatio) external;
    function processExpiredLocks(bool _relock) external;
    function withdrawExpiredLocksTo(address _to) external;
    function getReward(address _account, bool _stake) external;
    function lockedBalanceOf(address _user) external view returns (uint256);
}

/**
 * @title ConvexAdapter
 * @notice Action adapter for Convex Finance
 * @dev Supports LP staking, reward claiming, and CVX locking
 */
contract ConvexAdapter is IAdapter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ConvexAdapter__OnlyProcessor();
    error ConvexAdapter__InvalidOperation();
    error ConvexAdapter__ZeroAmount();
    error ConvexAdapter__OperationFailed();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("ConvexAdapter"));
    
    /// @notice Operation selectors
    bytes4 public constant OP_DEPOSIT = 0x47e7ef24; // deposit(address,uint256)
    bytes4 public constant OP_STAKE = 0xa694fc3a; // stake(uint256)
    bytes4 public constant OP_WITHDRAW = 0xf3fef3a3; // withdraw(address,uint256)
    bytes4 public constant OP_CLAIM = 0x4e71d92d; // getReward()
    bytes4 public constant OP_LOCK_CVX = 0x282d3fdf; // lock(...)
    bytes4 public constant OP_UNLOCK_CVX = 0x2f6c493c; // processExpiredLocks(...)

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    address public immutable processor;
    IConvexBooster public immutable booster;
    ICvxLocker public immutable cvxLocker;
    address public immutable cvx;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address _processor,
        address _booster,
        address _cvxLocker,
        address _cvx
    ) {
        processor = _processor;
        booster = IConvexBooster(_booster);
        cvxLocker = ICvxLocker(_cvxLocker);
        cvx = _cvx;
    }

    /*//////////////////////////////////////////////////////////////
                           ADAPTER INTERFACE
    //////////////////////////////////////////////////////////////*/

    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    function execute(address initiator, bytes calldata input) external payable override returns (bytes memory) {
        if (msg.sender != processor) revert ConvexAdapter__OnlyProcessor();
        if (input.length < 4) revert ConvexAdapter__InvalidOperation();

        bytes4 operation = bytes4(input[:4]);
        bytes calldata params = input[4:];

        if (operation == OP_DEPOSIT) {
            return _executeDeposit(initiator, params);
        } else if (operation == OP_STAKE) {
            return _executeStake(initiator, params);
        } else if (operation == OP_WITHDRAW) {
            return _executeWithdraw(initiator, params);
        } else if (operation == OP_CLAIM) {
            return _executeClaim(initiator, params);
        } else if (operation == OP_LOCK_CVX) {
            return _executeLockCvx(initiator, params);
        } else if (operation == OP_UNLOCK_CVX) {
            return _executeUnlockCvx(initiator, params);
        } else {
            revert ConvexAdapter__InvalidOperation();
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

    /// @notice Deposit Curve LP tokens into Convex
    function _executeDeposit(address initiator, bytes calldata params) internal returns (bytes memory) {
        (uint256 pid, address lpToken, uint256 amount, bool stake) = 
            abi.decode(params, (uint256, address, uint256, bool));

        if (amount == 0) revert ConvexAdapter__ZeroAmount();

        // Transfer LP tokens from initiator
        IERC20(lpToken).safeTransferFrom(initiator, address(this), amount);
        IERC20(lpToken).forceApprove(address(booster), amount);

        // Deposit to Convex
        bool success = booster.deposit(pid, amount, stake);
        if (!success) revert ConvexAdapter__OperationFailed();

        // If not staking, transfer cvxLP tokens to initiator
        if (!stake) {
            (, address cvxLpToken, , , , ) = booster.poolInfo(pid);
            uint256 balance = IERC20(cvxLpToken).balanceOf(address(this));
            IERC20(cvxLpToken).safeTransfer(initiator, balance);
        }

        return abi.encode(amount);
    }

    /// @notice Stake cvxLP tokens in reward pool
    function _executeStake(address initiator, bytes calldata params) internal returns (bytes memory) {
        (address rewardPool, address stakingToken, uint256 amount) = 
            abi.decode(params, (address, address, uint256));

        if (amount == 0) revert ConvexAdapter__ZeroAmount();

        // Transfer staking tokens from initiator
        IERC20(stakingToken).safeTransferFrom(initiator, address(this), amount);
        IERC20(stakingToken).forceApprove(rewardPool, amount);

        // Stake in reward pool
        bool success = IConvexRewardPool(rewardPool).stake(amount);
        if (!success) revert ConvexAdapter__OperationFailed();

        return abi.encode(amount);
    }

    /// @notice Withdraw from Convex
    function _executeWithdraw(address initiator, bytes calldata params) internal returns (bytes memory) {
        (address rewardPool, address lpToken, uint256 amount, bool claim) = 
            abi.decode(params, (address, address, uint256, bool));

        if (amount == 0) revert ConvexAdapter__ZeroAmount();

        // Withdraw and unwrap to get Curve LP tokens back
        bool success = IConvexRewardPool(rewardPool).withdrawAndUnwrap(amount, claim);
        if (!success) revert ConvexAdapter__OperationFailed();

        // Transfer LP tokens to initiator
        IERC20(lpToken).safeTransfer(initiator, amount);

        return abi.encode(amount);
    }

    /// @notice Claim rewards from a Convex pool
    function _executeClaim(address initiator, bytes calldata params) internal returns (bytes memory) {
        (address rewardPool, bool claimExtras) = abi.decode(params, (address, bool));

        // Claim rewards
        bool success = IConvexRewardPool(rewardPool).getReward(initiator, claimExtras);
        if (!success) revert ConvexAdapter__OperationFailed();

        return abi.encode(true);
    }

    /// @notice Lock CVX tokens
    function _executeLockCvx(address initiator, bytes calldata params) internal returns (bytes memory) {
        (uint256 amount, uint256 spendRatio) = abi.decode(params, (uint256, uint256));

        if (amount == 0) revert ConvexAdapter__ZeroAmount();

        // Transfer CVX from initiator
        IERC20(cvx).safeTransferFrom(initiator, address(this), amount);
        IERC20(cvx).forceApprove(address(cvxLocker), amount);

        // Lock CVX
        cvxLocker.lock(initiator, amount, spendRatio);

        return abi.encode(amount);
    }

    /// @notice Process expired CVX locks
    function _executeUnlockCvx(address initiator, bytes calldata params) internal returns (bytes memory) {
        bool relock = abi.decode(params, (bool));

        if (relock) {
            cvxLocker.processExpiredLocks(true);
        } else {
            cvxLocker.withdrawExpiredLocksTo(initiator);
        }

        return abi.encode(true);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get pool info by PID
    function getPoolInfo(uint256 pid) external view returns (
        address lptoken,
        address token,
        address gauge,
        address crvRewards,
        address stash,
        bool shutdown
    ) {
        return booster.poolInfo(pid);
    }

    /// @notice Get earned rewards
    function getEarned(address rewardPool, address account) external view returns (uint256) {
        return IConvexRewardPool(rewardPool).earned(account);
    }

    /// @notice Get locked CVX balance
    function getLockedBalance(address account) external view returns (uint256) {
        return cvxLocker.lockedBalanceOf(account);
    }
}
