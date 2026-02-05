// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title IL1StandardBridge
/// @notice Interface for Optimism L1 Standard Bridge
interface IL1StandardBridge {
    function depositETH(uint32 _minGasLimit, bytes calldata _extraData) external payable;
    function depositETHTo(address _to, uint32 _minGasLimit, bytes calldata _extraData) external payable;
    function depositERC20(
        address _l1Token,
        address _l2Token,
        uint256 _amount,
        uint32 _minGasLimit,
        bytes calldata _extraData
    ) external;
    function depositERC20To(
        address _l1Token,
        address _l2Token,
        address _to,
        uint256 _amount,
        uint32 _minGasLimit,
        bytes calldata _extraData
    ) external;
}

/// @title IL2StandardBridge
/// @notice Interface for Optimism L2 Standard Bridge (for withdrawals from L2)
interface IL2StandardBridge {
    function withdraw(
        address _l2Token,
        uint256 _amount,
        uint32 _minGasLimit,
        bytes calldata _extraData
    ) external payable;
    function withdrawTo(
        address _l2Token,
        address _to,
        uint256 _amount,
        uint32 _minGasLimit,
        bytes calldata _extraData
    ) external payable;
}

/// @title IOptimismPortal
/// @notice Interface for Optimism Portal (message passing)
interface IOptimismPortal {
    function depositTransaction(
        address _to,
        uint256 _value,
        uint64 _gasLimit,
        bool _isCreation,
        bytes memory _data
    ) external payable;
    
    function finalizeWithdrawalTransaction(
        uint256 _nonce,
        address _sender,
        address _target,
        uint256 _value,
        uint256 _gasLimit,
        bytes calldata _data
    ) external;
}

/**
 * @title OptimismBridgeAdapter
 * @notice Action adapter for Optimism Native Bridge (L1 <-> L2)
 * @dev Supports ETH and ERC20 deposits/withdrawals via official Optimism bridge
 */
