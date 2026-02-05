// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title ICurvePool
/// @notice Minimal interface for Curve pools (stable pools)
interface ICurvePool {
    function exchange(
        int128 i,
        int128 j,
        uint256 dx,
        uint256 min_dy
    ) external returns (uint256);
    
    function exchange_underlying(
        int128 i,
        int128 j,
        uint256 dx,
        uint256 min_dy
    ) external returns (uint256);
    
    function add_liquidity(
        uint256[2] calldata amounts,
        uint256 min_mint_amount
    ) external returns (uint256);
    
    function add_liquidity(
        uint256[3] calldata amounts,
        uint256 min_mint_amount
    ) external returns (uint256);
    
    function add_liquidity(
        uint256[4] calldata amounts,
        uint256 min_mint_amount
    ) external returns (uint256);
    
    function remove_liquidity(
        uint256 amount,
        uint256[2] calldata min_amounts
    ) external returns (uint256[2] memory);
    
    function remove_liquidity_one_coin(
        uint256 token_amount,
        int128 i,
        uint256 min_amount
    ) external returns (uint256);
    
    function coins(uint256 i) external view returns (address);
    function balances(uint256 i) external view returns (uint256);
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
}

/// @title ICurveRouter
/// @notice Interface for Curve Router (for complex routes)
interface ICurveRouter {
    function exchange(
        address[11] calldata route,
        uint256[5][5] calldata swap_params,
        uint256 amount,
        uint256 expected
    ) external returns (uint256);
}

/**
 * @title CurveAdapter
 * @notice Action adapter for Curve Finance
 * @dev Supports swaps and liquidity operations on Curve pools
 */
