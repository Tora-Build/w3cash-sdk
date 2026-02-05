// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title ISparkPool
/// @notice Interface for Spark Protocol Pool (Aave V3 fork on MakerDAO)
interface ISparkPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function borrow(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        uint16 referralCode,
        address onBehalfOf
    ) external;
    function repay(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        address onBehalfOf
    ) external returns (uint256);
    function setUserUseReserveAsCollateral(address asset, bool useAsCollateral) external;
    
    function getUserAccountData(address user) external view returns (
        uint256 totalCollateralBase,
        uint256 totalDebtBase,
        uint256 availableBorrowsBase,
        uint256 currentLiquidationThreshold,
        uint256 ltv,
        uint256 healthFactor
    );
}

/// @title ISparkRewardsController
/// @notice Interface for Spark Rewards Controller
interface ISparkRewardsController {
    function claimAllRewards(address[] calldata assets, address to) 
        external returns (address[] memory rewardsList, uint256[] memory claimedAmounts);
    function claimAllRewardsToSelf(address[] calldata assets) 
        external returns (address[] memory rewardsList, uint256[] memory claimedAmounts);
    function getUserRewards(address[] calldata assets, address user, address reward) 
        external view returns (uint256);
}

/**
 * @title SparkAdapter
 * @notice Action adapter for Spark Protocol (MakerDAO's Aave V3 fork)
 * @dev Supports supply, withdraw, borrow, repay, and rewards claiming
 */
