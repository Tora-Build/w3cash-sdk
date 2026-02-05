// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Pendle token input
struct TokenInput {
    address tokenIn;
    uint256 netTokenIn;
    address tokenMintSy;
    address pendleSwap;
    SwapData swapData;
}

/// @notice Pendle token output
struct TokenOutput {
    address tokenOut;
    uint256 minTokenOut;
    address tokenRedeemSy;
    address pendleSwap;
    SwapData swapData;
}

/// @notice Swap data for internal routing
struct SwapData {
    SwapType swapType;
    address extRouter;
    bytes extCalldata;
    bool needScale;
}

enum SwapType {
    NONE,
    KYBERSWAP,
    ONE_INCH,
    ETH_WETH
}

/// @notice Approximation parameters
struct ApproxParams {
    uint256 guessMin;
    uint256 guessMax;
    uint256 guessOffchain;
    uint256 maxIteration;
    uint256 eps;
}

/// @notice Limit order data
struct LimitOrderData {
    address limitRouter;
    uint256 epsSkipMarket;
    FillOrderParams[] normalFills;
    FillOrderParams[] flashFills;
    bytes optData;
}

struct FillOrderParams {
    Order order;
    bytes signature;
    uint256 makingAmount;
}

struct Order {
    uint256 salt;
    uint256 expiry;
    uint256 nonce;
    uint8 orderType;
    address token;
    address YT;
    address maker;
    address receiver;
    uint256 makingAmount;
    uint256 lnImpliedRate;
    uint256 failSafeRate;
    bytes permit;
}

/// @title IPendleRouter
/// @notice Minimal interface for Pendle Router V3
interface IPendleRouter {
    function mintSyFromToken(
        address receiver,
        address SY,
        uint256 minSyOut,
        TokenInput calldata input
    ) external payable returns (uint256 netSyOut);
    
    function redeemSyToToken(
        address receiver,
        address SY,
        uint256 netSyIn,
        TokenOutput calldata output
    ) external returns (uint256 netTokenOut);
    
    function mintPyFromSy(
        address receiver,
        address YT,
        uint256 netSyIn,
        uint256 minPyOut
    ) external returns (uint256 netPyOut);
    
    function redeemPyToSy(
        address receiver,
        address YT,
        uint256 netPyIn,
        uint256 minSyOut
    ) external returns (uint256 netSyOut);
    
    function swapExactTokenForPt(
        address receiver,
        address market,
        uint256 minPtOut,
        ApproxParams calldata guessPtOut,
        TokenInput calldata input,
        LimitOrderData calldata limit
    ) external payable returns (uint256 netPtOut, uint256 netSyFee, uint256 netSyInterm);
    
    function swapExactPtForToken(
        address receiver,
        address market,
        uint256 exactPtIn,
        TokenOutput calldata output,
        LimitOrderData calldata limit
    ) external returns (uint256 netTokenOut, uint256 netSyFee, uint256 netSyInterm);
    
    function swapExactTokenForYt(
        address receiver,
        address market,
        uint256 minYtOut,
        ApproxParams calldata guessYtOut,
        TokenInput calldata input,
        LimitOrderData calldata limit
    ) external payable returns (uint256 netYtOut, uint256 netSyFee, uint256 netSyInterm);
    
    function swapExactYtForToken(
        address receiver,
        address market,
        uint256 exactYtIn,
        TokenOutput calldata output,
        LimitOrderData calldata limit
    ) external returns (uint256 netTokenOut, uint256 netSyFee, uint256 netSyInterm);
    
    function addLiquiditySingleToken(
        address receiver,
        address market,
        uint256 minLpOut,
        ApproxParams calldata guessPtReceivedFromSy,
        TokenInput calldata input,
        LimitOrderData calldata limit
    ) external payable returns (uint256 netLpOut, uint256 netSyFee, uint256 netSyInterm);
    
    function removeLiquiditySingleToken(
        address receiver,
        address market,
        uint256 netLpIn,
        TokenOutput calldata output,
        LimitOrderData calldata limit
    ) external returns (uint256 netTokenOut, uint256 netSyFee, uint256 netSyInterm);
}

/**
 * @title PendleAdapter
 * @notice Action adapter for Pendle Finance yield tokenization
 * @dev Supports PT/YT swaps, liquidity provision, and SY minting
 */