contract CurveAdapter is IAdapter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error CurveAdapter__OnlyProcessor();
    error CurveAdapter__InvalidOperation();
    error CurveAdapter__ZeroAmount();
    error CurveAdapter__SwapFailed();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("CurveAdapter"));
    
    /// @notice Operation selectors
    bytes4 public constant OP_SWAP = 0x8119c065; // swap(...)
    bytes4 public constant OP_ADD_LIQUIDITY_2 = 0x0b4c7e4d; // add_liquidity (2 tokens)
    bytes4 public constant OP_ADD_LIQUIDITY_3 = 0x4515cef3; // add_liquidity (3 tokens)
    bytes4 public constant OP_REMOVE_LIQUIDITY = 0x5b36389c; // remove_liquidity
    bytes4 public constant OP_REMOVE_ONE_COIN = 0x1a4d01d2; // remove_liquidity_one_coin

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    address public immutable processor;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _processor) {
        processor = _processor;
    }

    /*//////////////////////////////////////////////////////////////
                           ADAPTER INTERFACE
    //////////////////////////////////////////////////////////////*/

    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    function execute(address initiator, bytes calldata input) external payable override returns (bytes memory) {
        if (msg.sender != processor) revert CurveAdapter__OnlyProcessor();
        if (input.length < 4) revert CurveAdapter__InvalidOperation();

        bytes4 operation = bytes4(input[:4]);
        bytes calldata params = input[4:];

        if (operation == OP_SWAP) {
            return _executeSwap(initiator, params);
        } else if (operation == OP_ADD_LIQUIDITY_2) {
            return _executeAddLiquidity2(initiator, params);
        } else if (operation == OP_ADD_LIQUIDITY_3) {
            return _executeAddLiquidity3(initiator, params);
        } else if (operation == OP_REMOVE_LIQUIDITY) {
            return _executeRemoveLiquidity(initiator, params);
        } else if (operation == OP_REMOVE_ONE_COIN) {
            return _executeRemoveOneCoin(initiator, params);
        } else {
            revert CurveAdapter__InvalidOperation();
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

    /// @notice Execute a swap on a Curve pool
    function _executeSwap(address initiator, bytes calldata params) internal returns (bytes memory) {
        (
            address pool,
            address tokenIn,
            address tokenOut,
            int128 i,
            int128 j,
            uint256 amountIn,
            uint256 minAmountOut,
            bool useUnderlying
        ) = abi.decode(params, (address, address, address, int128, int128, uint256, uint256, bool));

        if (amountIn == 0) revert CurveAdapter__ZeroAmount();

        // Transfer tokens from initiator
        IERC20(tokenIn).safeTransferFrom(initiator, address(this), amountIn);
        
        // Approve pool
        IERC20(tokenIn).forceApprove(pool, amountIn);

        // Execute swap
        uint256 amountOut;
        if (useUnderlying) {
            amountOut = ICurvePool(pool).exchange_underlying(i, j, amountIn, minAmountOut);
        } else {
            amountOut = ICurvePool(pool).exchange(i, j, amountIn, minAmountOut);
        }

        // Transfer output to initiator
        IERC20(tokenOut).safeTransfer(initiator, amountOut);

        return abi.encode(amountOut);
    }

    /// @notice Add liquidity to a 2-token Curve pool
    function _executeAddLiquidity2(address initiator, bytes calldata params) internal returns (bytes memory) {
        (
            address pool,
            address lpToken,
            address[2] memory tokens,
            uint256[2] memory amounts,
            uint256 minMintAmount
        ) = abi.decode(params, (address, address, address[2], uint256[2], uint256));

        // Transfer tokens and approve
        for (uint256 k = 0; k < 2; k++) {
            if (amounts[k] > 0) {
                IERC20(tokens[k]).safeTransferFrom(initiator, address(this), amounts[k]);
                IERC20(tokens[k]).forceApprove(pool, amounts[k]);
            }
        }

        // Add liquidity
        uint256 lpReceived = ICurvePool(pool).add_liquidity(amounts, minMintAmount);

        // Transfer LP tokens to initiator
        IERC20(lpToken).safeTransfer(initiator, lpReceived);

        return abi.encode(lpReceived);
    }

    /// @notice Add liquidity to a 3-token Curve pool
    function _executeAddLiquidity3(address initiator, bytes calldata params) internal returns (bytes memory) {
        (
            address pool,
            address lpToken,
            address[3] memory tokens,
            uint256[3] memory amounts,
            uint256 minMintAmount
        ) = abi.decode(params, (address, address, address[3], uint256[3], uint256));

        // Transfer tokens and approve
        for (uint256 k = 0; k < 3; k++) {
            if (amounts[k] > 0) {
                IERC20(tokens[k]).safeTransferFrom(initiator, address(this), amounts[k]);
                IERC20(tokens[k]).forceApprove(pool, amounts[k]);
            }
        }

        // Add liquidity
        uint256 lpReceived = ICurvePool(pool).add_liquidity(amounts, minMintAmount);

        // Transfer LP tokens to initiator
        IERC20(lpToken).safeTransfer(initiator, lpReceived);

        return abi.encode(lpReceived);
    }

    /// @notice Remove liquidity from a 2-token Curve pool
    function _executeRemoveLiquidity(address initiator, bytes calldata params) internal returns (bytes memory) {
        (
            address pool,
            address lpToken,
            address[2] memory tokens,
            uint256 lpAmount,
            uint256[2] memory minAmounts
        ) = abi.decode(params, (address, address, address[2], uint256, uint256[2]));

        // Transfer LP tokens
        IERC20(lpToken).safeTransferFrom(initiator, address(this), lpAmount);
        IERC20(lpToken).forceApprove(pool, lpAmount);

        // Remove liquidity
        uint256[2] memory receivedAmounts = ICurvePool(pool).remove_liquidity(lpAmount, minAmounts);

        // Transfer tokens to initiator
        for (uint256 k = 0; k < 2; k++) {
            if (receivedAmounts[k] > 0) {
                IERC20(tokens[k]).safeTransfer(initiator, receivedAmounts[k]);
            }
        }

        return abi.encode(receivedAmounts[0], receivedAmounts[1]);
    }

    /// @notice Remove liquidity in a single coin
    function _executeRemoveOneCoin(address initiator, bytes calldata params) internal returns (bytes memory) {
        (
            address pool,
            address lpToken,
            address tokenOut,
            uint256 lpAmount,
            int128 coinIndex,
            uint256 minAmount
        ) = abi.decode(params, (address, address, address, uint256, int128, uint256));

        // Transfer LP tokens
        IERC20(lpToken).safeTransferFrom(initiator, address(this), lpAmount);
        IERC20(lpToken).forceApprove(pool, lpAmount);

        // Remove liquidity
        uint256 received = ICurvePool(pool).remove_liquidity_one_coin(lpAmount, coinIndex, minAmount);

        // Transfer token to initiator
        IERC20(tokenOut).safeTransfer(initiator, received);

        return abi.encode(received);
    }
}
