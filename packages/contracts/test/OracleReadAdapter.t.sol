// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { OracleReadAdapter, IPyth } from "../src/w3cash/adapters/OracleReadAdapter.sol";
import { QueryAdapter } from "../src/w3cash/adapters/QueryAdapter.sol";
import { DataTypes } from "../src/w3cash/utils/DataTypes.sol";

// --- Mocks --------------------------------------------------------------

/// @dev Chainlink feed. latestRoundData returns 5 fields; a naive uint256 decode
/// of the raw return reads roundId (word 0), not answer (word 1).
contract MockAggregator {
    uint80 public roundId;
    int256 public answer;
    uint256 public updatedAt;
    uint8 public dec;

    constructor(uint80 _roundId, int256 _answer, uint256 _updatedAt, uint8 _dec) {
        roundId = _roundId;
        answer = _answer;
        updatedAt = _updatedAt;
        dec = _dec;
    }

    function set(int256 _answer, uint256 _updatedAt) external {
        answer = _answer;
        updatedAt = _updatedAt;
    }

    function decimals() external view returns (uint8) {
        return dec;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (roundId, answer, 0, updatedAt, roundId);
    }
}

contract MockAavePool {
    uint256 public hf;

    constructor(uint256 _hf) {
        hf = _hf;
    }

    function getUserAccountData(address)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return (1, 2, 3, 4, 5, hf);
    }
}

contract MockVault {
    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares * 2; // 2 assets per share
    }
}

contract MockPyth {
    IPyth.Price internal p;

    constructor(int64 _price, uint256 _publishTime) {
        p = IPyth.Price({ price: _price, conf: 1, expo: -8, publishTime: _publishTime });
    }

    function getPriceUnsafe(bytes32) external view returns (IPyth.Price memory) {
        return p;
    }
}

