// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title IWETH
/// @notice Interface for WETH
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 value) external returns (bool);
}

/// @title UnwrapAdapter
/// @notice Explicit adapter for unwrapping WETH to ETH
/// @dev Complement to WrapAdapter, provides clearer intent
contract UnwrapAdapter is IAdapter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error UnwrapAdapter__CallerNotProcessor();
    error UnwrapAdapter__ZeroAmount();
    error UnwrapAdapter__TransferFailed();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("UnwrapAdapter"));

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The WETH contract address
    IWETH public immutable weth;

    /// @notice The authorized Processor contract
    address public immutable processor;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyProcessor() {
        if (msg.sender != processor) revert UnwrapAdapter__CallerNotProcessor();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _weth The WETH contract address
    /// @param _processor The authorized Processor address
    constructor(address _weth, address _processor) {
        weth = IWETH(_weth);
        processor = _processor;
    }

    /*//////////////////////////////////////////////////////////////
                           ADAPTER INTERFACE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAdapter
    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    /// @notice Unwrap WETH to ETH
    /// @param account The account unwrapping
    /// @param data ABI encoded (uint256 amount)
    ///        Use type(uint256).max for full balance
    /// @return ABI encoded unwrapped amount
    function execute(
        address account,
        bytes calldata data
    ) external payable override onlyProcessor returns (bytes memory) {
        uint256 amount = abi.decode(data, (uint256));

        // Handle max amount
        if (amount == type(uint256).max) {
            amount = weth.balanceOf(account);
        }

        if (amount == 0) revert UnwrapAdapter__ZeroAmount();

        // Transfer WETH from user to adapter
        IERC20(address(weth)).safeTransferFrom(account, address(this), amount);

        // Unwrap WETH to ETH
        weth.withdraw(amount);

        // Send ETH to user
        (bool success, ) = account.call{value: amount}("");
        if (!success) revert UnwrapAdapter__TransferFailed();

        return abi.encode(amount);
    }

    /// @inheritdoc IAdapter
    function send(bytes memory, uint8, uint64, uint112) external payable override returns (uint64) {
        revert("UnwrapAdapter: send not supported");
    }

    /// @inheritdoc IAdapter
    function estimateFee(uint8, uint112, uint256) external pure override returns (uint256) {
        return 0;
    }

    /// @notice Receive ETH from WETH contract
    receive() external payable {}
}
