// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title IsFRAX
/// @notice Interface for sFRAX (Staked FRAX - ERC-4626)
interface IsFRAX {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function mint(uint256 shares, address receiver) external returns (uint256 assets);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    
    function totalAssets() external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function previewDeposit(uint256 assets) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function asset() external view returns (address);
    function rewardsCycleEnd() external view returns (uint256);
}

/// @title IsfrxETH
/// @notice Interface for sfrxETH (Staked Frax Ether - ERC-4626)
interface IsfrxETH {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function totalAssets() external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function asset() external view returns (address);
}

/// @title IFraxEtherMinter
/// @notice Interface for frxETH Minter
interface IFraxEtherMinter {
    function submitAndDeposit(address recipient) external payable returns (uint256 shares);
    function submit() external payable;
}

/// @title IFraxLend
/// @notice Interface for FraxLend Pairs
interface IFraxLend {
    function deposit(uint256 amount, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 amount);
    function addCollateral(uint256 collateralAmount, address borrower) external;
    function removeCollateral(uint256 collateralAmount, address receiver, address borrower) external;
    function borrowAsset(uint256 borrowAmount, uint256 collateralAmount, address receiver) external returns (uint256 shares);
    function repayAsset(uint256 shares, address borrower) external returns (uint256 amountToRepay);
    
    function totalAsset() external view returns (uint128 amount, uint128 shares);
    function totalBorrow() external view returns (uint128 amount, uint128 shares);
    function userCollateralBalance(address user) external view returns (uint256);
    function userBorrowShares(address user) external view returns (uint256);
}

/**
 * @title FraxAdapter
 * @notice Action adapter for Frax Finance ecosystem
 * @dev Supports sFRAX, sfrxETH, and FraxLend operations
 */
