// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title IBurnable
/// @notice Interface for burnable tokens
interface IBurnable {
    function burn(uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
}

/// @title BurnAdapter
/// @notice Adapter for burning ERC20 tokens
/// @dev Supports both standard burn and burnFrom patterns
contract BurnAdapter is IAdapter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error BurnAdapter__CallerNotProcessor();
    error BurnAdapter__ZeroAmount();
    error BurnAdapter__BurnFailed();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("BurnAdapter"));

    /// @notice Burn methods
    uint8 public constant METHOD_BURN = 0;          // burn(amount) - requires transfer first
    uint8 public constant METHOD_BURN_FROM = 1;     // burnFrom(account, amount) - requires approval
    uint8 public constant METHOD_TRANSFER_DEAD = 2; // Transfer to dead address

    /// @notice Dead address for tokens that don't support burn
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The authorized Processor contract
    address public immutable processor;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyProcessor() {
        if (msg.sender != processor) revert BurnAdapter__CallerNotProcessor();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _processor The authorized Processor address
    constructor(address _processor) {
        processor = _processor;
    }

    /*//////////////////////////////////////////////////////////////
                           ADAPTER INTERFACE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAdapter
    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    /// @notice Execute a burn operation
    /// @param account The account burning tokens
    /// @param data ABI encoded (address token, uint256 amount, uint8 method)
    ///        method: 0 = burn(), 1 = burnFrom(), 2 = transfer to dead address
    /// @return ABI encoded burned amount
    function execute(
        address account,
        bytes calldata data
    ) external payable override onlyProcessor returns (bytes memory) {
        (
            address token,
            uint256 amount,
            uint8 method
        ) = abi.decode(data, (address, uint256, uint8));

        if (amount == 0) revert BurnAdapter__ZeroAmount();

        if (method == METHOD_BURN) {
            // Transfer to adapter, then burn
            IERC20(token).safeTransferFrom(account, address(this), amount);
            IBurnable(token).burn(amount);
        } else if (method == METHOD_BURN_FROM) {
            // Burn directly from account (requires approval to adapter)
            IBurnable(token).burnFrom(account, amount);
        } else if (method == METHOD_TRANSFER_DEAD) {
            // Fallback: transfer to dead address
            IERC20(token).safeTransferFrom(account, DEAD_ADDRESS, amount);
        } else {
            revert BurnAdapter__BurnFailed();
        }

        return abi.encode(amount);
    }

    /// @inheritdoc IAdapter
    function send(bytes memory, uint8, uint64, uint112) external payable override returns (uint64) {
        revert("BurnAdapter: send not supported");
    }

    /// @inheritdoc IAdapter
    function estimateFee(uint8, uint112, uint256) external pure override returns (uint256) {
        return 0;
    }
}
