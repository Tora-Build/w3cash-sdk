// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title IAavePoolLiquidate
/// @notice Interface for Aave V3 Pool liquidation
interface IAavePoolLiquidate {
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external;
}

/// @title LiquidateAdapter
/// @notice Adapter for liquidating underwater positions on Aave V3
/// @dev Allows liquidators to liquidate positions when health factor < 1
contract LiquidateAdapter is IAdapter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error LiquidateAdapter__CallerNotProcessor();
    error LiquidateAdapter__ZeroAmount();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("LiquidateAdapter"));

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The Aave V3 Pool contract
    IAavePoolLiquidate public immutable pool;

    /// @notice The authorized Processor contract
    address public immutable processor;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyProcessor() {
        if (msg.sender != processor) revert LiquidateAdapter__CallerNotProcessor();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _pool The Aave V3 Pool address
    /// @param _processor The authorized Processor address
    constructor(address _pool, address _processor) {
        pool = IAavePoolLiquidate(_pool);
        processor = _processor;
    }

    /*//////////////////////////////////////////////////////////////
                           ADAPTER INTERFACE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAdapter
    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    /// @notice Execute a liquidation
    /// @param account The account performing the liquidation (receives collateral)
    /// @param data ABI encoded (address collateralAsset, address debtAsset, address userToLiquidate, uint256 debtToCover, bool receiveAToken)
    /// @return Empty bytes
    function execute(
        address account,
        bytes calldata data
    ) external payable override onlyProcessor returns (bytes memory) {
        (
            address collateralAsset,
            address debtAsset,
            address userToLiquidate,
            uint256 debtToCover,
            bool receiveAToken
        ) = abi.decode(data, (address, address, address, uint256, bool));

        if (debtToCover == 0) revert LiquidateAdapter__ZeroAmount();

        // Transfer debt tokens from liquidator to adapter
        IERC20(debtAsset).safeTransferFrom(account, address(this), debtToCover);

        // Approve pool to spend debt tokens
        IERC20(debtAsset).forceApprove(address(pool), debtToCover);

        // Execute liquidation
        pool.liquidationCall(
            collateralAsset,
            debtAsset,
            userToLiquidate,
            debtToCover,
            receiveAToken
        );

        // Transfer received collateral to liquidator
        uint256 collateralBalance = IERC20(collateralAsset).balanceOf(address(this));
        if (collateralBalance > 0) {
            IERC20(collateralAsset).safeTransfer(account, collateralBalance);
        }

        return abi.encode(collateralBalance);
    }

    /// @inheritdoc IAdapter
    function send(bytes memory, uint8, uint64, uint112) external payable override returns (uint64) {
        revert("LiquidateAdapter: send not supported");
    }

    /// @inheritdoc IAdapter
    function estimateFee(uint8, uint112, uint256) external pure override returns (uint256) {
        return 0;
    }
}
