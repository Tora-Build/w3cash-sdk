// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IFlow} from "../core/IFlow.sol";

/// @title x402Flow
/// @notice HTTP-native payment flow compatible with x402 protocol
/// @dev Handles on-chain settlement for x402 payments
contract x402Flow is IFlow {
    // Flow identifier: "x402" = 0x78343032
    bytes4 public constant FLOW_ID = 0x78343032;
    
    // Actions
    bytes4 public constant ACTION_PAY = 0x0a1ebe70;        // pay(address,uint256,address,bytes32)
    bytes4 public constant ACTION_PAY_ETH = 0x1249c58b;    // payEth(address,bytes32)
    bytes4 public constant ACTION_VERIFY = 0x8e760afe;    // verify(bytes32)
    
    // Events
    event Payment(
        bytes32 indexed paymentId,
        address indexed from,
        address indexed to,
        address token,
        uint256 amount,
        bytes32 resourceId
    );
    
    // Storage
    mapping(bytes32 => PaymentReceipt) public receipts;
    
    struct PaymentReceipt {
        address from;
        address to;
        address token;
        uint256 amount;
        bytes32 resourceId;
        uint256 timestamp;
    }
    
    /// @inheritdoc IFlow
    function execute(address caller, bytes calldata data) external payable returns (bytes memory) {
        bytes4 action = bytes4(data[:4]);
        bytes memory params = data[4:];
        
        if (action == ACTION_PAY) {
            return _pay(caller, params);
        } else if (action == ACTION_PAY_ETH) {
            return _payEth(caller, params);
        } else if (action == ACTION_VERIFY) {
            return _verify(params);
        }
        
        revert("x402: unsupported action");
    }
    
    /// @inheritdoc IFlow
    function flowId() external pure returns (bytes4) {
        return FLOW_ID;
    }
    
    /// @inheritdoc IFlow
    function supportsAction(bytes4 action) external pure returns (bool) {
        return action == ACTION_PAY || action == ACTION_PAY_ETH || action == ACTION_VERIFY;
    }
    
    /// @inheritdoc IFlow
    function metadata() external pure returns (string memory, string memory) {
        return ("x402Flow", "1.0.0");
    }
    
    /// @notice Pay with ERC20 token
    /// @dev Requires prior approval to this contract
    function _pay(address caller, bytes memory params) internal returns (bytes memory) {
        (address to, uint256 amount, address token, bytes32 resourceId) = 
            abi.decode(params, (address, uint256, address, bytes32));
        
        // Generate unique payment ID
        bytes32 paymentId = keccak256(abi.encodePacked(
            caller, to, token, amount, resourceId, block.timestamp, block.number
        ));
        
        // Transfer tokens
        (bool success, ) = token.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", caller, to, amount)
        );
        require(success, "x402: transfer failed");
        
        // Store receipt
        receipts[paymentId] = PaymentReceipt({
            from: caller,
            to: to,
            token: token,
            amount: amount,
            resourceId: resourceId,
            timestamp: block.timestamp
        });
        
        emit Payment(paymentId, caller, to, token, amount, resourceId);
        
        return abi.encode(paymentId);
    }
    
    /// @notice Pay with native ETH (must call directly, not via execute)
    function _payEth(address caller, bytes memory params) internal returns (bytes memory) {
        (address to, bytes32 resourceId) = abi.decode(params, (address, bytes32));
        
        // Note: For ETH payments, call payEth directly, not via execute
        // execute() is non-payable per IFlow interface
        revert("x402: use payEth() directly for ETH payments");
    }
    
    /// @notice Verify a payment exists
    function _verify(bytes memory params) internal view returns (bytes memory) {
        bytes32 paymentId = abi.decode(params, (bytes32));
        
        PaymentReceipt memory receipt = receipts[paymentId];
        bool exists = receipt.timestamp > 0;
        
        return abi.encode(exists, receipt);
    }
    
    /// @notice Direct payment function for convenience
    function pay(address to, uint256 amount, address token, bytes32 resourceId) external returns (bytes32) {
        bytes memory result = _pay(msg.sender, abi.encode(to, amount, token, resourceId));
        return abi.decode(result, (bytes32));
    }
    
    /// @notice Direct ETH payment function
    function payEth(address to, bytes32 resourceId) external payable returns (bytes32) {
        require(msg.value > 0, "x402: no value sent");
        
        // Generate unique payment ID
        bytes32 paymentId = keccak256(abi.encodePacked(
            msg.sender, to, address(0), msg.value, resourceId, block.timestamp, block.number
        ));
        
        // Transfer ETH
        (bool success, ) = to.call{value: msg.value}("");
        require(success, "x402: ETH transfer failed");
        
        // Store receipt
        receipts[paymentId] = PaymentReceipt({
            from: msg.sender,
            to: to,
            token: address(0), // ETH
            amount: msg.value,
            resourceId: resourceId,
            timestamp: block.timestamp
        });
        
        emit Payment(paymentId, msg.sender, to, address(0), msg.value, resourceId);
        
        return paymentId;
    }
    
    /// @notice Check if a payment exists
    function verify(bytes32 paymentId) external view returns (bool exists, PaymentReceipt memory receipt) {
        receipt = receipts[paymentId];
        exists = receipt.timestamp > 0;
    }
}