contract SparkAdapter is IAdapter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error SparkAdapter__OnlyProcessor();
    error SparkAdapter__InvalidOperation();
    error SparkAdapter__ZeroAmount();
    error SparkAdapter__InvalidAsset();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("SparkAdapter"));
    uint16 public constant REFERRAL_CODE = 0;
    
    /// @notice Interest rate modes
    uint256 public constant VARIABLE_RATE = 2;
    uint256 public constant STABLE_RATE = 1;
    
    /// @notice Operation selectors
    bytes4 public constant OP_SUPPLY = 0x47e7ef24; // deposit(address,uint256)
    bytes4 public constant OP_WITHDRAW = 0xf3fef3a3; // withdraw(address,uint256)
    bytes4 public constant OP_BORROW = 0xc5ebeaec; // borrow(uint256)
    bytes4 public constant OP_REPAY = 0x0e752702; // repayBorrow(uint256)
    bytes4 public constant OP_SET_COLLATERAL = 0xa8c62e76; // setUserUseReserveAsCollateral(address,bool)
    bytes4 public constant OP_CLAIM_REWARDS = 0x4e71d92d; // claimAllRewards(...)

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    address public immutable processor;
    ISparkPool public immutable pool;
    ISparkRewardsController public immutable rewardsController;
    
    /// @notice Mapping from underlying to spToken
    mapping(address => address) public spTokens;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address _processor,
        address _pool,
        address _rewardsController
    ) {
        processor = _processor;
        pool = ISparkPool(_pool);
        rewardsController = ISparkRewardsController(_rewardsController);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Register a spToken for an underlying asset
    function registerSpToken(address underlying, address spToken) external {
        // In production, this should be access controlled
        spTokens[underlying] = spToken;
    }

    /*//////////////////////////////////////////////////////////////
                           ADAPTER INTERFACE
    //////////////////////////////////////////////////////////////*/

    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    function execute(address initiator, bytes calldata input) external payable override returns (bytes memory) {
        if (msg.sender != processor) revert SparkAdapter__OnlyProcessor();
        if (input.length < 4) revert SparkAdapter__InvalidOperation();

        bytes4 operation = bytes4(input[:4]);
        bytes calldata params = input[4:];

        if (operation == OP_SUPPLY) {
            return _executeSupply(initiator, params);
        } else if (operation == OP_WITHDRAW) {
            return _executeWithdraw(initiator, params);
        } else if (operation == OP_BORROW) {
            return _executeBorrow(initiator, params);
        } else if (operation == OP_REPAY) {
            return _executeRepay(initiator, params);
        } else if (operation == OP_SET_COLLATERAL) {
            return _executeSetCollateral(params);
        } else if (operation == OP_CLAIM_REWARDS) {
            return _executeClaimRewards(initiator, params);
        } else {
            revert SparkAdapter__InvalidOperation();
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

    /// @notice Supply assets to Spark
    function _executeSupply(address initiator, bytes calldata params) internal returns (bytes memory) {
        (address asset, uint256 amount) = abi.decode(params, (address, uint256));
        
        if (amount == 0) revert SparkAdapter__ZeroAmount();

        // Transfer assets from initiator
        IERC20(asset).safeTransferFrom(initiator, address(this), amount);
        IERC20(asset).forceApprove(address(pool), amount);

        // Supply to Spark - spTokens go to initiator
        pool.supply(asset, amount, initiator, REFERRAL_CODE);

        return abi.encode(amount);
    }

    /// @notice Withdraw assets from Spark
    function _executeWithdraw(address initiator, bytes calldata params) internal returns (bytes memory) {
        (address asset, uint256 amount) = abi.decode(params, (address, uint256));
        
        if (amount == 0) revert SparkAdapter__ZeroAmount();

        address spToken = spTokens[asset];
        if (spToken == address(0)) revert SparkAdapter__InvalidAsset();

        // Transfer spTokens from initiator
        IERC20(spToken).safeTransferFrom(initiator, address(this), amount);

        // Withdraw - assets go to initiator
        uint256 withdrawn = pool.withdraw(asset, amount, initiator);

        return abi.encode(withdrawn);
    }

    /// @notice Borrow assets from Spark
    function _executeBorrow(address initiator, bytes calldata params) internal returns (bytes memory) {
        (address asset, uint256 amount, uint256 interestRateMode) = 
            abi.decode(params, (address, uint256, uint256));
        
        if (amount == 0) revert SparkAdapter__ZeroAmount();

        // Borrow - assets go to initiator
        // Note: initiator must have supplied collateral beforehand
        pool.borrow(
            asset,
            amount,
            interestRateMode > 0 ? interestRateMode : VARIABLE_RATE,
            REFERRAL_CODE,
            initiator
        );

        return abi.encode(amount);
    }

    /// @notice Repay borrowed assets
    function _executeRepay(address initiator, bytes calldata params) internal returns (bytes memory) {
        (address asset, uint256 amount, uint256 interestRateMode) = 
            abi.decode(params, (address, uint256, uint256));
        
        if (amount == 0) revert SparkAdapter__ZeroAmount();

        // Transfer assets from initiator
        IERC20(asset).safeTransferFrom(initiator, address(this), amount);
        IERC20(asset).forceApprove(address(pool), amount);

        // Repay
        uint256 repaid = pool.repay(
            asset,
            amount,
            interestRateMode > 0 ? interestRateMode : VARIABLE_RATE,
            initiator
        );

        // Refund excess if repaying more than debt
        if (repaid < amount) {
            IERC20(asset).safeTransfer(initiator, amount - repaid);
        }

        return abi.encode(repaid);
    }

    /// @notice Set asset as collateral
    function _executeSetCollateral(bytes calldata params) internal returns (bytes memory) {
        (address asset, bool useAsCollateral) = abi.decode(params, (address, bool));

        pool.setUserUseReserveAsCollateral(asset, useAsCollateral);

        return abi.encode(true);
    }

    /// @notice Claim all rewards
    function _executeClaimRewards(address initiator, bytes calldata params) internal returns (bytes memory) {
        address[] memory assets = abi.decode(params, (address[]));

        (address[] memory rewardsList, uint256[] memory amounts) = 
            rewardsController.claimAllRewards(assets, initiator);

        return abi.encode(rewardsList, amounts);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get user account data
    function getUserAccountData(address user) external view returns (
        uint256 totalCollateralBase,
        uint256 totalDebtBase,
        uint256 availableBorrowsBase,
        uint256 currentLiquidationThreshold,
        uint256 ltv,
        uint256 healthFactor
    ) {
        return pool.getUserAccountData(user);
    }

    /// @notice Get pending rewards for a user
    function getPendingRewards(address[] calldata assets, address user, address reward) external view returns (uint256) {
        return rewardsController.getUserRewards(assets, user, reward);
    }

    /// @notice Get spToken balance for an underlying asset
    function getSpTokenBalance(address underlying, address user) external view returns (uint256) {
        address spToken = spTokens[underlying];
        if (spToken == address(0)) return 0;
        return IERC20(spToken).balanceOf(user);
    }
}
