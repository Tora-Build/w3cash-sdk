// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title SwapAdapter
 * @notice Action adapter for token swaps via Uniswap V3 Router
 * @dev Executes exactInputSingle swaps through the configured router
 */
contract SwapAdapter is IAdapter {
    using SafeERC20 for IERC20;

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("SwapAdapter"));
    address public immutable processor;
    address public immutable router;

    error OnlyProcessor();
    error SwapFailed();

    constructor(address _router, address _processor) {
        router = _router;
        processor = _processor;
    }

    /**
     * @notice Execute a token swap
     * @param initiator The address that signed the intent (token source)
     * @param input ABI-encoded SwapParams: (tokenIn, tokenOut, amountIn, minAmountOut, fee)
     * @return ABI-encoded amountOut
     */
    function execute(address initiator, bytes calldata input) external payable override returns (bytes memory) {
        if (msg.sender != processor) revert OnlyProcessor();

        (
            address tokenIn,
            address tokenOut,
            uint256 amountIn,
            uint256 minAmountOut,
            uint24 fee
        ) = abi.decode(input, (address, address, uint256, uint256, uint24));

        // Transfer tokens from initiator to this adapter
        IERC20(tokenIn).safeTransferFrom(initiator, address(this), amountIn);
        
        // Approve router
        IERC20(tokenIn).forceApprove(router, amountIn);

        // Build swap params
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: fee,
            recipient: initiator, // Send output directly to initiator
            amountIn: amountIn,
            amountOutMinimum: minAmountOut,
            sqrtPriceLimitX96: 0
        });

        // Execute swap
        uint256 amountOut = ISwapRouter(router).exactInputSingle(params);
        
        return abi.encode(amountOut);
    }

    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    function send(bytes memory, uint8, uint64, uint112) external payable override returns (uint64) {
        return 0;
    }

    function estimateFee(uint8, uint112, uint256) external pure override returns (uint256) {
        return 0;
    }
}

/// @notice Uniswap V3 SwapRouter interface
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}
