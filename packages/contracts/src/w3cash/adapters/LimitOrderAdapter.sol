// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice 0x v4 Limit Order
struct LimitOrder {
    address makerToken;
    address takerToken;
    uint128 makerAmount;
    uint128 takerAmount;
    uint128 takerTokenFeeAmount;
    address maker;
    address taker;
    address sender;
    address feeRecipient;
    bytes32 pool;
    uint64 expiry;
    uint256 salt;
}

/// @notice 0x v4 RFQ Order
struct RfqOrder {
    address makerToken;
    address takerToken;
    uint128 makerAmount;
    uint128 takerAmount;
    address maker;
    address taker;
    address txOrigin;
    bytes32 pool;
    uint64 expiry;
    uint256 salt;
}

/// @notice Signature for 0x orders
struct Signature {
    uint8 signatureType; // 2 = EIP712, 3 = EthSign
    uint8 v;
    bytes32 r;
    bytes32 s;
}

/// @title IZeroExExchangeProxy
/// @notice Minimal interface for 0x Exchange Proxy
interface IZeroExExchangeProxy {
    function fillLimitOrder(
        LimitOrder calldata order,
        Signature calldata signature,
        uint128 takerTokenFillAmount
    ) external payable returns (uint128 takerTokenFilledAmount, uint128 makerTokenFilledAmount);
    
    function fillRfqOrder(
        RfqOrder calldata order,
        Signature calldata signature,
        uint128 takerTokenFillAmount
    ) external returns (uint128 takerTokenFilledAmount, uint128 makerTokenFilledAmount);
    
    function cancelLimitOrder(LimitOrder calldata order) external;
    function cancelRfqOrder(RfqOrder calldata order) external;
    
    function getLimitOrderHash(LimitOrder calldata order) external view returns (bytes32);
    function getRfqOrderHash(RfqOrder calldata order) external view returns (bytes32);
}

/// @title ICoWSettlement
/// @notice Minimal interface for CoW Protocol Settlement
interface ICoWSettlement {
    struct GPv2Order {
        address sellToken;
        address buyToken;
        address receiver;
        uint256 sellAmount;
        uint256 buyAmount;
        uint32 validTo;
        bytes32 appData;
        uint256 feeAmount;
        bytes32 kind; // sell or buy
        bool partiallyFillable;
        bytes32 sellTokenBalance;
        bytes32 buyTokenBalance;
    }
    
    function setPreSignature(bytes calldata orderUid, bool signed) external;
    function invalidateOrder(bytes calldata orderUid) external;
}

/**
 * @title LimitOrderAdapter
 * @notice Action adapter for limit orders via 0x and CoW Protocol
 * @dev Supports creating, filling, and canceling limit orders
 */
