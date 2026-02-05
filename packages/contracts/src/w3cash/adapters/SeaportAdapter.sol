// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAdapter } from "./interfaces/IAdapter.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Seaport order types
enum ItemType {
    NATIVE,
    ERC20,
    ERC721,
    ERC1155,
    ERC721_WITH_CRITERIA,
    ERC1155_WITH_CRITERIA
}

enum OrderType {
    FULL_OPEN,
    PARTIAL_OPEN,
    FULL_RESTRICTED,
    PARTIAL_RESTRICTED,
    CONTRACT
}

struct OfferItem {
    ItemType itemType;
    address token;
    uint256 identifierOrCriteria;
    uint256 startAmount;
    uint256 endAmount;
}

struct ConsiderationItem {
    ItemType itemType;
    address token;
    uint256 identifierOrCriteria;
    uint256 startAmount;
    uint256 endAmount;
    address payable recipient;
}

struct OrderParameters {
    address offerer;
    address zone;
    OfferItem[] offer;
    ConsiderationItem[] consideration;
    OrderType orderType;
    uint256 startTime;
    uint256 endTime;
    bytes32 zoneHash;
    uint256 salt;
    bytes32 conduitKey;
    uint256 totalOriginalConsiderationItems;
}

struct AdvancedOrder {
    OrderParameters parameters;
    uint120 numerator;
    uint120 denominator;
    bytes signature;
    bytes extraData;
}

struct CriteriaResolver {
    uint256 orderIndex;
    uint8 side;
    uint256 index;
    uint256 identifier;
    bytes32[] criteriaProof;
}

struct FulfillmentComponent {
    uint256 orderIndex;
    uint256 itemIndex;
}

struct Fulfillment {
    FulfillmentComponent[] offerComponents;
    FulfillmentComponent[] considerationComponents;
}

/// @title ISeaport
/// @notice Minimal interface for Seaport 1.5
interface ISeaport {
    function fulfillAdvancedOrder(
        AdvancedOrder calldata advancedOrder,
        CriteriaResolver[] calldata criteriaResolvers,
        bytes32 fulfillerConduitKey,
        address recipient
    ) external payable returns (bool fulfilled);
    
    function fulfillBasicOrder(
        BasicOrderParameters calldata parameters
    ) external payable returns (bool fulfilled);
    
    function validate(Order[] calldata orders) external returns (bool validated);
    function cancel(OrderComponents[] calldata orders) external returns (bool cancelled);
}

struct BasicOrderParameters {
    address considerationToken;
    uint256 considerationIdentifier;
    uint256 considerationAmount;
    address payable offerer;
    address zone;
    address offerToken;
    uint256 offerIdentifier;
    uint256 offerAmount;
    uint8 basicOrderType;
    uint256 startTime;
    uint256 endTime;
    bytes32 zoneHash;
    uint256 salt;
    bytes32 offererConduitKey;
    bytes32 fulfillerConduitKey;
    uint256 totalOriginalAdditionalRecipients;
    AdditionalRecipient[] additionalRecipients;
    bytes signature;
}

struct AdditionalRecipient {
    uint256 amount;
    address payable recipient;
}

struct Order {
    OrderParameters parameters;
    bytes signature;
}

struct OrderComponents {
    address offerer;
    address zone;
    OfferItem[] offer;
    ConsiderationItem[] consideration;
    OrderType orderType;
    uint256 startTime;
    uint256 endTime;
    bytes32 zoneHash;
    uint256 salt;
    bytes32 conduitKey;
    uint256 counter;
}

/**
 * @title SeaportAdapter
 * @notice Action adapter for Seaport NFT marketplace
 * @dev Supports buying and selling NFTs through Seaport 1.5
 */
