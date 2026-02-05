// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title BridgeAdapter
 * @notice Action adapter for cross-chain bridging via Across Protocol
 * @dev Deposits tokens into Across SpokePool for bridging to destination chain
 * 
 * Across is an optimistic bridge that uses relayers for fast fills.
 * Typical bridging time: ~2-10 minutes.
 */
contract BridgeAdapter is IAdapter {
    using SafeERC20 for IERC20;

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("BridgeAdapter"));
    address public immutable processor;
    address public immutable spokePool;

    error OnlyProcessor();

    constructor(address _spokePool, address _processor) {
        spokePool = _spokePool;
        processor = _processor;
    }

    /**
     * @notice Bridge tokens to another chain via Across
     * @param initiator The address that signed the intent (token source)
     * @param input ABI-encoded BridgeParams:
     *        - recipient: address on destination chain
     *        - destinationChainId: target chain ID
     *        - inputToken: token to bridge (on this chain)
     *        - outputToken: token to receive (on destination)
     *        - inputAmount: amount to bridge
     *        - outputAmount: minimum amount to receive (after fees)
     *        - relayerFeePct: fee percentage for relayers (in 1e18 scale)
     *        - quoteTimestamp: timestamp of the quote
     *        - message: optional message for contract calls on destination
     *        - fillDeadline: deadline for fill (0 = default)
     *        - exclusivityDeadline: exclusivity period (0 = none)
     * @return Empty bytes on success
     */
    function execute(address initiator, bytes calldata input) external payable override returns (bytes memory) {
        if (msg.sender != processor) revert OnlyProcessor();

        (
            address recipient,
            uint256 destinationChainId,
            address inputToken,
            address outputToken,
            uint256 inputAmount,
            uint256 outputAmount,
            int64 relayerFeePct,
            uint32 quoteTimestamp,
            bytes memory message,
            uint32 fillDeadline,
            uint32 exclusivityDeadline
        ) = abi.decode(input, (address, uint256, address, address, uint256, uint256, int64, uint32, bytes, uint32, uint32));

        // Transfer tokens from initiator
        IERC20(inputToken).safeTransferFrom(initiator, address(this), inputAmount);
        
        // Approve SpokePool
        IERC20(inputToken).forceApprove(spokePool, inputAmount);

        // Deposit to Across
        IAcrossSpokePool(spokePool).depositV3(
            initiator,           // depositor
            recipient,           // recipient on destination
            inputToken,
            outputToken,
            inputAmount,
            outputAmount,
            destinationChainId,
            address(0),          // exclusiveRelayer (none)
            quoteTimestamp,
            fillDeadline,
            exclusivityDeadline,
            message
        );

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

/// @notice Across Protocol SpokePool interface (V3)
interface IAcrossSpokePool {
    function depositV3(
        address depositor,
        address recipient,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        address exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes calldata message
    ) external payable;
}
