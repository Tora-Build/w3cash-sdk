// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IFlow} from "../core/IFlow.sol";

/// @title SwapFlow
/// @notice Uniswap V3 swap flow
/// @dev Uses Uniswap SwapRouter02 for token swaps
contract SwapFlow is IFlow {
    // Flow identifier: "swap" = 0x73776170
    bytes4 public constant FLOW_ID = 0x73776170;
    
    // Actions
    bytes4 public constant ACTION_SWAP = 0x04e45aaf; // exactInputSingle struct
    
    // Uniswap V3 SwapRouter02 (Universal Router compatible)
    address public immutable SWAP_ROUTER;
    
    // Events
    event Swapped(
        address indexed caller,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    struct SwapParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        uint256 amountIn;
        uint256 amountOutMin;
    }
    
    constructor(address _swapRouter) {
        SWAP_ROUTER = _swapRouter;
    }
    
    /// @inheritdoc IFlow
    function execute(address caller, bytes calldata data) external payable returns (bytes memory) {
        bytes4 action = bytes4(data[:4]);
        
        if (action == ACTION_SWAP) {
            bytes memory params = data[4:];
            return _swap(caller, params);
        }
        
        revert("SwapFlow: unsupported action");
    }
    
    /// @inheritdoc IFlow
    function flowId() external pure returns (bytes4) {
        return FLOW_ID;
    }
    
    /// @inheritdoc IFlow
    function supportsAction(bytes4 action) external pure returns (bool) {
        return action == ACTION_SWAP;
    }
    
    /// @inheritdoc IFlow
    function metadata() external pure returns (string memory, string memory) {
        return ("SwapFlow", "1.0.0");
    }
    
    /// @notice Execute swap
    function _swap(address caller, bytes memory params) internal returns (bytes memory) {
        SwapParams memory p = abi.decode(params, (SwapParams));
        
        // Transfer tokens from caller
        _safeTransferFrom(p.tokenIn, caller, address(this), p.amountIn);
        
        // Approve router
        _safeApprove(p.tokenIn, SWAP_ROUTER, p.amountIn);
        
        // Build ExactInputSingleParams struct for SwapRouter02
        // struct: tokenIn, tokenOut, fee, recipient, amountIn, amountOutMinimum, sqrtPriceLimitX96
        bytes memory swapCall = abi.encodeWithSignature(
            "exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))",
            p.tokenIn, p.tokenOut, p.fee, caller, p.amountIn, p.amountOutMin, uint160(0)
        );
        
        (bool success, bytes memory result) = SWAP_ROUTER.call(swapCall);
        require(success, "SwapFlow: swap failed");
        
        uint256 amountOut = abi.decode(result, (uint256));
        
        emit Swapped(caller, p.tokenIn, p.tokenOut, p.amountIn, amountOut);
        
        return abi.encode(amountOut);
    }
    
    /// @notice Convenience function for direct swaps
    function swap(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 amountOutMin
    ) external returns (uint256 amountOut) {
        SwapParams memory p = SwapParams(tokenIn, tokenOut, fee, amountIn, amountOutMin);
        bytes memory result = _swap(msg.sender, abi.encode(p));
        return abi.decode(result, (uint256));
    }
    
    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool success, ) = token.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, amount)
        );
        require(success, "SwapFlow: transferFrom failed");
    }
    
    function _safeApprove(address token, address spender, uint256 amount) internal {
        (bool success, ) = token.call(
            abi.encodeWithSignature("approve(address,uint256)", spender, amount)
        );
        require(success, "SwapFlow: approve failed");
    }
}