contract OracleReadAdapterTest is Test {
    OracleReadAdapter internal reader;

    function setUp() public {
        reader = new OracleReadAdapter();
        vm.warp(1_000_000);
    }

    // --- Chainlink: the core fix -----------------------------------------

    function test_ChainlinkPrice_ReadsAnswerNotRoundId() public {
        // roundId = 42 (a value that would be returned by the buggy path),
        // answer = 2000e8 (the real price).
        MockAggregator feed = new MockAggregator(42, 2000e8, block.timestamp, 8);
        assertEq(reader.chainlinkPrice(address(feed)), 2000e8);
        // Prove the distinction: the reader must NOT return the roundId.
        assertTrue(reader.chainlinkPrice(address(feed)) != 42);
    }

    function test_ChainlinkPrice_RevertsOnNegativeAnswer() public {
        MockAggregator feed = new MockAggregator(1, -5, block.timestamp, 8);
        vm.expectRevert(OracleReadAdapter.NegativeAnswer.selector);
        reader.chainlinkPrice(address(feed));
    }

    function test_ChainlinkPrice_RevertsOnZeroUpdateTime() public {
        MockAggregator feed = new MockAggregator(1, 100, 0, 8);
        vm.expectRevert(OracleReadAdapter.InvalidUpdateTime.selector);
        reader.chainlinkPrice(address(feed));
    }

    function test_ChainlinkPrice_RevertsOnFutureUpdateTime() public {
        MockAggregator feed = new MockAggregator(1, 100, block.timestamp + 1, 8);
        vm.expectRevert(OracleReadAdapter.InvalidUpdateTime.selector);
        reader.chainlinkPrice(address(feed));
    }

    function test_ChainlinkFreshPrice_ReturnsWhenFresh() public {
        MockAggregator feed = new MockAggregator(1, 3000e8, block.timestamp - 100, 8);
        assertEq(reader.chainlinkFreshPrice(address(feed), 3600), 3000e8);
    }

    function test_ChainlinkFreshPrice_RevertsWhenStale() public {
        MockAggregator feed = new MockAggregator(1, 3000e8, block.timestamp - 7200, 8);
        vm.expectRevert(OracleReadAdapter.StalePrice.selector);
        reader.chainlinkFreshPrice(address(feed), 3600);
    }

    function test_ChainlinkStaleness_ReturnsAge() public {
        MockAggregator feed = new MockAggregator(1, 100, block.timestamp - 250, 8);
        assertEq(reader.chainlinkStaleness(address(feed)), 250);
    }

    function test_ChainlinkPriceScaled_Up() public {
        // 2000e8 (8 dec) → 18 dec == 2000e18.
        MockAggregator feed = new MockAggregator(1, 2000e8, block.timestamp, 8);
        assertEq(reader.chainlinkPriceScaled(address(feed), 18), 2000e18);
    }

    function test_ChainlinkPriceScaled_Down() public {
        // 2000e8 (8 dec) → 6 dec == 2000e6.
        MockAggregator feed = new MockAggregator(1, 2000e8, block.timestamp, 8);
        assertEq(reader.chainlinkPriceScaled(address(feed), 6), 2000e6);
    }

    // --- Aave / ERC-4626 / Pyth ------------------------------------------

    function test_AaveHealthFactor_ReadsSixthField() public {
        MockAavePool pool = new MockAavePool(1.05e18);
        assertEq(reader.aaveHealthFactor(address(pool), address(0xBEEF)), 1.05e18);
    }

    function test_Erc4626ConvertToAssets() public {
        MockVault vault = new MockVault();
        assertEq(reader.erc4626ConvertToAssets(address(vault), 10), 20);
    }

    function test_PythPrice() public {
        MockPyth pyth = new MockPyth(int64(12345), block.timestamp);
        assertEq(reader.pythPrice(address(pyth), bytes32(0)), 12345);
    }

    function test_PythPrice_RevertsOnNegative() public {
        MockPyth pyth = new MockPyth(int64(-1), block.timestamp);
        vm.expectRevert(OracleReadAdapter.NegativeAnswer.selector);
        reader.pythPrice(address(pyth), bytes32(0));
    }

    function test_PythFreshPrice_RevertsWhenStale() public {
        MockPyth pyth = new MockPyth(int64(12345), block.timestamp - 7200);
        vm.expectRevert(OracleReadAdapter.StalePrice.selector);
        reader.pythFreshPrice(address(pyth), bytes32(0), 3600);
    }

    /// Audit F10: pythPrice now enforces a valid publish time (a zero/uninitialized time reverts).
    function test_AuditF10_PythPrice_RequiresValidTime() public {
        MockPyth pyth = new MockPyth(int64(12345), 0); // uninitialized publishTime
        vm.expectRevert(OracleReadAdapter.InvalidUpdateTime.selector);
        reader.pythPrice(address(pyth), bytes32(0));
    }

    /// Audit F10: the expo-aware scaled reader normalizes to target decimals (expo -8 -> 8 dp).
    function test_AuditF10_PythPriceScaled_AppliesExpo() public {
        // mantissa 3000_0000_0000 (3e11) with expo -8 == $3000; scaled to 8 dp == 3000e8.
        MockPyth pyth = new MockPyth(int64(3000_0000_0000), block.timestamp);
        assertEq(reader.pythPriceScaled(address(pyth), bytes32(0), 8, 3600), 3000e8);
    }

    /// Audit F11: chainlinkPriceScaled that would truncate a non-zero price to 0 reverts.
    function test_AuditF11_ChainlinkScaled_RevertsOnUnderflow() public {
        // $0.30 on an 8-dec feed (3e7); scaling to 0 decimals => 3e7/1e8 = 0 -> ScaleUnderflow.
        MockAggregator feed = new MockAggregator(1, 3e7, block.timestamp, 8);
        vm.expectRevert(OracleReadAdapter.ScaleUnderflow.selector);
        reader.chainlinkPriceScaled(address(feed), 0);
    }

    // --- Integration: QueryAdapter reads the reader correctly ------------

    /// @dev The whole point: a `query` gate that targets OracleReadAdapter.
    /// chainlinkPrice() compares the PRICE. Targeting the feed's latestRoundData()
    /// directly would compare roundId — the bug this reader exists to fix.
    function test_Integration_QueryAdapter_ComparesPriceViaReader() public {
        address processor = address(0x1111);
        QueryAdapter q = new QueryAdapter(processor);
        MockAggregator feed = new MockAggregator(42, 2000e8, block.timestamp, 8);

        // Gate: price >= 1500e8  → met (2000e8 >= 1500e8).
        bytes memory input = abi.encode(
            address(reader),
            abi.encodeWithSelector(reader.chainlinkPrice.selector, address(feed)),
            q.OP_GTE(),
            uint256(1500e8)
        );
        vm.prank(processor);
        bytes memory met = q.execute(address(0xBEEF), input);
        assertEq(met.length, 0); // condition met → empty return

        // Gate: price >= 2500e8 → not met (2000e8 < 2500e8) → PAUSE.
        bytes memory input2 = abi.encode(
            address(reader),
            abi.encodeWithSelector(reader.chainlinkPrice.selector, address(feed)),
            q.OP_GTE(),
            uint256(2500e8)
        );
        vm.prank(processor);
        bytes memory notMet = q.execute(address(0xBEEF), input2);
        assertEq(
            keccak256(notMet),
            keccak256(abi.encode(DataTypes.PAUSE_EXECUTION))
        );
    }

    /// @dev A broken/stale feed makes the gate revert through QueryAdapter's
    /// staticcall (QueryFailed) — never falsely satisfied.
    function test_Integration_StaleFeed_RevertsAsQueryFailed() public {
        address processor = address(0x1111);
        QueryAdapter q = new QueryAdapter(processor);
        MockAggregator feed = new MockAggregator(1, 2000e8, block.timestamp - 7200, 8);

        bytes memory input = abi.encode(
            address(reader),
            abi.encodeWithSelector(
                reader.chainlinkFreshPrice.selector,
                address(feed),
                uint256(3600)
            ),
            q.OP_GTE(),
            uint256(1)
        );
        vm.prank(processor);
        vm.expectRevert(QueryAdapter.QueryFailed.selector);
        q.execute(address(0xBEEF), input);
    }
}
