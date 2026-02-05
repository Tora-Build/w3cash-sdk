// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title IAerodromeRouter
/// @notice Minimal interface for Aerodrome V2 Router on Base
interface IAerodromeRouter {
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }
    
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
    
    function addLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
    
    function removeLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);
    
    function defaultFactory() external view returns (address);
}

/**
 * @title AerodromeAdapter
 * @notice Action adapter for Aerodrome DEX on Base
 * @dev Supports swaps and liquidity operations on Aerodrome V2
 */
contract AerodromeAdapter is IAdapter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error AerodromeAdapter__OnlyProcessor();
    error AerodromeAdapter__InvalidOperation();
    error AerodromeAdapter__SwapFailed();
    error AerodromeAdapter__ZeroAmount();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("AerodromeAdapter"));
    
    /// @notice Operation selectors
    bytes4 public constant OP_SWAP = 0x8119c065; // swap(...)
    bytes4 public constant OP_ADD_LIQUIDITY = 0xe8e33700; // addLiquidity(...)
    bytes4 public constant OP_REMOVE_LIQUIDITY = 0x5e60dab5; // removeLiquidity(...)

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    IAerodromeRouter public immutable router;
    address public immutable processor;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _router, address _processor) {
        router = IAerodromeRouter(_router);
        processor = _processor;
    }

    /*//////////////////////////////////////////////////////////////
                           ADAPTER INTERFACE
    //////////////////////////////////////////////////////////////*/

    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    function execute(address initiator, bytes calldata input) external payable override returns (bytes memory) {
        if (msg.sender != processor) revert AerodromeAdapter__OnlyProcessor();
        if (input.length < 4) revert AerodromeAdapter__InvalidOperation();

        bytes4 operation = bytes4(input[:4]);
        bytes calldata params = input[4:];

        if (operation == OP_SWAP) {
            return _executeSwap(initiator, params);
        } else if (operation == OP_ADD_LIQUIDITY) {
            return _executeAddLiquidity(initiator, params);
        } else if (operation == OP_REMOVE_LIQUIDITY) {
            return _executeRemoveLiquidity(initiator, params);
        } else {
            revert AerodromeAdapter__InvalidOperation();
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

    /// @notice Execute a swap on Aerodrome
    /// @param initiator The account initiating the swap
    /// @param params ABI encoded (tokenIn, tokenOut, amountIn, minAmountOut, stable)
    function _executeSwap(address initiator, bytes calldata params) internal returns (bytes memory) {
        (
            address tokenIn,
            address tokenOut,
            uint256 amountIn,
            uint256 minAmountOut,
            bool stable
        ) = abi.decode(params, (address, address, uint256, uint256, bool));

        if (amountIn == 0) revert AerodromeAdapter__ZeroAmount();

        // Transfer tokens from initiator
        IERC20(tokenIn).safeTransferFrom(initiator, address(this), amountIn);
        
        // Approve router
        IERC20(tokenIn).forceApprove(address(router), amountIn);

        // Build route
        IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](1);
        routes[0] = IAerodromeRouter.Route({
            from: tokenIn,
            to: tokenOut,
            stable: stable,
            factory: router.defaultFactory()
        });

        // Execute swap
        uint256[] memory amounts = router.swapExactTokensForTokens(
            amountIn,
            minAmountOut,
            routes,
            initiator,
            block.timestamp
        );

        return abi.encode(amounts[amounts.length - 1]);
    }

    /// @notice Add liquidity to Aerodrome pool
    /// @param initiator The account adding liquidity
    /// @param params ABI encoded (tokenA, tokenB, amountA, amountB, minA, minB, stable)
    function _executeAddLiquidity(address initiator, bytes calldata params) internal returns (bytes memory) {
        (
            address tokenA,
            address tokenB,
            uint256 amountADesired,
            uint256 amountBDesired,
            uint256 amountAMin,
            uint256 amountBMin,
            bool stable
        ) = abi.decode(params, (address, address, uint256, uint256, uint256, uint256, bool));

        // Transfer tokens
        IERC20(tokenA).safeTransferFrom(initiator, address(this), amountADesired);
        IERC20(tokenB).safeTransferFrom(initiator, address(this), amountBDesired);
        
        // Approve router
        IERC20(tokenA).forceApprove(address(router), amountADesired);
        IERC20(tokenB).forceApprove(address(router), amountBDesired);

        // Add liquidity
        (uint256 amountA, uint256 amountB, uint256 liquidity) = router.addLiquidity(
            tokenA,
            tokenB,
            stable,
            amountADesired,
            amountBDesired,
            amountAMin,
            amountBMin,
            initiator,
            block.timestamp
        );

        // Refund unused tokens
        uint256 unusedA = amountADesired - amountA;
        uint256 unusedB = amountBDesired - amountB;
        if (unusedA > 0) IERC20(tokenA).safeTransfer(initiator, unusedA);
        if (unusedB > 0) IERC20(tokenB).safeTransfer(initiator, unusedB);

        return abi.encode(amountA, amountB, liquidity);
    }

    /// @notice Remove liquidity from Aerodrome pool
    /// @param initiator The account removing liquidity
    /// @param params ABI encoded (tokenA, tokenB, liquidity, minA, minB, stable, lpToken)
    function _executeRemoveLiquidity(address initiator, bytes calldata params) internal returns (bytes memory) {
        (
            address tokenA,
            address tokenB,
            uint256 liquidity,
            uint256 amountAMin,
            uint256 amountBMin,
            bool stable,
            address lpToken
        ) = abi.decode(params, (address, address, uint256, uint256, uint256, bool, address));

        // Transfer LP tokens
        IERC20(lpToken).safeTransferFrom(initiator, address(this), liquidity);
        
        // Approve router
        IERC20(lpToken).forceApprove(address(router), liquidity);

        // Remove liquidity
        (uint256 amountA, uint256 amountB) = router.removeLiquidity(
            tokenA,
            tokenB,
            stable,
            liquidity,
            amountAMin,
            amountBMin,
            initiator,
            block.timestamp
        );

        return abi.encode(amountA, amountB);
    }
}
