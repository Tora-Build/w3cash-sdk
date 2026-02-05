// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title INonfungiblePositionManager
/// @notice Minimal interface for Uniswap V3 position manager
interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    function mint(MintParams calldata params)
        external
        payable
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        );

    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        payable
        returns (
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        );
}

/// @title AddLiquidityAdapter
/// @notice Adapter for adding liquidity to Uniswap V3
/// @dev Supports both new position creation and adding to existing positions
contract AddLiquidityAdapter is IAdapter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error AddLiquidityAdapter__CallerNotProcessor();
    error AddLiquidityAdapter__ZeroAmount();
    error AddLiquidityAdapter__InvalidOperation();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("AddLiquidityAdapter"));

    /// @notice Operations
    uint8 public constant OP_MINT = 0;     // Create new position
    uint8 public constant OP_INCREASE = 1; // Add to existing position

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Uniswap V3 Position Manager
    INonfungiblePositionManager public immutable positionManager;

    /// @notice The authorized Processor contract
    address public immutable processor;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyProcessor() {
        if (msg.sender != processor) revert AddLiquidityAdapter__CallerNotProcessor();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _positionManager The Uniswap V3 Position Manager address
    /// @param _processor The authorized Processor address
    constructor(address _positionManager, address _processor) {
        positionManager = INonfungiblePositionManager(_positionManager);
        processor = _processor;
    }

    /*//////////////////////////////////////////////////////////////
                           ADAPTER INTERFACE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAdapter
    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    /// @notice Add liquidity to Uniswap V3
    /// @param account The account adding liquidity
    /// @param data ABI encoded based on operation:
    ///        MINT: (uint8 op, address token0, address token1, uint24 fee, int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1, uint256 amount0Min, uint256 amount1Min)
    ///        INCREASE: (uint8 op, uint256 tokenId, uint256 amount0, uint256 amount1, uint256 amount0Min, uint256 amount1Min)
    /// @return ABI encoded result (tokenId, liquidity, amount0, amount1)
    function execute(
        address account,
        bytes calldata data
    ) external payable override onlyProcessor returns (bytes memory) {
        uint8 operation = uint8(data[0]);

        if (operation == OP_MINT) {
            return _mint(account, data[1:]);
        } else if (operation == OP_INCREASE) {
            return _increase(account, data[1:]);
        } else {
            revert AddLiquidityAdapter__InvalidOperation();
        }
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _mint(address account, bytes calldata data) internal returns (bytes memory) {
        (
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint256 amount0Desired,
            uint256 amount1Desired,
            uint256 amount0Min,
            uint256 amount1Min
        ) = abi.decode(data, (address, address, uint24, int24, int24, uint256, uint256, uint256, uint256));

        if (amount0Desired == 0 && amount1Desired == 0) revert AddLiquidityAdapter__ZeroAmount();

        // Transfer tokens from user
        if (amount0Desired > 0) {
            IERC20(token0).safeTransferFrom(account, address(this), amount0Desired);
            IERC20(token0).forceApprove(address(positionManager), amount0Desired);
        }
        if (amount1Desired > 0) {
            IERC20(token1).safeTransferFrom(account, address(this), amount1Desired);
            IERC20(token1).forceApprove(address(positionManager), amount1Desired);
        }

        // Mint position
        (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        ) = positionManager.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: fee,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                recipient: account,
                deadline: block.timestamp + 300
            })
        );

        // Refund unused tokens
        if (amount0Desired > amount0) {
            IERC20(token0).safeTransfer(account, amount0Desired - amount0);
        }
        if (amount1Desired > amount1) {
            IERC20(token1).safeTransfer(account, amount1Desired - amount1);
        }

        return abi.encode(tokenId, liquidity, amount0, amount1);
    }

    function _increase(address account, bytes calldata data) internal returns (bytes memory) {
        (
            uint256 tokenId,
            address token0,
            address token1,
            uint256 amount0Desired,
            uint256 amount1Desired,
            uint256 amount0Min,
            uint256 amount1Min
        ) = abi.decode(data, (uint256, address, address, uint256, uint256, uint256, uint256));

        if (amount0Desired == 0 && amount1Desired == 0) revert AddLiquidityAdapter__ZeroAmount();

        // Transfer tokens from user
        if (amount0Desired > 0) {
            IERC20(token0).safeTransferFrom(account, address(this), amount0Desired);
            IERC20(token0).forceApprove(address(positionManager), amount0Desired);
        }
        if (amount1Desired > 0) {
            IERC20(token1).safeTransferFrom(account, address(this), amount1Desired);
            IERC20(token1).forceApprove(address(positionManager), amount1Desired);
        }

        // Increase liquidity
        (
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        ) = positionManager.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: block.timestamp + 300
            })
        );

        // Refund unused tokens
        if (amount0Desired > amount0) {
            IERC20(token0).safeTransfer(account, amount0Desired - amount0);
        }
        if (amount1Desired > amount1) {
            IERC20(token1).safeTransfer(account, amount1Desired - amount1);
        }

        return abi.encode(tokenId, liquidity, amount0, amount1);
    }

    /// @inheritdoc IAdapter
    function send(bytes memory, uint8, uint64, uint112) external payable override returns (uint64) {
        revert("AddLiquidityAdapter: send not supported");
    }

    /// @inheritdoc IAdapter
    function estimateFee(uint8, uint112, uint256) external pure override returns (uint256) {
        return 0;
    }
}
