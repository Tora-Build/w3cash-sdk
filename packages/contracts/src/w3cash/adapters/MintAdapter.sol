// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";

/// @title IERC721Mint
/// @notice Interface for mintable NFTs
interface IERC721Mint {
    function mint(address to) external payable returns (uint256);
    function safeMint(address to) external payable returns (uint256);
}

/// @title MintAdapter
/// @notice Adapter for minting NFTs (ERC721)
/// @dev Supports standard mint patterns and generic calls
contract MintAdapter is IAdapter {

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error MintAdapter__CallerNotProcessor();
    error MintAdapter__MintFailed();
    error MintAdapter__InsufficientValue();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("MintAdapter"));

    /// @notice Mint methods
    uint8 public constant METHOD_MINT = 0;      // mint(to)
    uint8 public constant METHOD_SAFE_MINT = 1; // safeMint(to)
    uint8 public constant METHOD_GENERIC = 2;   // Generic call with custom calldata

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The authorized Processor contract
    address public immutable processor;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyProcessor() {
        if (msg.sender != processor) revert MintAdapter__CallerNotProcessor();
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

    /// @notice Execute a mint operation
    /// @param account The account receiving the NFT
    /// @param data ABI encoded based on method:
    ///        Standard: (address nftContract, uint8 method, uint256 mintPrice)
    ///        Generic: (address nftContract, uint8 method=2, uint256 mintPrice, bytes callData)
    /// @return ABI encoded token ID (if available)
    function execute(
        address account,
        bytes calldata data
    ) external payable override onlyProcessor returns (bytes memory) {
        if (data.length < 64) {
            // Minimum: address + method + price
            revert MintAdapter__MintFailed();
        }

        (
            address nftContract,
            uint8 method,
            uint256 mintPrice
        ) = abi.decode(data[:96], (address, uint8, uint256));

        // Verify we have enough ETH for mint price
        if (msg.value < mintPrice) revert MintAdapter__InsufficientValue();

        uint256 tokenId;

        if (method == METHOD_MINT) {
            tokenId = IERC721Mint(nftContract).mint{value: mintPrice}(account);
        } else if (method == METHOD_SAFE_MINT) {
            tokenId = IERC721Mint(nftContract).safeMint{value: mintPrice}(account);
        } else if (method == METHOD_GENERIC) {
            // Generic call with custom calldata
            bytes memory callData = abi.decode(data[96:], (bytes));
            (bool success, bytes memory result) = nftContract.call{value: mintPrice}(callData);
            if (!success) revert MintAdapter__MintFailed();
            // Try to decode token ID from result
            if (result.length >= 32) {
                tokenId = abi.decode(result, (uint256));
            }
        } else {
            revert MintAdapter__MintFailed();
        }

        // Refund excess ETH
        if (msg.value > mintPrice) {
            (bool refunded,) = account.call{value: msg.value - mintPrice}("");
            // Don't revert on refund failure
        }

        return abi.encode(tokenId);
    }

    /// @inheritdoc IAdapter
    function send(bytes memory, uint8, uint64, uint112) external payable override returns (uint64) {
        revert("MintAdapter: send not supported");
    }

    /// @inheritdoc IAdapter
    function estimateFee(uint8, uint112, uint256) external pure override returns (uint256) {
        return 0;
    }

    /// @notice Allow receiving ETH for mint payments
    receive() external payable {}
}
