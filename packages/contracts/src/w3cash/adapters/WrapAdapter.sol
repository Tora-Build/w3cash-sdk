// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title WrapAdapter
 * @notice Action adapter for wrapping/unwrapping ETH to WETH
 * @dev Handles deposit (ETH→WETH) and withdraw (WETH→ETH)
 */
contract WrapAdapter is IAdapter {
    using SafeERC20 for IERC20;

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("WrapAdapter"));
    address public immutable processor;
    address public immutable weth;

    error OnlyProcessor();

    constructor(address _weth, address _processor) {
        weth = _weth;
        processor = _processor;
    }

    /**
     * @notice Execute wrap or unwrap
     * @param initiator The address that signed the intent
     * @param input ABI-encoded WrapParams: (isWrap, amount)
     *        isWrap=true: deposit ETH to get WETH
     *        isWrap=false: withdraw WETH to get ETH
     * @return Empty bytes on success
     */
    function execute(address initiator, bytes calldata input) external payable override returns (bytes memory) {
        if (msg.sender != processor) revert OnlyProcessor();

        (bool isWrap, uint256 amount) = abi.decode(input, (bool, uint256));

        if (isWrap) {
            // Wrap: deposit ETH, receive WETH
            uint256 ethToWrap = msg.value > 0 ? msg.value : amount;
            require(address(this).balance >= ethToWrap, "Insufficient ETH");
            IWETH(weth).deposit{value: ethToWrap}();
            // Transfer WETH to initiator (use SafeERC20)
            IERC20(weth).safeTransfer(initiator, ethToWrap);
        } else {
            // Unwrap: WETH → ETH
            // Pull WETH from initiator (use SafeERC20)
            IERC20(weth).safeTransferFrom(initiator, address(this), amount);
            // Withdraw to ETH
            IWETH(weth).withdraw(amount);
            // Send ETH to initiator
            (bool success, ) = initiator.call{value: amount}("");
            require(success, "ETH transfer failed");
        }

        return "";
    }

    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    function send(bytes memory, uint8, uint64, uint112) external payable override returns (uint64) {
        return 0;
    }

    function estimateFee(uint8, uint112, uint256) external pure override returns (uint256) {
        return 0;
    }

    receive() external payable {}
}

/// @notice WETH interface
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}
