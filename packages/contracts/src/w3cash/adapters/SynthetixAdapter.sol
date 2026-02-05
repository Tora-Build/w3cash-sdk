// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title ISynthetixPerpsV2
/// @notice Interface for Synthetix Perps V2 Market
interface ISynthetixPerpsV2 {
    struct Position {
        uint64 id;
        uint64 lastFundingIndex;
        uint128 margin;
        uint128 lastPrice;
        int128 size;
    }
    
    function modifyPositionWithTracking(
        int256 sizeDelta,
        uint256 desiredFillPrice,
        bytes32 trackingCode
    ) external;
    
    function closePositionWithTracking(
        uint256 desiredFillPrice,
        bytes32 trackingCode
    ) external;
    
    function submitOffchainDelayedOrderWithTracking(
        int256 sizeDelta,
        uint256 desiredFillPrice,
        bytes32 trackingCode
    ) external;
    
    function submitOffchainDelayedOrder(
        int256 sizeDelta,
        uint256 desiredFillPrice
    ) external;
    
    function cancelOffchainDelayedOrder(address account) external;
    function executeOffchainDelayedOrder(address account, bytes[] calldata priceUpdateData) external payable;
    
    function transferMargin(int256 marginDelta) external;
    function withdrawAllMargin() external;
    
    function positions(address account) external view returns (Position memory);
    function remainingMargin(address account) external view returns (uint256 marginRemaining, bool invalid);
    function accessibleMargin(address account) external view returns (uint256 marginAccessible, bool invalid);
    function currentFundingRate() external view returns (int256 fundingRate);
    function assetPrice() external view returns (uint256 price, bool invalid);
    function marketKey() external view returns (bytes32);
}

/// @title ISynthetixPerpsV3
/// @notice Interface for Synthetix Perps V3
interface ISynthetixPerpsV3 {
    struct OrderCommitment {
        uint128 marketId;
        uint128 accountId;
        int128 sizeDelta;
        uint256 settlementStrategyId;
        uint256 acceptablePrice;
        bytes32 trackingCode;
        address referrer;
    }
    
    function commitOrder(OrderCommitment memory commitment) external returns (uint256 commitmentTime, uint256 fees);
    function settleOrder(uint128 accountId) external;
    function cancelOrder(uint128 accountId) external;
    
    function modifyCollateral(uint128 accountId, uint128 synthMarketId, int256 amountDelta) external;
    
    function getOpenPosition(uint128 accountId, uint128 marketId) external view returns (
        int256 totalPnl,
        int256 accruedFunding,
        int128 positionSize
    );
    
    function getAvailableMargin(uint128 accountId) external view returns (int256 availableMargin);
    function getRequiredMargins(uint128 accountId) external view returns (
        uint256 requiredInitialMargin,
        uint256 requiredMaintenanceMargin,
        uint256 totalAccumulatedLiquidationRewards,
        uint256 maxLiquidationReward
    );
}

/// @title ISpotMarket
/// @notice Interface for Synthetix Spot Market
interface ISpotMarket {
    function buy(
        uint128 marketId,
        uint256 usdAmount,
        uint256 minAmountReceived,
        address referrer
    ) external returns (uint256 synthAmount, uint256 fees);
    
    function sell(
        uint128 marketId,
        uint256 synthAmount,
        uint256 minUsdAmount,
        address referrer
    ) external returns (uint256 usdAmount, uint256 fees);
    
    function wrap(uint128 marketId, uint256 wrapAmount, uint256 minAmountReceived) 
        external returns (uint256 amountToMint, uint256 fees);
        
    function unwrap(uint128 marketId, uint256 unwrapAmount, uint256 minAmountReceived)
        external returns (uint256 returnCollateralAmount, uint256 fees);
}

/**
 * @title SynthetixAdapter
 * @notice Action adapter for Synthetix V3 Perps and Spot Markets
 * @dev Supports trading, collateral management, and position tracking
 */