contract SeaportAdapter is IAdapter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error SeaportAdapter__OnlyProcessor();
    error SeaportAdapter__InvalidOperation();
    error SeaportAdapter__FulfillmentFailed();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes4 public constant ADAPTER_ID = bytes4(keccak256("SeaportAdapter"));
    
    /// @notice Operation selectors
    bytes4 public constant OP_FULFILL_BASIC = 0xfb0f3ee1; // fulfillBasicOrder
    bytes4 public constant OP_FULFILL_ADVANCED = 0xe7acab24; // fulfillAdvancedOrder

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    ISeaport public immutable seaport;
    address public immutable processor;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _seaport, address _processor) {
        seaport = ISeaport(_seaport);
        processor = _processor;
    }

    /*//////////////////////////////////////////////////////////////
                           ADAPTER INTERFACE
    //////////////////////////////////////////////////////////////*/

    function adapterId() external pure override returns (bytes4) {
        return ADAPTER_ID;
    }

    function execute(address initiator, bytes calldata input) external payable override returns (bytes memory) {
        if (msg.sender != processor) revert SeaportAdapter__OnlyProcessor();
        if (input.length < 4) revert SeaportAdapter__InvalidOperation();

        bytes4 operation = bytes4(input[:4]);
        bytes calldata params = input[4:];

        if (operation == OP_FULFILL_BASIC) {
            return _executeFulfillBasic(initiator, params);
        } else if (operation == OP_FULFILL_ADVANCED) {
            return _executeFulfillAdvanced(initiator, params);
        } else {
            revert SeaportAdapter__InvalidOperation();
        }
    }

    function send(bytes memory, uint8, uint64, uint112) external payable override returns (uint64) {
        return 0;
    }

    function estimateFee(uint8, uint112, uint256) external pure override returns (uint256) {
        return 0;
    }

    /// @notice Allow receiving ETH for purchases
    receive() external payable {}

    /// @notice Allow receiving ERC721
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /// @notice Allow receiving ERC1155
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL OPERATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fulfill a basic Seaport order (ETH for NFT or NFT for ETH)
    function _executeFulfillBasic(address initiator, bytes calldata params) internal returns (bytes memory) {
        BasicOrderParameters memory orderParams = abi.decode(params, (BasicOrderParameters));

        // For ETH purchases, ETH should be sent with the call
        // For ERC20 purchases, transfer from initiator
        if (orderParams.considerationToken != address(0)) {
            IERC20(orderParams.considerationToken).safeTransferFrom(
                initiator,
                address(this),
                orderParams.considerationAmount
            );
            IERC20(orderParams.considerationToken).forceApprove(
                address(seaport),
                orderParams.considerationAmount
            );
        }

        // Fulfill order
        bool success = seaport.fulfillBasicOrder{ value: msg.value }(orderParams);
        if (!success) revert SeaportAdapter__FulfillmentFailed();

        // Transfer received NFT to initiator
        ItemType offerType = ItemType(orderParams.basicOrderType % 4);
        if (offerType == ItemType.ERC721) {
            IERC721(orderParams.offerToken).safeTransferFrom(
                address(this),
                initiator,
                orderParams.offerIdentifier
            );
        } else if (offerType == ItemType.ERC1155) {
            IERC1155(orderParams.offerToken).safeTransferFrom(
                address(this),
                initiator,
                orderParams.offerIdentifier,
                orderParams.offerAmount,
                ""
            );
        }

        return abi.encode(true);
    }

    /// @notice Fulfill an advanced Seaport order
    function _executeFulfillAdvanced(address initiator, bytes calldata params) internal returns (bytes memory) {
        (
            AdvancedOrder memory advancedOrder,
            CriteriaResolver[] memory criteriaResolvers,
            bytes32 fulfillerConduitKey
        ) = abi.decode(params, (AdvancedOrder, CriteriaResolver[], bytes32));

        // Handle consideration items (what fulfiller pays)
        for (uint256 i = 0; i < advancedOrder.parameters.consideration.length; i++) {
            ConsiderationItem memory item = advancedOrder.parameters.consideration[i];
            if (item.itemType == ItemType.ERC20) {
                IERC20(item.token).safeTransferFrom(initiator, address(this), item.startAmount);
                IERC20(item.token).forceApprove(address(seaport), item.startAmount);
            }
        }

        // Fulfill order
        bool success = seaport.fulfillAdvancedOrder{ value: msg.value }(
            advancedOrder,
            criteriaResolvers,
            fulfillerConduitKey,
            initiator // recipient
        );
        if (!success) revert SeaportAdapter__FulfillmentFailed();

        return abi.encode(true);
    }
}
