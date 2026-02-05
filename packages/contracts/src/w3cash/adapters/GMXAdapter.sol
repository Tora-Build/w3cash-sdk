// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title IGMXRouter
/// @notice Interface for GMX Router
interface IGMXRouter {
    function swap(
        address[] memory _path,
        uint256 _amountIn,
        uint256 _minOut,
        address _receiver
    ) external;
    
    function swapTokensToETH(
        address[] memory _path,
        uint256 _amountIn,
        uint256 _minOut,
        address payable _receiver
    ) external;
    
    function swapETHToTokens(
        address[] memory _path,
        uint256 _minOut,
        address _receiver
    ) external payable;
}

/// @title IGMXPositionRouter
/// @notice Interface for GMX Position Router (V1 Perps)
interface IGMXPositionRouter {
    function createIncreasePosition(
        address[] memory _path,
        address _indexToken,
        uint256 _amountIn,
        uint256 _minOut,
        uint256 _sizeDelta,
        bool _isLong,
        uint256 _acceptablePrice,
        uint256 _executionFee,
        bytes32 _referralCode,
        address _callbackTarget
    ) external payable returns (bytes32);
    
    function createDecreasePosition(
        address[] memory _path,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver,
        uint256 _acceptablePrice,
        uint256 _minOut,
        uint256 _executionFee,
        bool _withdrawETH,
        address _callbackTarget
    ) external payable returns (bytes32);
    
    function cancelIncreasePosition(bytes32 _key, address payable _executionFeeReceiver) external returns (bool);
    function cancelDecreasePosition(bytes32 _key, address payable _executionFeeReceiver) external returns (bool);
    
    function minExecutionFee() external view returns (uint256);
}

/// @title IGMXVault
/// @notice Interface for GMX Vault
interface IGMXVault {
    function getPosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong
    ) external view returns (
        uint256 size,
        uint256 collateral,
        uint256 averagePrice,
        uint256 entryFundingRate,
        uint256 reserveAmount,
        int256 realisedPnl,
        uint256 lastIncreasedTime
    );
    
    function getMaxPrice(address _token) external view returns (uint256);
    function getMinPrice(address _token) external view returns (uint256);
}

/// @title IGLP
/// @notice Interface for GLP (GMX Liquidity Provider Token)
interface IGLP {
    function balanceOf(address account) external view returns (uint256);
}

/// @title IGLPManager
/// @notice Interface for GLP Manager
interface IGLPManager {
    function addLiquidity(
        address _token,
        uint256 _amount,
        uint256 _minUsdg,
        uint256 _minGlp
    ) external returns (uint256);
    
    function addLiquidityForAccount(
        address _fundingAccount,
        address _account,
        address _token,
        uint256 _amount,
        uint256 _minUsdg,
        uint256 _minGlp
    ) external returns (uint256);
    
    function removeLiquidity(
        address _tokenOut,
        uint256 _glpAmount,
        uint256 _minOut,
        address _receiver
    ) external returns (uint256);
}

/**
 * @title GMXAdapter
 * @notice Action adapter for GMX V1 perpetuals and GLP
 * @dev Supports swap, position management, and GLP operations
 */