contract PendleAdapter is IAdapter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error PendleAdapter__OnlyProcessor();
    error PendleAdapter__InvalidOperation();
    error PendleAdapter__ZeroAmount();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("PendleAdapter"));
    
    /// @notice Operation selectors
    bytes4 public constant OP_SWAP_TOKEN_FOR_PT = 0x3f3e4c11; // swapExactTokenForPt
    bytes4 public constant OP_SWAP_PT_FOR_TOKEN = 0x7b41e857; // swapExactPtForToken
    bytes4 public constant OP_SWAP_TOKEN_FOR_YT = 0x0a3b46b1; // swapExactTokenForYt
    bytes4 public constant OP_SWAP_YT_FOR_TOKEN = 0x7fcd66ed; // swapExactYtForToken
    bytes4 public constant OP_ADD_LIQUIDITY = 0xa8d5fd65; // addLiquiditySingleToken
    bytes4 public constant OP_REMOVE_LIQUIDITY = 0x5b36389c; // removeLiquiditySingleToken
    bytes4 public constant OP_MINT_SY = 0x93bcabb8; // mintSyFromToken
    bytes4 public constant OP_REDEEM_SY = 0x4782f779; // redeemSyToToken

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    IPendleRouter public immutable router;
    address public immutable processor;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _router, address _processor) {
        router = IPendleRouter(_router);
        processor = _processor;
    }

    /*//////////////////////////////////////////////////////////////
                           ADAPTER INTERFACE
    //////////////////////////////////////////////////////////////*/

    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    function execute(address initiator, bytes calldata input) external payable override returns (bytes memory) {
        if (msg.sender != processor) revert PendleAdapter__OnlyProcessor();
        if (input.length < 4) revert PendleAdapter__InvalidOperation();

        bytes4 operation = bytes4(input[:4]);
        bytes calldata params = input[4:];

        if (operation == OP_SWAP_TOKEN_FOR_PT) {
            return _executeSwapTokenForPt(initiator, params);
        } else if (operation == OP_SWAP_PT_FOR_TOKEN) {
            return _executeSwapPtForToken(initiator, params);
        } else if (operation == OP_SWAP_TOKEN_FOR_YT) {
            return _executeSwapTokenForYt(initiator, params);
        } else if (operation == OP_SWAP_YT_FOR_TOKEN) {
            return _executeSwapYtForToken(initiator, params);
        } else if (operation == OP_ADD_LIQUIDITY) {
            return _executeAddLiquidity(initiator, params);
        } else if (operation == OP_REMOVE_LIQUIDITY) {
            return _executeRemoveLiquidity(initiator, params);
        } else {
            revert PendleAdapter__InvalidOperation();
        }
    }

    function send(bytes memory, uint8, uint64, uint112) external payable override returns (uint64) {
        return 0;
    }

    function estimateFee(uint8, uint112, uint256) external pure override returns (uint256) {
        return 0;
    }

    /// @notice Allow receiving ETH
    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                          INTERNAL OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Swap tokens for PT (Principal Token)
    function _executeSwapTokenForPt(address initiator, bytes calldata params) internal returns (bytes memory) {
        (
            address market,
            address tokenIn,
            uint256 amountIn,
            uint256 minPtOut,
            ApproxParams memory guessPtOut
        ) = abi.decode(params, (address, address, uint256, uint256, ApproxParams));

        if (amountIn == 0) revert PendleAdapter__ZeroAmount();

        // Transfer tokens from initiator
        IERC20(tokenIn).safeTransferFrom(initiator, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(router), amountIn);

        // Build token input
        TokenInput memory input = TokenInput({
            tokenIn: tokenIn,
            netTokenIn: amountIn,
            tokenMintSy: tokenIn,
            pendleSwap: address(0),
            swapData: SwapData({
                swapType: SwapType.NONE,
                extRouter: address(0),
                extCalldata: "",
                needScale: false
            })
        });

        // Empty limit order data
        LimitOrderData memory limit;

        // Execute swap
        (uint256 netPtOut, , ) = router.swapExactTokenForPt(
            initiator,
            market,
            minPtOut,
            guessPtOut,
            input,
            limit
        );

        return abi.encode(netPtOut);
    }

    /// @notice Swap PT for tokens
    function _executeSwapPtForToken(address initiator, bytes calldata params) internal returns (bytes memory) {
        (
            address market,
            address pt,
            address tokenOut,
            uint256 exactPtIn,
            uint256 minTokenOut
        ) = abi.decode(params, (address, address, address, uint256, uint256));

        if (exactPtIn == 0) revert PendleAdapter__ZeroAmount();

        // Transfer PT from initiator
        IERC20(pt).safeTransferFrom(initiator, address(this), exactPtIn);
        IERC20(pt).forceApprove(address(router), exactPtIn);

        // Build token output
        TokenOutput memory output = TokenOutput({
            tokenOut: tokenOut,
            minTokenOut: minTokenOut,
            tokenRedeemSy: tokenOut,
            pendleSwap: address(0),
            swapData: SwapData({
                swapType: SwapType.NONE,
                extRouter: address(0),
                extCalldata: "",
                needScale: false
            })
        });

        // Empty limit order data
        LimitOrderData memory limit;

        // Execute swap
        (uint256 netTokenOut, , ) = router.swapExactPtForToken(
            initiator,
            market,
            exactPtIn,
            output,
            limit
        );

        return abi.encode(netTokenOut);
    }

    /// @notice Swap tokens for YT (Yield Token)
    function _executeSwapTokenForYt(address initiator, bytes calldata params) internal returns (bytes memory) {
        (
            address market,
            address tokenIn,
            uint256 amountIn,
            uint256 minYtOut,
            ApproxParams memory guessYtOut
        ) = abi.decode(params, (address, address, uint256, uint256, ApproxParams));

        if (amountIn == 0) revert PendleAdapter__ZeroAmount();

        // Transfer tokens from initiator
        IERC20(tokenIn).safeTransferFrom(initiator, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(router), amountIn);

        // Build token input
        TokenInput memory input = TokenInput({
            tokenIn: tokenIn,
            netTokenIn: amountIn,
            tokenMintSy: tokenIn,
            pendleSwap: address(0),
            swapData: SwapData({
                swapType: SwapType.NONE,
                extRouter: address(0),
                extCalldata: "",
                needScale: false
            })
        });

        // Empty limit order data
        LimitOrderData memory limit;

        // Execute swap
        (uint256 netYtOut, , ) = router.swapExactTokenForYt(
            initiator,
            market,
            minYtOut,
            guessYtOut,
            input,
            limit
        );

        return abi.encode(netYtOut);
    }

    /// @notice Swap YT for tokens
    function _executeSwapYtForToken(address initiator, bytes calldata params) internal returns (bytes memory) {
        (
            address market,
            address yt,
            address tokenOut,
            uint256 exactYtIn,
            uint256 minTokenOut
        ) = abi.decode(params, (address, address, address, uint256, uint256));

        if (exactYtIn == 0) revert PendleAdapter__ZeroAmount();

        // Transfer YT from initiator
        IERC20(yt).safeTransferFrom(initiator, address(this), exactYtIn);
        IERC20(yt).forceApprove(address(router), exactYtIn);

        // Build token output
        TokenOutput memory output = TokenOutput({
            tokenOut: tokenOut,
            minTokenOut: minTokenOut,
            tokenRedeemSy: tokenOut,
            pendleSwap: address(0),
            swapData: SwapData({
                swapType: SwapType.NONE,
                extRouter: address(0),
                extCalldata: "",
                needScale: false
            })
        });

        // Empty limit order data
        LimitOrderData memory limit;

        // Execute swap
        (uint256 netTokenOut, , ) = router.swapExactYtForToken(
            initiator,
            market,
            exactYtIn,
            output,
            limit
        );

        return abi.encode(netTokenOut);
    }

    /// @notice Add liquidity to a Pendle market
    function _executeAddLiquidity(address initiator, bytes calldata params) internal returns (bytes memory) {
        (
            address market,
            address tokenIn,
            uint256 amountIn,
            uint256 minLpOut,
            ApproxParams memory guessPtReceivedFromSy
        ) = abi.decode(params, (address, address, uint256, uint256, ApproxParams));

        if (amountIn == 0) revert PendleAdapter__ZeroAmount();

        // Transfer tokens from initiator
        IERC20(tokenIn).safeTransferFrom(initiator, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(router), amountIn);

        // Build token input
        TokenInput memory input = TokenInput({
            tokenIn: tokenIn,
            netTokenIn: amountIn,
            tokenMintSy: tokenIn,
            pendleSwap: address(0),
            swapData: SwapData({
                swapType: SwapType.NONE,
                extRouter: address(0),
                extCalldata: "",
                needScale: false
            })
        });

        // Empty limit order data
        LimitOrderData memory limit;

        // Add liquidity
        (uint256 netLpOut, , ) = router.addLiquiditySingleToken(
            initiator,
            market,
            minLpOut,
            guessPtReceivedFromSy,
            input,
            limit
        );

        return abi.encode(netLpOut);
    }

    /// @notice Remove liquidity from a Pendle market
    function _executeRemoveLiquidity(address initiator, bytes calldata params) internal returns (bytes memory) {
        (
            address market,
            address lpToken,
            address tokenOut,
            uint256 netLpIn,
            uint256 minTokenOut
        ) = abi.decode(params, (address, address, address, uint256, uint256));

        if (netLpIn == 0) revert PendleAdapter__ZeroAmount();

        // Transfer LP tokens from initiator
        IERC20(lpToken).safeTransferFrom(initiator, address(this), netLpIn);
        IERC20(lpToken).forceApprove(address(router), netLpIn);

        // Build token output
        TokenOutput memory output = TokenOutput({
            tokenOut: tokenOut,
            minTokenOut: minTokenOut,
            tokenRedeemSy: tokenOut,
            pendleSwap: address(0),
            swapData: SwapData({
                swapType: SwapType.NONE,
                extRouter: address(0),
                extCalldata: "",
                needScale: false
            })
        });

        // Empty limit order data
        LimitOrderData memory limit;

        // Remove liquidity
        (uint256 netTokenOut, , ) = router.removeLiquiditySingleToken(
            initiator,
            market,
            netLpIn,
            output,
            limit
        );

        return abi.encode(netTokenOut);
    }
}
