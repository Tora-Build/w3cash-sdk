// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IFlow} from "../core/IFlow.sol";

/// @title YieldFlow
/// @notice Aave V3 yield flow for deposits and withdrawals
/// @dev Interacts with Aave V3 Pool on Base
contract YieldFlow is IFlow {
    // Flow identifier: "yeld" = 0x79656c64
    bytes4 public constant FLOW_ID = 0x79656c64;
    
    // Actions (matching FLOWS.md selectors)
    bytes4 public constant ACTION_DEPOSIT = 0x47e7ef24;     // deposit(address,uint256)
    bytes4 public constant ACTION_WITHDRAW = 0xf3fef3a3;    // withdraw(address,uint256)
    bytes4 public constant ACTION_WITHDRAW_ALL = 0xfa09e630; // withdrawAll(address)
    bytes4 public constant ACTION_BALANCE = 0xe3d670d7;      // balance(address,address)
    
    // Aave V3 Pool
    address public immutable aavePool;
    
    // Events
    event Deposited(address indexed caller, address indexed token, uint256 amount);
    event Withdrawn(address indexed caller, address indexed token, uint256 amount);
    
    constructor(address _aavePool) {
        aavePool = _aavePool;
    }
    
    /// @inheritdoc IFlow
    function execute(address caller, bytes calldata data) external payable returns (bytes memory) {
        bytes4 action = bytes4(data[:4]);
        bytes memory params = data[4:];
        
        if (action == ACTION_DEPOSIT) {
            return _deposit(caller, params);
        } else if (action == ACTION_WITHDRAW) {
            return _withdraw(caller, params);
        } else if (action == ACTION_WITHDRAW_ALL) {
            return _withdrawAll(caller, params);
        } else if (action == ACTION_BALANCE) {
            return _getBalance(params);
        }
        
        revert("YieldFlow: unsupported action");
    }
    
    /// @inheritdoc IFlow
    function flowId() external pure returns (bytes4) {
        return FLOW_ID;
    }
    
    /// @inheritdoc IFlow
    function supportsAction(bytes4 action) external pure returns (bool) {
        return action == ACTION_DEPOSIT || 
               action == ACTION_WITHDRAW || 
               action == ACTION_WITHDRAW_ALL ||
               action == ACTION_BALANCE;
    }
    
    /// @inheritdoc IFlow
    function metadata() external pure returns (string memory, string memory) {
        return ("YieldFlow", "1.0.0");
    }
    
    /// @notice Deposit tokens to Aave
    function _deposit(address caller, bytes memory params) internal returns (bytes memory) {
        (address token, uint256 amount) = abi.decode(params, (address, uint256));
        
        // Transfer tokens from caller to this contract
        (bool transferSuccess, ) = token.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", caller, address(this), amount)
        );
        require(transferSuccess, "YieldFlow: transfer failed");
        
        // Approve Aave Pool
        (bool approveSuccess, ) = token.call(
            abi.encodeWithSignature("approve(address,uint256)", aavePool, amount)
        );
        require(approveSuccess, "YieldFlow: approve failed");
        
        // Deposit to Aave (supply function)
        // supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode)
        (bool depositSuccess, ) = aavePool.call(
            abi.encodeWithSignature("supply(address,uint256,address,uint16)", token, amount, caller, 0)
        );
        require(depositSuccess, "YieldFlow: deposit failed");
        
        emit Deposited(caller, token, amount);
        
        return abi.encode(true, amount);
    }
    
    /// @notice Withdraw tokens from Aave
    function _withdraw(address caller, bytes memory params) internal returns (bytes memory) {
        (address token, uint256 amount) = abi.decode(params, (address, uint256));
        
        // Get aToken address from Aave
        address aToken = _getAToken(token);
        
        // Transfer aTokens from caller to this contract
        (bool transferSuccess, ) = aToken.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", caller, address(this), amount)
        );
        require(transferSuccess, "YieldFlow: aToken transfer failed");
        
        // Withdraw from Aave
        // withdraw(address asset, uint256 amount, address to)
        (bool withdrawSuccess, bytes memory result) = aavePool.call(
            abi.encodeWithSignature("withdraw(address,uint256,address)", token, amount, caller)
        );
        require(withdrawSuccess, "YieldFlow: withdraw failed");
        
        uint256 withdrawn = abi.decode(result, (uint256));
        
        emit Withdrawn(caller, token, withdrawn);
        
        return abi.encode(true, withdrawn);
    }
    
    /// @notice Withdraw all tokens from Aave
    function _withdrawAll(address caller, bytes memory params) internal returns (bytes memory) {
        address token = abi.decode(params, (address));
        
        // Get aToken address and balance
        address aToken = _getAToken(token);
        
        (, bytes memory balanceData) = aToken.staticcall(
            abi.encodeWithSignature("balanceOf(address)", caller)
        );
        uint256 bal = abi.decode(balanceData, (uint256));
        
        if (bal == 0) {
            return abi.encode(true, uint256(0));
        }
        
        // Withdraw all
        return _withdraw(caller, abi.encode(token, bal));
    }
    
    /// @notice Get balance in Aave (aToken balance)
    function _getBalance(bytes memory params) internal view returns (bytes memory) {
        (address token, address account) = abi.decode(params, (address, address));
        
        address aToken = _getAToken(token);
        
        (, bytes memory balanceData) = aToken.staticcall(
            abi.encodeWithSignature("balanceOf(address)", account)
        );
        uint256 bal = abi.decode(balanceData, (uint256));
        
        return abi.encode(bal);
    }
    
    /// @notice Get aToken address for underlying token
    function _getAToken(address token) internal view returns (address) {
        // Call getReserveData and extract aToken address
        (bool success, bytes memory data) = aavePool.staticcall(
            abi.encodeWithSignature("getReserveData(address)", token)
        );
        require(success, "YieldFlow: getReserveData failed");
        
        // ReserveData struct - aTokenAddress is the 8th field (index 7)
        // Each field is 32 bytes, so offset = 32 * 7 = 224
        // Plus 32 bytes for the data length prefix = 256
        address aToken;
        assembly {
            aToken := mload(add(data, 256))
        }
        
        require(aToken != address(0), "YieldFlow: no aToken");
        return aToken;
    }
    
    // Direct convenience functions
    
    function deposit(address token, uint256 amount) external returns (bool, uint256) {
        bytes memory result = _deposit(msg.sender, abi.encode(token, amount));
        return abi.decode(result, (bool, uint256));
    }
    
    function withdraw(address token, uint256 amount) external returns (bool, uint256) {
        bytes memory result = _withdraw(msg.sender, abi.encode(token, amount));
        return abi.decode(result, (bool, uint256));
    }
    
    function withdrawAll(address token) external returns (bool, uint256) {
        bytes memory result = _withdrawAll(msg.sender, abi.encode(token));
        return abi.decode(result, (bool, uint256));
    }
    
    function balance(address token, address account) external view returns (uint256) {
        bytes memory result = _getBalance(abi.encode(token, account));
        return abi.decode(result, (uint256));
    }
}