contract OptimismBridgeAdapter is IAdapter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error OptimismBridgeAdapter__OnlyProcessor();
    error OptimismBridgeAdapter__InvalidOperation();
    error OptimismBridgeAdapter__ZeroAmount();
    error OptimismBridgeAdapter__InvalidToken();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("OptimismBridgeAdapter"));
    uint32 public constant DEFAULT_GAS_LIMIT = 200000;
    
    /// @notice Operation selectors
    bytes4 public constant OP_DEPOSIT_ETH = 0x9a2ac6d5; // depositETH(...)
    bytes4 public constant OP_DEPOSIT_ERC20 = 0x58a997f6; // depositERC20(...)
    bytes4 public constant OP_WITHDRAW = 0x2e1a7d4d; // withdraw(...)
    bytes4 public constant OP_DEPOSIT_TX = 0xe9e05c42; // depositTransaction(...)

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    address public immutable processor;
    IL1StandardBridge public immutable l1Bridge;
    IL2StandardBridge public immutable l2Bridge;
    IOptimismPortal public immutable portal;
    bool public immutable isL1; // true if deployed on L1, false if on L2
    
    /// @notice L1 to L2 token mapping
    mapping(address => address) public l1ToL2Token;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address _processor,
        address _l1Bridge,
        address _l2Bridge,
        address _portal,
        bool _isL1
    ) {
        processor = _processor;
        l1Bridge = IL1StandardBridge(_l1Bridge);
        l2Bridge = IL2StandardBridge(_l2Bridge);
        portal = IOptimismPortal(_portal);
        isL1 = _isL1;
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Register L1 to L2 token mapping
    function registerTokenPair(address l1Token, address l2Token) external {
        // In production, this should be access controlled
        l1ToL2Token[l1Token] = l2Token;
    }

    /*//////////////////////////////////////////////////////////////
                           ADAPTER INTERFACE
    //////////////////////////////////////////////////////////////*/

    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    function execute(address initiator, bytes calldata input) external payable override returns (bytes memory) {
        if (msg.sender != processor) revert OptimismBridgeAdapter__OnlyProcessor();
        if (input.length < 4) revert OptimismBridgeAdapter__InvalidOperation();

        bytes4 operation = bytes4(input[:4]);
        bytes calldata params = input[4:];

        if (operation == OP_DEPOSIT_ETH) {
            return _executeDepositETH(initiator, params);
        } else if (operation == OP_DEPOSIT_ERC20) {
            return _executeDepositERC20(initiator, params);
        } else if (operation == OP_WITHDRAW) {
            return _executeWithdraw(initiator, params);
        } else if (operation == OP_DEPOSIT_TX) {
            return _executeDepositTransaction(initiator, params);
        } else {
            revert OptimismBridgeAdapter__InvalidOperation();
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

    /// @notice Deposit ETH to L2 (L1 only)
    function _executeDepositETH(address initiator, bytes calldata params) internal returns (bytes memory) {
        (address recipient, uint32 minGasLimit) = abi.decode(params, (address, uint32));
        
        if (msg.value == 0) revert OptimismBridgeAdapter__ZeroAmount();

        uint32 gasLimit = minGasLimit > 0 ? minGasLimit : DEFAULT_GAS_LIMIT;
        
        // If recipient is zero, send to initiator on L2
        address to = recipient == address(0) ? initiator : recipient;

        // Deposit ETH
        l1Bridge.depositETHTo{ value: msg.value }(to, gasLimit, "");

        return abi.encode(msg.value);
    }

    /// @notice Deposit ERC20 to L2 (L1 only)
    function _executeDepositERC20(address initiator, bytes calldata params) internal returns (bytes memory) {
        (address l1Token, address recipient, uint256 amount, uint32 minGasLimit) = 
            abi.decode(params, (address, address, uint256, uint32));
        
        if (amount == 0) revert OptimismBridgeAdapter__ZeroAmount();

        address l2Token = l1ToL2Token[l1Token];
        if (l2Token == address(0)) revert OptimismBridgeAdapter__InvalidToken();

        uint32 gasLimit = minGasLimit > 0 ? minGasLimit : DEFAULT_GAS_LIMIT;
        address to = recipient == address(0) ? initiator : recipient;

        // Transfer tokens from initiator
        IERC20(l1Token).safeTransferFrom(initiator, address(this), amount);
        IERC20(l1Token).forceApprove(address(l1Bridge), amount);

        // Deposit ERC20
        l1Bridge.depositERC20To(l1Token, l2Token, to, amount, gasLimit, "");

        return abi.encode(amount);
    }

    /// @notice Withdraw tokens from L2 to L1 (L2 only)
    function _executeWithdraw(address initiator, bytes calldata params) internal returns (bytes memory) {
        (address l2Token, address recipient, uint256 amount, uint32 minGasLimit) = 
            abi.decode(params, (address, address, uint256, uint32));
        
        if (amount == 0) revert OptimismBridgeAdapter__ZeroAmount();

        uint32 gasLimit = minGasLimit > 0 ? minGasLimit : DEFAULT_GAS_LIMIT;
        address to = recipient == address(0) ? initiator : recipient;

        // If withdrawing ETH (l2Token is zero address or predeploy)
        if (l2Token == address(0)) {
            // Withdraw ETH
            l2Bridge.withdrawTo{ value: amount }(
                address(0), // ETH
                to,
                amount,
                gasLimit,
                ""
            );
        } else {
            // Withdraw ERC20
            IERC20(l2Token).safeTransferFrom(initiator, address(this), amount);
            IERC20(l2Token).forceApprove(address(l2Bridge), amount);
            
            l2Bridge.withdrawTo(l2Token, to, amount, gasLimit, "");
        }

        return abi.encode(amount);
    }

    /// @notice Execute arbitrary deposit transaction (advanced)
    function _executeDepositTransaction(address initiator, bytes calldata params) internal returns (bytes memory) {
        (address to, uint256 value, uint64 gasLimit, bytes memory data) = 
            abi.decode(params, (address, uint256, uint64, bytes));

        portal.depositTransaction{ value: value }(
            to,
            value,
            gasLimit,
            false, // not contract creation
            data
        );

        return abi.encode(true);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get L2 token for an L1 token
    function getL2Token(address l1Token) external view returns (address) {
        return l1ToL2Token[l1Token];
    }

    /// @notice Check if this is deployed on L1
    function isLayer1() external view returns (bool) {
        return isL1;
    }
}
