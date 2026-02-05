// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title LockAdapter
/// @notice Adapter for time-locking tokens
/// @dev Creates simple time-locks that can be withdrawn after unlock time
contract LockAdapter is IAdapter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error LockAdapter__CallerNotProcessor();
    error LockAdapter__ZeroAmount();
    error LockAdapter__InvalidUnlockTime();
    error LockAdapter__NotUnlocked();
    error LockAdapter__NoLock();
    error LockAdapter__InvalidOperation();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("LockAdapter"));

    /// @notice Operations
    bytes4 public constant OP_LOCK = 0x4c4f434b;     // "LOCK"
    bytes4 public constant OP_UNLOCK = 0x554e4c4b;   // "UNLK"

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    struct Lock {
        address token;
        uint256 amount;
        uint256 unlockTime;
        bool withdrawn;
    }

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The authorized Processor contract
    address public immutable processor;

    /// @notice Mapping of user => lockId => Lock
    mapping(address => mapping(uint256 => Lock)) public locks;

    /// @notice Counter for lock IDs per user
    mapping(address => uint256) public lockCount;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event TokensLocked(
        address indexed user,
        uint256 indexed lockId,
        address token,
        uint256 amount,
        uint256 unlockTime
    );

    event TokensUnlocked(
        address indexed user,
        uint256 indexed lockId,
        address token,
        uint256 amount
    );

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyProcessor() {
        if (msg.sender != processor) revert LockAdapter__CallerNotProcessor();
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

    /// @notice Execute a lock or unlock operation
    /// @param account The account locking/unlocking
    /// @param data ABI encoded based on operation:
    ///        Lock: (bytes4 op=LOCK, address token, uint256 amount, uint256 unlockTime)
    ///        Unlock: (bytes4 op=UNLOCK, uint256 lockId)
    /// @return ABI encoded lockId (for lock) or amount (for unlock)
    function execute(
        address account,
        bytes calldata data
    ) external payable override onlyProcessor returns (bytes memory) {
        bytes4 operation = bytes4(data[:4]);

        if (operation == OP_LOCK) {
            return _lock(account, data[4:]);
        } else if (operation == OP_UNLOCK) {
            return _unlock(account, data[4:]);
        } else {
            revert LockAdapter__InvalidOperation();
        }
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _lock(address account, bytes calldata data) internal returns (bytes memory) {
        (
            address token,
            uint256 amount,
            uint256 unlockTime
        ) = abi.decode(data, (address, uint256, uint256));

        if (amount == 0) revert LockAdapter__ZeroAmount();
        if (unlockTime <= block.timestamp) revert LockAdapter__InvalidUnlockTime();

        // Transfer tokens to adapter
        IERC20(token).safeTransferFrom(account, address(this), amount);

        // Create lock
        uint256 lockId = lockCount[account]++;
        locks[account][lockId] = Lock({
            token: token,
            amount: amount,
            unlockTime: unlockTime,
            withdrawn: false
        });

        emit TokensLocked(account, lockId, token, amount, unlockTime);

        return abi.encode(lockId);
    }

    function _unlock(address account, bytes calldata data) internal returns (bytes memory) {
        uint256 lockId = abi.decode(data, (uint256));

        Lock storage lock = locks[account][lockId];
        if (lock.amount == 0) revert LockAdapter__NoLock();
        if (lock.withdrawn) revert LockAdapter__NoLock();
        if (block.timestamp < lock.unlockTime) revert LockAdapter__NotUnlocked();

        lock.withdrawn = true;
        uint256 amount = lock.amount;
        address token = lock.token;

        // Transfer tokens back to user
        IERC20(token).safeTransfer(account, amount);

        emit TokensUnlocked(account, lockId, token, amount);

        return abi.encode(amount);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get lock details
    function getLock(address account, uint256 lockId) external view returns (Lock memory) {
        return locks[account][lockId];
    }

    /// @notice Check if a lock can be withdrawn
    function canUnlock(address account, uint256 lockId) external view returns (bool) {
        Lock memory lock = locks[account][lockId];
        return !lock.withdrawn && lock.amount > 0 && block.timestamp >= lock.unlockTime;
    }

    /// @inheritdoc IAdapter
    function send(bytes memory, uint8, uint64, uint112) external payable override returns (uint64) {
        revert("LockAdapter: send not supported");
    }

    /// @inheritdoc IAdapter
    function estimateFee(uint8, uint112, uint256) external pure override returns (uint256) {
        return 0;
    }
}