contract LimitOrderAdapter is IAdapter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error LimitOrderAdapter__OnlyProcessor();
    error LimitOrderAdapter__InvalidOperation();
    error LimitOrderAdapter__InvalidProtocol();
    error LimitOrderAdapter__OrderFailed();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("LimitOrderAdapter"));
    
    /// @notice Protocol identifiers
    uint8 public constant PROTOCOL_0X = 1;
    uint8 public constant PROTOCOL_COW = 2;
    
    /// @notice Operation selectors
    bytes4 public constant OP_FILL_0X_LIMIT = 0x1baae71a; // fill0xLimitOrder
    bytes4 public constant OP_FILL_0X_RFQ = 0x3e97e7d6; // fill0xRfqOrder
    bytes4 public constant OP_CANCEL_0X = 0x2da62987; // cancel0xOrder
    bytes4 public constant OP_PRESIGN_COW = 0x1e44e70d; // preSignCoW
    bytes4 public constant OP_INVALIDATE_COW = 0x7b4d91ae; // invalidateCoW

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    address public immutable processor;
    IZeroExExchangeProxy public immutable zeroExProxy;
    ICoWSettlement public immutable cowSettlement;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _processor, address _zeroExProxy, address _cowSettlement) {
        processor = _processor;
        zeroExProxy = IZeroExExchangeProxy(_zeroExProxy);
        cowSettlement = ICoWSettlement(_cowSettlement);
    }

    /*//////////////////////////////////////////////////////////////
                           ADAPTER INTERFACE
    //////////////////////////////////////////////////////////////*/

    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    function execute(address initiator, bytes calldata input) external payable override returns (bytes memory) {
        if (msg.sender != processor) revert LimitOrderAdapter__OnlyProcessor();
        if (input.length < 4) revert LimitOrderAdapter__InvalidOperation();

        bytes4 operation = bytes4(input[:4]);
        bytes calldata params = input[4:];

        if (operation == OP_FILL_0X_LIMIT) {
            return _executeFill0xLimit(initiator, params);
        } else if (operation == OP_FILL_0X_RFQ) {
            return _executeFill0xRfq(initiator, params);
        } else if (operation == OP_CANCEL_0X) {
            return _executeCancel0x(params);
        } else if (operation == OP_PRESIGN_COW) {
            return _executePresignCoW(params);
        } else if (operation == OP_INVALIDATE_COW) {
            return _executeInvalidateCoW(params);
        } else {
            revert LimitOrderAdapter__InvalidOperation();
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

    /// @notice Fill a 0x limit order as taker
    function _executeFill0xLimit(address initiator, bytes calldata params) internal returns (bytes memory) {
        (LimitOrder memory order, Signature memory signature, uint128 takerTokenFillAmount) = 
            abi.decode(params, (LimitOrder, Signature, uint128));

        // Transfer taker tokens from initiator
        IERC20(order.takerToken).safeTransferFrom(initiator, address(this), takerTokenFillAmount);
        
        // Approve 0x proxy
        IERC20(order.takerToken).forceApprove(address(zeroExProxy), takerTokenFillAmount);

        // Fill order
        (uint128 takerFilled, uint128 makerFilled) = zeroExProxy.fillLimitOrder(
            order,
            signature,
            takerTokenFillAmount
        );

        // Transfer maker tokens to initiator
        IERC20(order.makerToken).safeTransfer(initiator, makerFilled);

        // Refund unused taker tokens
        uint256 unusedTaker = takerTokenFillAmount - takerFilled;
        if (unusedTaker > 0) {
            IERC20(order.takerToken).safeTransfer(initiator, unusedTaker);
        }

        return abi.encode(takerFilled, makerFilled);
    }

    /// @notice Fill a 0x RFQ order as taker
    function _executeFill0xRfq(address initiator, bytes calldata params) internal returns (bytes memory) {
        (RfqOrder memory order, Signature memory signature, uint128 takerTokenFillAmount) = 
            abi.decode(params, (RfqOrder, Signature, uint128));

        // Transfer taker tokens from initiator
        IERC20(order.takerToken).safeTransferFrom(initiator, address(this), takerTokenFillAmount);
        
        // Approve 0x proxy
        IERC20(order.takerToken).forceApprove(address(zeroExProxy), takerTokenFillAmount);

        // Fill order
        (uint128 takerFilled, uint128 makerFilled) = zeroExProxy.fillRfqOrder(
            order,
            signature,
            takerTokenFillAmount
        );

        // Transfer maker tokens to initiator
        IERC20(order.makerToken).safeTransfer(initiator, makerFilled);

        return abi.encode(takerFilled, makerFilled);
    }

    /// @notice Cancel a 0x limit order
    function _executeCancel0x(bytes calldata params) internal returns (bytes memory) {
        (bool isRfq, bytes memory orderData) = abi.decode(params, (bool, bytes));

        if (isRfq) {
            RfqOrder memory order = abi.decode(orderData, (RfqOrder));
            zeroExProxy.cancelRfqOrder(order);
        } else {
            LimitOrder memory order = abi.decode(orderData, (LimitOrder));
            zeroExProxy.cancelLimitOrder(order);
        }

        return abi.encode(true);
    }

    /// @notice Pre-sign a CoW Protocol order (on-chain signature)
    function _executePresignCoW(bytes calldata params) internal returns (bytes memory) {
        bytes memory orderUid = abi.decode(params, (bytes));
        
        cowSettlement.setPreSignature(orderUid, true);

        return abi.encode(true);
    }

    /// @notice Invalidate a CoW Protocol order
    function _executeInvalidateCoW(bytes calldata params) internal returns (bytes memory) {
        bytes memory orderUid = abi.decode(params, (bytes));
        
        cowSettlement.invalidateOrder(orderUid);

        return abi.encode(true);
    }
}