contract GMXAdapter is IAdapter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error GMXAdapter__OnlyProcessor();
    error GMXAdapter__InvalidOperation();
    error GMXAdapter__ZeroAmount();
    error GMXAdapter__InsufficientFee();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("GMXAdapter"));
    bytes32 public constant REFERRAL_CODE = bytes32("w3cash");
    
    /// @notice Operation selectors
    bytes4 public constant OP_SWAP = 0x8119c065; // swap(...)
    bytes4 public constant OP_INCREASE_POSITION = 0x5b88e8c6; // createIncreasePosition(...)
    bytes4 public constant OP_DECREASE_POSITION = 0x90205d8c; // createDecreasePosition(...)
    bytes4 public constant OP_CANCEL_POSITION = 0x6168bc63; // cancelPosition(...)
    bytes4 public constant OP_ADD_GLP = 0xe8e33700; // addLiquidity(...)
    bytes4 public constant OP_REMOVE_GLP = 0x5b36389c; // removeLiquidity(...)

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    address public immutable processor;
    IGMXRouter public immutable router;
    IGMXPositionRouter public immutable positionRouter;
    IGMXVault public immutable vault;
    IGLPManager public immutable glpManager;
    address public immutable glp;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address _processor,
        address _router,
        address _positionRouter,
        address _vault,
        address _glpManager,
        address _glp
    ) {
        processor = _processor;
        router = IGMXRouter(_router);
        positionRouter = IGMXPositionRouter(_positionRouter);
        vault = IGMXVault(_vault);
        glpManager = IGLPManager(_glpManager);
        glp = _glp;
    }

    /*//////////////////////////////////////////////////////////////
                           ADAPTER INTERFACE
    //////////////////////////////////////////////////////////////*/

    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    function execute(address initiator, bytes calldata input) external payable override returns (bytes memory) {
        if (msg.sender != processor) revert GMXAdapter__OnlyProcessor();
        if (input.length < 4) revert GMXAdapter__InvalidOperation();

        bytes4 operation = bytes4(input[:4]);
        bytes calldata params = input[4:];

        if (operation == OP_SWAP) {
            return _executeSwap(initiator, params);
        } else if (operation == OP_INCREASE_POSITION) {
            return _executeIncreasePosition(initiator, params);
        } else if (operation == OP_DECREASE_POSITION) {
            return _executeDecreasePosition(initiator, params);
        } else if (operation == OP_CANCEL_POSITION) {
            return _executeCancelPosition(initiator, params);
        } else if (operation == OP_ADD_GLP) {
            return _executeAddGlp(initiator, params);
        } else if (operation == OP_REMOVE_GLP) {
            return _executeRemoveGlp(initiator, params);
        } else {
            revert GMXAdapter__InvalidOperation();
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

    /// @notice Execute a swap on GMX
    function _executeSwap(address initiator, bytes calldata params) internal returns (bytes memory) {
        (address[] memory path, uint256 amountIn, uint256 minOut) = 
            abi.decode(params, (address[], uint256, uint256));

        if (amountIn == 0) revert GMXAdapter__ZeroAmount();

        // Transfer input token from initiator
        IERC20(path[0]).safeTransferFrom(initiator, address(this), amountIn);
        IERC20(path[0]).forceApprove(address(router), amountIn);

        // Execute swap - output goes to initiator
        router.swap(path, amountIn, minOut, initiator);

        return abi.encode(true);
    }

    /// @notice Create an increase position order
    function _executeIncreasePosition(address initiator, bytes calldata params) internal returns (bytes memory) {
        (
            address[] memory path,
            address indexToken,
            uint256 amountIn,
            uint256 minOut,
            uint256 sizeDelta,
            bool isLong,
            uint256 acceptablePrice
        ) = abi.decode(params, (address[], address, uint256, uint256, uint256, bool, uint256));

        uint256 executionFee = positionRouter.minExecutionFee();
        if (msg.value < executionFee) revert GMXAdapter__InsufficientFee();

        // Transfer collateral from initiator
        if (amountIn > 0) {
            IERC20(path[0]).safeTransferFrom(initiator, address(this), amountIn);
            IERC20(path[0]).forceApprove(address(positionRouter), amountIn);
        }

        // Create position - position is opened for this adapter, but
        // in practice would need additional logic to track positions per user
        bytes32 key = positionRouter.createIncreasePosition{ value: executionFee }(
            path,
            indexToken,
            amountIn,
            minOut,
            sizeDelta,
            isLong,
            acceptablePrice,
            executionFee,
            REFERRAL_CODE,
            address(0) // no callback
        );

        return abi.encode(key);
    }

    /// @notice Create a decrease position order
    function _executeDecreasePosition(address initiator, bytes calldata params) internal returns (bytes memory) {
        (
            address[] memory path,
            address indexToken,
            uint256 collateralDelta,
            uint256 sizeDelta,
            bool isLong,
            uint256 acceptablePrice,
            uint256 minOut,
            bool withdrawETH
        ) = abi.decode(params, (address[], address, uint256, uint256, bool, uint256, uint256, bool));

        uint256 executionFee = positionRouter.minExecutionFee();
        if (msg.value < executionFee) revert GMXAdapter__InsufficientFee();

        // Create decrease position order
        bytes32 key = positionRouter.createDecreasePosition{ value: executionFee }(
            path,
            indexToken,
            collateralDelta,
            sizeDelta,
            isLong,
            initiator, // receiver
            acceptablePrice,
            minOut,
            executionFee,
            withdrawETH,
            address(0) // no callback
        );

        return abi.encode(key);
    }

    /// @notice Cancel a pending position order
    function _executeCancelPosition(address initiator, bytes calldata params) internal returns (bytes memory) {
        (bytes32 key, bool isIncrease) = abi.decode(params, (bytes32, bool));

        bool success;
        if (isIncrease) {
            success = positionRouter.cancelIncreasePosition(key, payable(initiator));
        } else {
            success = positionRouter.cancelDecreasePosition(key, payable(initiator));
        }

        return abi.encode(success);
    }

    /// @notice Add liquidity to GLP
    function _executeAddGlp(address initiator, bytes calldata params) internal returns (bytes memory) {
        (address token, uint256 amount, uint256 minUsdg, uint256 minGlp) = 
            abi.decode(params, (address, uint256, uint256, uint256));

        if (amount == 0) revert GMXAdapter__ZeroAmount();

        // Transfer token from initiator
        IERC20(token).safeTransferFrom(initiator, address(this), amount);
        IERC20(token).forceApprove(address(glpManager), amount);

        // Add liquidity - GLP goes to initiator
        uint256 glpAmount = glpManager.addLiquidityForAccount(
            address(this),
            initiator,
            token,
            amount,
            minUsdg,
            minGlp
        );

        return abi.encode(glpAmount);
    }

    /// @notice Remove liquidity from GLP
    function _executeRemoveGlp(address initiator, bytes calldata params) internal returns (bytes memory) {
        (address tokenOut, uint256 glpAmount, uint256 minOut) = 
            abi.decode(params, (address, uint256, uint256));

        if (glpAmount == 0) revert GMXAdapter__ZeroAmount();

        // Transfer GLP from initiator
        IERC20(glp).safeTransferFrom(initiator, address(this), glpAmount);
        IERC20(glp).forceApprove(address(glpManager), glpAmount);

        // Remove liquidity - tokens go to initiator
        uint256 amountOut = glpManager.removeLiquidity(
            tokenOut,
            glpAmount,
            minOut,
            initiator
        );

        return abi.encode(amountOut);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get position details
    function getPosition(
        address account,
        address collateralToken,
        address indexToken,
        bool isLong
    ) external view returns (
        uint256 size,
        uint256 collateral,
        uint256 averagePrice,
        uint256 entryFundingRate,
        uint256 reserveAmount,
        int256 realisedPnl,
        uint256 lastIncreasedTime
    ) {
        return vault.getPosition(account, collateralToken, indexToken, isLong);
    }

    /// @notice Get min execution fee for position orders
    function getMinExecutionFee() external view returns (uint256) {
        return positionRouter.minExecutionFee();
    }

    /// @notice Get token price from vault
    function getTokenPrice(address token, bool isMax) external view returns (uint256) {
        return isMax ? vault.getMaxPrice(token) : vault.getMinPrice(token);
    }
}