contract SynthetixAdapter is IAdapter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error SynthetixAdapter__OnlyProcessor();
    error SynthetixAdapter__InvalidOperation();
    error SynthetixAdapter__ZeroAmount();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("SynthetixAdapter"));
    bytes32 public constant TRACKING_CODE = bytes32("w3cash");
    
    /// @notice Operation selectors
    bytes4 public constant OP_COMMIT_ORDER = 0x7f00b1b4; // commitOrder(...)
    bytes4 public constant OP_SETTLE_ORDER = 0x17eb8cf3; // settleOrder(uint128)
    bytes4 public constant OP_CANCEL_ORDER = 0xa85a9a3e; // cancelOrder(uint128)
    bytes4 public constant OP_MODIFY_COLLATERAL = 0x8d34166b; // modifyCollateral(...)
    bytes4 public constant OP_SPOT_BUY = 0xc9d27afe; // buy(...)
    bytes4 public constant OP_SPOT_SELL = 0xe4849b32; // sell(...)
    bytes4 public constant OP_WRAP = 0xd6dc43c5; // wrap(...)
    bytes4 public constant OP_UNWRAP = 0xde0e9a3e; // unwrap(...)

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    address public immutable processor;
    ISynthetixPerpsV3 public immutable perpsMarket;
    ISpotMarket public immutable spotMarket;
    address public immutable sUSD;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address _processor,
        address _perpsMarket,
        address _spotMarket,
        address _sUSD
    ) {
        processor = _processor;
        perpsMarket = ISynthetixPerpsV3(_perpsMarket);
        spotMarket = ISpotMarket(_spotMarket);
        sUSD = _sUSD;
    }

    /*//////////////////////////////////////////////////////////////
                           ADAPTER INTERFACE
    //////////////////////////////////////////////////////////////*/

    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    function execute(address initiator, bytes calldata input) external payable override returns (bytes memory) {
        if (msg.sender != processor) revert SynthetixAdapter__OnlyProcessor();
        if (input.length < 4) revert SynthetixAdapter__InvalidOperation();

        bytes4 operation = bytes4(input[:4]);
        bytes calldata params = input[4:];

        if (operation == OP_COMMIT_ORDER) {
            return _executeCommitOrder(initiator, params);
        } else if (operation == OP_SETTLE_ORDER) {
            return _executeSettleOrder(params);
        } else if (operation == OP_CANCEL_ORDER) {
            return _executeCancelOrder(params);
        } else if (operation == OP_MODIFY_COLLATERAL) {
            return _executeModifyCollateral(initiator, params);
        } else if (operation == OP_SPOT_BUY) {
            return _executeSpotBuy(initiator, params);
        } else if (operation == OP_SPOT_SELL) {
            return _executeSpotSell(initiator, params);
        } else if (operation == OP_WRAP) {
            return _executeWrap(initiator, params);
        } else if (operation == OP_UNWRAP) {
            return _executeUnwrap(initiator, params);
        } else {
            revert SynthetixAdapter__InvalidOperation();
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

    /// @notice Commit a perps order
    function _executeCommitOrder(address initiator, bytes calldata params) internal returns (bytes memory) {
        (
            uint128 marketId,
            uint128 accountId,
            int128 sizeDelta,
            uint256 settlementStrategyId,
            uint256 acceptablePrice
        ) = abi.decode(params, (uint128, uint128, int128, uint256, uint256));

        ISynthetixPerpsV3.OrderCommitment memory commitment = ISynthetixPerpsV3.OrderCommitment({
            marketId: marketId,
            accountId: accountId,
            sizeDelta: sizeDelta,
            settlementStrategyId: settlementStrategyId,
            acceptablePrice: acceptablePrice,
            trackingCode: TRACKING_CODE,
            referrer: initiator
        });

        (uint256 commitmentTime, uint256 fees) = perpsMarket.commitOrder(commitment);

        return abi.encode(commitmentTime, fees);
    }

    /// @notice Settle a pending order
    function _executeSettleOrder(bytes calldata params) internal returns (bytes memory) {
        uint128 accountId = abi.decode(params, (uint128));
        
        perpsMarket.settleOrder(accountId);

        return abi.encode(true);
    }

    /// @notice Cancel a pending order
    function _executeCancelOrder(bytes calldata params) internal returns (bytes memory) {
        uint128 accountId = abi.decode(params, (uint128));
        
        perpsMarket.cancelOrder(accountId);

        return abi.encode(true);
    }

    /// @notice Modify collateral for an account
    function _executeModifyCollateral(address initiator, bytes calldata params) internal returns (bytes memory) {
        (uint128 accountId, uint128 synthMarketId, int256 amountDelta, address collateralToken) = 
            abi.decode(params, (uint128, uint128, int256, address));

        if (amountDelta > 0) {
            // Deposit collateral
            uint256 amount = uint256(amountDelta);
            IERC20(collateralToken).safeTransferFrom(initiator, address(this), amount);
            IERC20(collateralToken).forceApprove(address(perpsMarket), amount);
        }

        perpsMarket.modifyCollateral(accountId, synthMarketId, amountDelta);

        if (amountDelta < 0) {
            // Withdrawal - transfer tokens to initiator
            uint256 amount = uint256(-amountDelta);
            IERC20(collateralToken).safeTransfer(initiator, amount);
        }

        return abi.encode(true);
    }

    /// @notice Buy synths with sUSD
    function _executeSpotBuy(address initiator, bytes calldata params) internal returns (bytes memory) {
        (uint128 marketId, uint256 usdAmount, uint256 minAmountReceived) = 
            abi.decode(params, (uint128, uint256, uint256));

        if (usdAmount == 0) revert SynthetixAdapter__ZeroAmount();

        // Transfer sUSD from initiator
        IERC20(sUSD).safeTransferFrom(initiator, address(this), usdAmount);
        IERC20(sUSD).forceApprove(address(spotMarket), usdAmount);

        // Buy synths
        (uint256 synthAmount, uint256 fees) = spotMarket.buy(
            marketId,
            usdAmount,
            minAmountReceived,
            initiator
        );

        return abi.encode(synthAmount, fees);
    }

    /// @notice Sell synths for sUSD
    function _executeSpotSell(address initiator, bytes calldata params) internal returns (bytes memory) {
        (uint128 marketId, address synthToken, uint256 synthAmount, uint256 minUsdAmount) = 
            abi.decode(params, (uint128, address, uint256, uint256));

        if (synthAmount == 0) revert SynthetixAdapter__ZeroAmount();

        // Transfer synths from initiator
        IERC20(synthToken).safeTransferFrom(initiator, address(this), synthAmount);
        IERC20(synthToken).forceApprove(address(spotMarket), synthAmount);

        // Sell synths
        (uint256 usdAmount, uint256 fees) = spotMarket.sell(
            marketId,
            synthAmount,
            minUsdAmount,
            initiator
        );

        // Transfer sUSD to initiator
        IERC20(sUSD).safeTransfer(initiator, usdAmount);

        return abi.encode(usdAmount, fees);
    }

    /// @notice Wrap collateral into synths
    function _executeWrap(address initiator, bytes calldata params) internal returns (bytes memory) {
        (uint128 marketId, address collateralToken, uint256 wrapAmount, uint256 minAmountReceived) = 
            abi.decode(params, (uint128, address, uint256, uint256));

        if (wrapAmount == 0) revert SynthetixAdapter__ZeroAmount();

        // Transfer collateral from initiator
        IERC20(collateralToken).safeTransferFrom(initiator, address(this), wrapAmount);
        IERC20(collateralToken).forceApprove(address(spotMarket), wrapAmount);

        // Wrap
        (uint256 amountMinted, uint256 fees) = spotMarket.wrap(marketId, wrapAmount, minAmountReceived);

        return abi.encode(amountMinted, fees);
    }

    /// @notice Unwrap synths to collateral
    function _executeUnwrap(address initiator, bytes calldata params) internal returns (bytes memory) {
        (uint128 marketId, address synthToken, uint256 unwrapAmount, uint256 minAmountReceived) = 
            abi.decode(params, (uint128, address, uint256, uint256));

        if (unwrapAmount == 0) revert SynthetixAdapter__ZeroAmount();

        // Transfer synths from initiator
        IERC20(synthToken).safeTransferFrom(initiator, address(this), unwrapAmount);
        IERC20(synthToken).forceApprove(address(spotMarket), unwrapAmount);

        // Unwrap
        (uint256 collateralReturned, uint256 fees) = spotMarket.unwrap(marketId, unwrapAmount, minAmountReceived);

        return abi.encode(collateralReturned, fees);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get open position for an account
    function getOpenPosition(uint128 accountId, uint128 marketId) external view returns (
        int256 totalPnl,
        int256 accruedFunding,
        int128 positionSize
    ) {
        return perpsMarket.getOpenPosition(accountId, marketId);
    }

    /// @notice Get available margin for an account
    function getAvailableMargin(uint128 accountId) external view returns (int256) {
        return perpsMarket.getAvailableMargin(accountId);
    }
}