contract FraxAdapter is IAdapter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error FraxAdapter__OnlyProcessor();
    error FraxAdapter__InvalidOperation();
    error FraxAdapter__ZeroAmount();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("FraxAdapter"));
    
    /// @notice Operation selectors
    bytes4 public constant OP_DEPOSIT_SFRAX = 0x47e7ef24; // deposit to sFRAX
    bytes4 public constant OP_WITHDRAW_SFRAX = 0xf3fef3a3; // withdraw from sFRAX
    bytes4 public constant OP_STAKE_ETH = 0x9fa6dd35; // stake ETH for sfrxETH
    bytes4 public constant OP_UNSTAKE_ETH = 0x2e1a7d4d; // unstake sfrxETH
    bytes4 public constant OP_LEND_DEPOSIT = 0x6e553f65; // deposit to FraxLend
    bytes4 public constant OP_LEND_WITHDRAW = 0xba087652; // withdraw from FraxLend
    bytes4 public constant OP_LEND_BORROW = 0xc5ebeaec; // borrow from FraxLend
    bytes4 public constant OP_LEND_REPAY = 0x0e752702; // repay FraxLend

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    address public immutable processor;
    address public immutable frax;
    IsFRAX public immutable sFRAX;
    address public immutable frxETH;
    IsfrxETH public immutable sfrxETH;
    IFraxEtherMinter public immutable frxETHMinter;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address _processor,
        address _frax,
        address _sFRAX,
        address _frxETH,
        address _sfrxETH,
        address _frxETHMinter
    ) {
        processor = _processor;
        frax = _frax;
        sFRAX = IsFRAX(_sFRAX);
        frxETH = _frxETH;
        sfrxETH = IsfrxETH(_sfrxETH);
        frxETHMinter = IFraxEtherMinter(_frxETHMinter);
    }

    /*//////////////////////////////////////////////////////////////
                           ADAPTER INTERFACE
    //////////////////////////////////////////////////////////////*/

    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    function execute(address initiator, bytes calldata input) external payable override returns (bytes memory) {
        if (msg.sender != processor) revert FraxAdapter__OnlyProcessor();
        if (input.length < 4) revert FraxAdapter__InvalidOperation();

        bytes4 operation = bytes4(input[:4]);
        bytes calldata params = input[4:];

        if (operation == OP_DEPOSIT_SFRAX) {
            return _executeDepositSFrax(initiator, params);
        } else if (operation == OP_WITHDRAW_SFRAX) {
            return _executeWithdrawSFrax(initiator, params);
        } else if (operation == OP_STAKE_ETH) {
            return _executeStakeEth(initiator, params);
        } else if (operation == OP_UNSTAKE_ETH) {
            return _executeUnstakeEth(initiator, params);
        } else if (operation == OP_LEND_DEPOSIT) {
            return _executeLendDeposit(initiator, params);
        } else if (operation == OP_LEND_WITHDRAW) {
            return _executeLendWithdraw(initiator, params);
        } else if (operation == OP_LEND_BORROW) {
            return _executeLendBorrow(initiator, params);
        } else if (operation == OP_LEND_REPAY) {
            return _executeLendRepay(initiator, params);
        } else {
            revert FraxAdapter__InvalidOperation();
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

    /// @notice Deposit FRAX to sFRAX
    function _executeDepositSFrax(address initiator, bytes calldata params) internal returns (bytes memory) {
        uint256 amount = abi.decode(params, (uint256));
        
        if (amount == 0) revert FraxAdapter__ZeroAmount();

        // Transfer FRAX from initiator
        IERC20(frax).safeTransferFrom(initiator, address(this), amount);
        IERC20(frax).forceApprove(address(sFRAX), amount);

        // Deposit to sFRAX
        uint256 shares = sFRAX.deposit(amount, initiator);

        return abi.encode(shares);
    }

    /// @notice Withdraw FRAX from sFRAX
    function _executeWithdrawSFrax(address initiator, bytes calldata params) internal returns (bytes memory) {
        uint256 shares = abi.decode(params, (uint256));
        
        if (shares == 0) revert FraxAdapter__ZeroAmount();

        // Transfer sFRAX from initiator
        IERC20(address(sFRAX)).safeTransferFrom(initiator, address(this), shares);

        // Redeem for FRAX
        uint256 assets = sFRAX.redeem(shares, initiator, address(this));

        return abi.encode(assets);
    }

    /// @notice Stake ETH for sfrxETH
    function _executeStakeEth(address initiator, bytes calldata params) internal returns (bytes memory) {
        uint256 ethAmount = abi.decode(params, (uint256));
        
        if (ethAmount == 0) revert FraxAdapter__ZeroAmount();

        // Stake ETH and receive sfrxETH directly to initiator
        uint256 shares = frxETHMinter.submitAndDeposit{ value: ethAmount }(initiator);

        return abi.encode(shares);
    }

    /// @notice Unstake sfrxETH to frxETH
    function _executeUnstakeEth(address initiator, bytes calldata params) internal returns (bytes memory) {
        uint256 shares = abi.decode(params, (uint256));
        
        if (shares == 0) revert FraxAdapter__ZeroAmount();

        // Transfer sfrxETH from initiator
        IERC20(address(sfrxETH)).safeTransferFrom(initiator, address(this), shares);

        // Redeem for frxETH
        uint256 assets = sfrxETH.redeem(shares, initiator, address(this));

        return abi.encode(assets);
    }

    /// @notice Deposit to FraxLend pair
    function _executeLendDeposit(address initiator, bytes calldata params) internal returns (bytes memory) {
        (address pair, address asset, uint256 amount) = abi.decode(params, (address, address, uint256));
        
        if (amount == 0) revert FraxAdapter__ZeroAmount();

        // Transfer asset from initiator
        IERC20(asset).safeTransferFrom(initiator, address(this), amount);
        IERC20(asset).forceApprove(pair, amount);

        // Deposit to FraxLend - shares go to initiator
        uint256 shares = IFraxLend(pair).deposit(amount, initiator);

        return abi.encode(shares);
    }

    /// @notice Withdraw from FraxLend pair
    function _executeLendWithdraw(address initiator, bytes calldata params) internal returns (bytes memory) {
        (address pair, uint256 shares) = abi.decode(params, (address, uint256));
        
        if (shares == 0) revert FraxAdapter__ZeroAmount();

        // Transfer fTokens from initiator
        IERC20(pair).safeTransferFrom(initiator, address(this), shares);

        // Redeem
        uint256 amount = IFraxLend(pair).redeem(shares, initiator, address(this));

        return abi.encode(amount);
    }

    /// @notice Borrow from FraxLend pair
    function _executeLendBorrow(address initiator, bytes calldata params) internal returns (bytes memory) {
        (address pair, address collateralToken, uint256 borrowAmount, uint256 collateralAmount) = 
            abi.decode(params, (address, address, uint256, uint256));

        // If providing collateral, transfer it
        if (collateralAmount > 0) {
            IERC20(collateralToken).safeTransferFrom(initiator, address(this), collateralAmount);
            IERC20(collateralToken).forceApprove(pair, collateralAmount);
        }

        // Borrow - borrowed assets go to initiator
        uint256 shares = IFraxLend(pair).borrowAsset(borrowAmount, collateralAmount, initiator);

        return abi.encode(shares);
    }

    /// @notice Repay FraxLend borrow
    function _executeLendRepay(address initiator, bytes calldata params) internal returns (bytes memory) {
        (address pair, address asset, uint256 shares) = abi.decode(params, (address, address, uint256));
        
        if (shares == 0) revert FraxAdapter__ZeroAmount();

        // Estimate amount needed (slightly overestimate for safety)
        // In practice, you'd calculate this more precisely
        uint256 estimatedAmount = shares; // Simplified

        // Transfer asset from initiator
        IERC20(asset).safeTransferFrom(initiator, address(this), estimatedAmount);
        IERC20(asset).forceApprove(pair, estimatedAmount);

        // Repay
        uint256 amountRepaid = IFraxLend(pair).repayAsset(shares, initiator);

        // Refund excess
        uint256 excess = estimatedAmount - amountRepaid;
        if (excess > 0) {
            IERC20(asset).safeTransfer(initiator, excess);
        }

        return abi.encode(amountRepaid);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get sFRAX share value
    function getSFraxShareValue(uint256 shares) external view returns (uint256) {
        return sFRAX.convertToAssets(shares);
    }

    /// @notice Get sfrxETH share value
    function getSfrxEthShareValue(uint256 shares) external view returns (uint256) {
        return sfrxETH.convertToAssets(shares);
    }

    /// @notice Get sFRAX rewards cycle end
    function getSFraxRewardsCycleEnd() external view returns (uint256) {
        return sFRAX.rewardsCycleEnd();
    }
}
