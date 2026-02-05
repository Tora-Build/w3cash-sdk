// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ApproveAdapter
 * @notice Action adapter for ERC20 token approvals
 * @dev Sets allowance for a spender on behalf of the initiator's wallet
 */
contract ApproveAdapter is IAdapter {
    using SafeERC20 for IERC20;

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("ApproveAdapter"));
    address public immutable processor;

    error OnlyProcessor();

    constructor(address _processor) {
        processor = _processor;
    }

    function execute(address, bytes calldata input) external payable override returns (bytes memory) {
        if (msg.sender != processor) revert OnlyProcessor();

        (address token, address spender, uint256 amount) = abi.decode(input, (address, address, uint256));
        IERC20(token).forceApprove(spender, amount);
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
}
