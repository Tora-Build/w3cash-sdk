// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Single swap params for Balancer
struct SingleSwap {
    bytes32 poolId;
    uint8 kind; // 0 = GIVEN_IN, 1 = GIVEN_OUT
    address assetIn;
    address assetOut;
    uint256 amount;
    bytes userData;
}

/// @notice Batch swap step
struct BatchSwapStep {
    bytes32 poolId;
    uint256 assetInIndex;
    uint256 assetOutIndex;
    uint256 amount;
    bytes userData;
}

/// @notice Fund management params
struct FundManagement {
    address sender;
    bool fromInternalBalance;
    address payable recipient;
    bool toInternalBalance;
}

/// @notice Join pool request
struct JoinPoolRequest {
    address[] assets;
    uint256[] maxAmountsIn;
    bytes userData;
    bool fromInternalBalance;
}

/// @notice Exit pool request
struct ExitPoolRequest {
    address[] assets;
    uint256[] minAmountsOut;
    bytes userData;
    bool toInternalBalance;
}

/// @title IBalancerVault
/// @notice Minimal interface for Balancer V2 Vault
interface IBalancerVault {
    function swap(
        SingleSwap memory singleSwap,
        FundManagement memory funds,
        uint256 limit,
        uint256 deadline
    ) external payable returns (uint256 amountCalculated);
    
    function batchSwap(
        uint8 kind,
        BatchSwapStep[] memory swaps,
        address[] memory assets,
        FundManagement memory funds,
        int256[] memory limits,
        uint256 deadline
    ) external payable returns (int256[] memory assetDeltas);
    
    function joinPool(
        bytes32 poolId,
        address sender,
        address recipient,
        JoinPoolRequest memory request
    ) external payable;
    
    function exitPool(
        bytes32 poolId,
        address sender,
        address payable recipient,
        ExitPoolRequest memory request
    ) external;
    
    function getPoolTokens(bytes32 poolId)
        external
        view
        returns (
            address[] memory tokens,
            uint256[] memory balances,
            uint256 lastChangeBlock
        );
}

/**
 * @title BalancerAdapter
 * @notice Action adapter for Balancer V2 protocol
 * @dev Supports single swaps, batch swaps, join, and exit operations
 */
contract BalancerAdapter is IAdapter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error BalancerAdapter__OnlyProcessor();
    error BalancerAdapter__InvalidOperation();
    error BalancerAdapter__ZeroAmount();
    error BalancerAdapter__SwapFailed();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("BalancerAdapter"));
    
    /// @notice Operation selectors
    bytes4 public constant OP_SWAP = 0x8119c065; // swap(...)
    bytes4 public constant OP_BATCH_SWAP = 0x945bcec9; // batchSwap(...)
    bytes4 public constant OP_JOIN_POOL = 0xb95cac28; // joinPool(...)
    bytes4 public constant OP_EXIT_POOL = 0x8bdb3913; // exitPool(...)

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    IBalancerVault public immutable vault;
    address public immutable processor;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _vault, address _processor) {
        vault = IBalancerVault(_vault);
        processor = _processor;
    }

    /*//////////////////////////////////////////////////////////////
                           ADAPTER INTERFACE
    //////////////////////////////////////////////////////////////*/

    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    function execute(address initiator, bytes calldata input) external payable override returns (bytes memory) {
        if (msg.sender != processor) revert BalancerAdapter__OnlyProcessor();
        if (input.length < 4) revert BalancerAdapter__InvalidOperation();

        bytes4 operation = bytes4(input[:4]);
        bytes calldata params = input[4:];

        if (operation == OP_SWAP) {
            return _executeSwap(initiator, params);
        } else if (operation == OP_JOIN_POOL) {
            return _executeJoinPool(initiator, params);
        } else if (operation == OP_EXIT_POOL) {
            return _executeExitPool(initiator, params);
        } else {
            revert BalancerAdapter__InvalidOperation();
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

    /// @notice Execute a single swap on Balancer
    function _executeSwap(address initiator, bytes calldata params) internal returns (bytes memory) {
        (
            bytes32 poolId,
            address tokenIn,
            address tokenOut,
            uint256 amountIn,
            uint256 minAmountOut
        ) = abi.decode(params, (bytes32, address, address, uint256, uint256));

        if (amountIn == 0) revert BalancerAdapter__ZeroAmount();

        // Transfer tokens from initiator
        IERC20(tokenIn).safeTransferFrom(initiator, address(this), amountIn);
        
        // Approve vault
        IERC20(tokenIn).forceApprove(address(vault), amountIn);

        // Build swap params
        SingleSwap memory singleSwap = SingleSwap({
            poolId: poolId,
            kind: 0, // GIVEN_IN
            assetIn: tokenIn,
            assetOut: tokenOut,
            amount: amountIn,
            userData: ""
        });

        FundManagement memory funds = FundManagement({
            sender: address(this),
            fromInternalBalance: false,
            recipient: payable(initiator),
            toInternalBalance: false
        });

        // Execute swap
        uint256 amountOut = vault.swap(
            singleSwap,
            funds,
            minAmountOut,
            block.timestamp
        );

        return abi.encode(amountOut);
    }

    /// @notice Join a Balancer pool
    function _executeJoinPool(address initiator, bytes calldata params) internal returns (bytes memory) {
        (
            bytes32 poolId,
            address[] memory assets,
            uint256[] memory maxAmountsIn,
            bytes memory userData
        ) = abi.decode(params, (bytes32, address[], uint256[], bytes));

        // Transfer tokens from initiator
        for (uint256 i = 0; i < assets.length; i++) {
            if (maxAmountsIn[i] > 0 && assets[i] != address(0)) {
                IERC20(assets[i]).safeTransferFrom(initiator, address(this), maxAmountsIn[i]);
                IERC20(assets[i]).forceApprove(address(vault), maxAmountsIn[i]);
            }
        }

        JoinPoolRequest memory request = JoinPoolRequest({
            assets: assets,
            maxAmountsIn: maxAmountsIn,
            userData: userData,
            fromInternalBalance: false
        });

        // Join pool - BPT goes to initiator
        vault.joinPool(poolId, address(this), initiator, request);

        // Refund unused tokens
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i] != address(0)) {
                uint256 remaining = IERC20(assets[i]).balanceOf(address(this));
                if (remaining > 0) {
                    IERC20(assets[i]).safeTransfer(initiator, remaining);
                }
            }
        }

        return abi.encode(true);
    }

    /// @notice Exit a Balancer pool
    function _executeExitPool(address initiator, bytes calldata params) internal returns (bytes memory) {
        (
            bytes32 poolId,
            address bptToken,
            uint256 bptAmount,
            address[] memory assets,
            uint256[] memory minAmountsOut,
            bytes memory userData
        ) = abi.decode(params, (bytes32, address, uint256, address[], uint256[], bytes));

        // Transfer BPT from initiator
        IERC20(bptToken).safeTransferFrom(initiator, address(this), bptAmount);
        IERC20(bptToken).forceApprove(address(vault), bptAmount);

        ExitPoolRequest memory request = ExitPoolRequest({
            assets: assets,
            minAmountsOut: minAmountsOut,
            userData: userData,
            toInternalBalance: false
        });

        // Exit pool - tokens go to initiator
        vault.exitPool(poolId, address(this), payable(initiator), request);

        return abi.encode(true);
    }
}
