// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title INonfungiblePositionManagerRemove
/// @notice Interface for Uniswap V3 position manager liquidity removal
interface INonfungiblePositionManagerRemove {
    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    function collect(CollectParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    function burn(uint256 tokenId) external payable;

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}

/// @title IERC721
/// @notice Minimal ERC721 interface
interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
    function approve(address to, uint256 tokenId) external;
}

/// @title RemoveLiquidityAdapter
/// @notice Adapter for removing liquidity from Uniswap V3
/// @dev Supports decreasing liquidity, collecting fees, and burning positions
contract RemoveLiquidityAdapter is IAdapter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error RemoveLiquidityAdapter__CallerNotProcessor();
    error RemoveLiquidityAdapter__ZeroLiquidity();
    error RemoveLiquidityAdapter__InvalidOperation();
    error RemoveLiquidityAdapter__NotOwner();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("RemoveLiquidityAdapter"));

    /// @notice Operations
    uint8 public constant OP_DECREASE = 0;     // Decrease liquidity
    uint8 public constant OP_COLLECT = 1;      // Collect tokens/fees
    uint8 public constant OP_CLOSE = 2;        // Decrease all + collect + burn

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Uniswap V3 Position Manager
    INonfungiblePositionManagerRemove public immutable positionManager;

    /// @notice The authorized Processor contract
    address public immutable processor;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyProcessor() {
        if (msg.sender != processor) revert RemoveLiquidityAdapter__CallerNotProcessor();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _positionManager The Uniswap V3 Position Manager address
    /// @param _processor The authorized Processor address
    constructor(address _positionManager, address _processor) {
        positionManager = INonfungiblePositionManagerRemove(_positionManager);
        processor = _processor;
    }

    /*//////////////////////////////////////////////////////////////
                           ADAPTER INTERFACE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAdapter
    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    /// @notice Remove liquidity from Uniswap V3
    /// @param account The account removing liquidity
    /// @param data ABI encoded based on operation:
    ///        DECREASE: (uint8 op, uint256 tokenId, uint128 liquidity, uint256 amount0Min, uint256 amount1Min)
    ///        COLLECT: (uint8 op, uint256 tokenId)
    ///        CLOSE: (uint8 op, uint256 tokenId, uint256 amount0Min, uint256 amount1Min)
    /// @return ABI encoded result (amount0, amount1)
    function execute(
        address account,
        bytes calldata data
    ) external payable override onlyProcessor returns (bytes memory) {
        uint8 operation = uint8(data[0]);

        if (operation == OP_DECREASE) {
            return _decrease(account, data[1:]);
        } else if (operation == OP_COLLECT) {
            return _collect(account, data[1:]);
        } else if (operation == OP_CLOSE) {
            return _close(account, data[1:]);
        } else {
            revert RemoveLiquidityAdapter__InvalidOperation();
        }
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _decrease(address account, bytes calldata data) internal returns (bytes memory) {
        (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0Min,
            uint256 amount1Min
        ) = abi.decode(data, (uint256, uint128, uint256, uint256));

        if (liquidity == 0) revert RemoveLiquidityAdapter__ZeroLiquidity();

        // User must have approved this adapter for the NFT
        // Decrease liquidity
        (uint256 amount0, uint256 amount1) = positionManager.decreaseLiquidity(
            INonfungiblePositionManagerRemove.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: block.timestamp + 300
            })
        );

        return abi.encode(amount0, amount1);
    }

    function _collect(address account, bytes calldata data) internal returns (bytes memory) {
        uint256 tokenId = abi.decode(data, (uint256));

        // Collect all owed tokens to user
        (uint256 amount0, uint256 amount1) = positionManager.collect(
            INonfungiblePositionManagerRemove.CollectParams({
                tokenId: tokenId,
                recipient: account,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        return abi.encode(amount0, amount1);
    }

    function _close(address account, bytes calldata data) internal returns (bytes memory) {
        (
            uint256 tokenId,
            uint256 amount0Min,
            uint256 amount1Min
        ) = abi.decode(data, (uint256, uint256, uint256));

        // Get position liquidity
        (,,,,,,,uint128 liquidity,,,,) = positionManager.positions(tokenId);

        // Decrease all liquidity
        if (liquidity > 0) {
            positionManager.decreaseLiquidity(
                INonfungiblePositionManagerRemove.DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: liquidity,
                    amount0Min: amount0Min,
                    amount1Min: amount1Min,
                    deadline: block.timestamp + 300
                })
            );
        }

        // Collect all tokens
        (uint256 amount0, uint256 amount1) = positionManager.collect(
            INonfungiblePositionManagerRemove.CollectParams({
                tokenId: tokenId,
                recipient: account,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        // Burn the position NFT (position must have 0 liquidity)
        positionManager.burn(tokenId);

        return abi.encode(amount0, amount1);
    }

    /// @inheritdoc IAdapter
    function send(bytes memory, uint8, uint64, uint112) external payable override returns (uint64) {
        revert("RemoveLiquidityAdapter: send not supported");
    }

    /// @inheritdoc IAdapter
    function estimateFee(uint8, uint112, uint256) external pure override returns (uint256) {
        return 0;
    }
}
