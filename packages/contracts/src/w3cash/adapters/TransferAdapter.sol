// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title TransferAdapter
 * @notice Action adapter for ERC20 token transfers
 * @dev Transfers tokens from the initiator to a recipient
 * 
 * The initiator must have approved this adapter to spend their tokens.
 * For gasless flows, use a permit signature or pre-approve the adapter.
 */
contract TransferAdapter is IAdapter {
    using SafeERC20 for IERC20;

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("TransferAdapter"));

    /// @notice Processor address (only processor can call execute)
    address public immutable processor;

    error OnlyProcessor();
    error TransferFailed();

    constructor(address _processor) {
        processor = _processor;
    }

    /**
     * @notice Execute a token transfer
     * @param initiator The address that signed the intent (token sender)
     * @param input ABI-encoded TransferParams: (token, to, amount)
     * @return Empty bytes on success
     */
    function execute(address initiator, bytes calldata input) external payable override returns (bytes memory) {
        if (msg.sender != processor) revert OnlyProcessor();

        (
            address token,
            address to,
            uint256 amount
        ) = abi.decode(input, (address, address, uint256));

        // Transfer from initiator to recipient
        IERC20(token).safeTransferFrom(initiator, to, amount);

        return "";
    }

    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    // Not used for action adapters
    function send(bytes memory, uint8, uint64, uint112) external payable override returns (uint64) {
        return 0;
    }

    function estimateFee(uint8, uint112, uint256) external pure override returns (uint256) {
        return 0;
    }
}
