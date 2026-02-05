// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title ILido
/// @notice Minimal interface for Lido stETH
interface ILido {
    function submit(address _referral) external payable returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @title IWstETH
/// @notice Minimal interface for Lido wstETH wrapper
interface IWstETH {
    function wrap(uint256 _stETHAmount) external returns (uint256);
    function unwrap(uint256 _wstETHAmount) external returns (uint256);
    function getStETHByWstETH(uint256 _wstETHAmount) external view returns (uint256);
    function getWstETHByStETH(uint256 _stETHAmount) external view returns (uint256);
}

/// @title ICbETH
/// @notice Minimal interface for Coinbase cbETH
interface ICbETH {
    function mint(address to) external payable;
    function exchangeRate() external view returns (uint256);
}

/// @title IRocketPool
/// @notice Minimal interface for Rocket Pool rETH
interface IRocketPool {
    function deposit() external payable;
    function getExchangeRate() external view returns (uint256);
}

/**
 * @title StakeAdapter
 * @notice Action adapter for liquid staking protocols
 * @dev Supports Lido (stETH/wstETH), Coinbase (cbETH), and Rocket Pool (rETH)
 */
contract StakeAdapter is IAdapter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error StakeAdapter__OnlyProcessor();
    error StakeAdapter__InvalidOperation();
    error StakeAdapter__InvalidProtocol();
    error StakeAdapter__ZeroAmount();
    error StakeAdapter__StakeFailed();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("StakeAdapter"));
    
    /// @notice Operation selectors
    bytes4 public constant OP_STAKE_LIDO = 0x9fa6dd35; // stakeLido()
    bytes4 public constant OP_WRAP_STETH = 0xea598cb0; // wrapStETH(uint256)
    bytes4 public constant OP_UNWRAP_WSTETH = 0x8c25a153; // unwrapWstETH(uint256)
    bytes4 public constant OP_STAKE_CBETH = 0x7b939232; // stakeCbETH()
    bytes4 public constant OP_STAKE_RETH = 0x83f12fec; // stakeRocketPool()

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    address public immutable processor;
    
    // Lido addresses
    address public immutable stETH;
    address public immutable wstETH;
    
    // Coinbase cbETH
    address public immutable cbETH;
    
    // Rocket Pool
    address public immutable rocketDepositPool;
    address public immutable rETH;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address _processor,
        address _stETH,
        address _wstETH,
        address _cbETH,
        address _rocketDepositPool,
        address _rETH
    ) {
        processor = _processor;
        stETH = _stETH;
        wstETH = _wstETH;
        cbETH = _cbETH;
        rocketDepositPool = _rocketDepositPool;
        rETH = _rETH;
    }

    /*//////////////////////////////////////////////////////////////
                           ADAPTER INTERFACE
    //////////////////////////////////////////////////////////////*/

    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    function execute(address initiator, bytes calldata input) external payable override returns (bytes memory) {
        if (msg.sender != processor) revert StakeAdapter__OnlyProcessor();
        if (input.length < 4) revert StakeAdapter__InvalidOperation();

        bytes4 operation = bytes4(input[:4]);
        bytes calldata params = input[4:];

        if (operation == OP_STAKE_LIDO) {
            return _executeStakeLido(initiator, params);
        } else if (operation == OP_WRAP_STETH) {
            return _executeWrapStETH(initiator, params);
        } else if (operation == OP_UNWRAP_WSTETH) {
            return _executeUnwrapWstETH(initiator, params);
        } else if (operation == OP_STAKE_CBETH) {
            return _executeStakeCbETH(initiator, params);
        } else if (operation == OP_STAKE_RETH) {
            return _executeStakeRocketPool(initiator, params);
        } else {
            revert StakeAdapter__InvalidOperation();
        }
    }

    function send(bytes memory, uint8, uint64, uint112) external payable override returns (uint64) {
        return 0;
    }

    function estimateFee(uint8, uint112, uint256) external pure override returns (uint256) {
        return 0;
    }

    /// @notice Allow receiving ETH for staking
    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                          INTERNAL OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Stake ETH to Lido for stETH
    /// @param initiator The account staking
    /// @param params ABI encoded (uint256 ethAmount) - ETH must be sent with call
    function _executeStakeLido(address initiator, bytes calldata params) internal returns (bytes memory) {
        uint256 ethAmount = abi.decode(params, (uint256));
        
        if (ethAmount == 0) revert StakeAdapter__ZeroAmount();
        if (stETH == address(0)) revert StakeAdapter__InvalidProtocol();

        // Submit ETH to Lido
        uint256 stETHReceived = ILido(stETH).submit{ value: ethAmount }(address(0));
        
        // Transfer stETH to initiator
        IERC20(stETH).safeTransfer(initiator, stETHReceived);

        return abi.encode(stETHReceived);
    }

    /// @notice Wrap stETH to wstETH
    /// @param initiator The account wrapping
    /// @param params ABI encoded (uint256 stETHAmount)
    function _executeWrapStETH(address initiator, bytes calldata params) internal returns (bytes memory) {
        uint256 stETHAmount = abi.decode(params, (uint256));
        
        if (stETHAmount == 0) revert StakeAdapter__ZeroAmount();
        if (wstETH == address(0)) revert StakeAdapter__InvalidProtocol();

        // Transfer stETH from initiator
        IERC20(stETH).safeTransferFrom(initiator, address(this), stETHAmount);
        
        // Approve wstETH contract
        IERC20(stETH).forceApprove(wstETH, stETHAmount);
        
        // Wrap to wstETH
        uint256 wstETHReceived = IWstETH(wstETH).wrap(stETHAmount);
        
        // Transfer wstETH to initiator
        IERC20(wstETH).safeTransfer(initiator, wstETHReceived);

        return abi.encode(wstETHReceived);
    }

    /// @notice Unwrap wstETH to stETH
    /// @param initiator The account unwrapping
    /// @param params ABI encoded (uint256 wstETHAmount)
    function _executeUnwrapWstETH(address initiator, bytes calldata params) internal returns (bytes memory) {
        uint256 wstETHAmount = abi.decode(params, (uint256));
        
        if (wstETHAmount == 0) revert StakeAdapter__ZeroAmount();
        if (wstETH == address(0)) revert StakeAdapter__InvalidProtocol();

        // Transfer wstETH from initiator
        IERC20(wstETH).safeTransferFrom(initiator, address(this), wstETHAmount);
        
        // Unwrap to stETH
        uint256 stETHReceived = IWstETH(wstETH).unwrap(wstETHAmount);
        
        // Transfer stETH to initiator
        IERC20(stETH).safeTransfer(initiator, stETHReceived);

        return abi.encode(stETHReceived);
    }

    /// @notice Stake ETH to Coinbase for cbETH
    /// @param initiator The account staking
    /// @param params ABI encoded (uint256 ethAmount) - ETH must be sent with call
    function _executeStakeCbETH(address initiator, bytes calldata params) internal returns (bytes memory) {
        uint256 ethAmount = abi.decode(params, (uint256));
        
        if (ethAmount == 0) revert StakeAdapter__ZeroAmount();
        if (cbETH == address(0)) revert StakeAdapter__InvalidProtocol();

        // Get balance before
        uint256 balanceBefore = IERC20(cbETH).balanceOf(address(this));
        
        // Mint cbETH
        ICbETH(cbETH).mint{ value: ethAmount }(address(this));
        
        // Calculate received
        uint256 cbETHReceived = IERC20(cbETH).balanceOf(address(this)) - balanceBefore;
        
        // Transfer cbETH to initiator
        IERC20(cbETH).safeTransfer(initiator, cbETHReceived);

        return abi.encode(cbETHReceived);
    }

    /// @notice Stake ETH to Rocket Pool for rETH
    /// @param initiator The account staking
    /// @param params ABI encoded (uint256 ethAmount) - ETH must be sent with call
    function _executeStakeRocketPool(address initiator, bytes calldata params) internal returns (bytes memory) {
        uint256 ethAmount = abi.decode(params, (uint256));
        
        if (ethAmount == 0) revert StakeAdapter__ZeroAmount();
        if (rocketDepositPool == address(0)) revert StakeAdapter__InvalidProtocol();

        // Get balance before
        uint256 balanceBefore = IERC20(rETH).balanceOf(address(this));
        
        // Deposit to Rocket Pool
        IRocketPool(rocketDepositPool).deposit{ value: ethAmount }();
        
        // Calculate received
        uint256 rETHReceived = IERC20(rETH).balanceOf(address(this)) - balanceBefore;
        
        // Transfer rETH to initiator
        IERC20(rETH).safeTransfer(initiator, rETHReceived);

        return abi.encode(rETHReceived);
    }
}
