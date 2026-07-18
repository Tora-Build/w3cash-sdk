// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title AggregatorV3Interface
/// @notice Chainlink price feed interface (subset).
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

/// @title IAavePool
/// @notice Aave v3 Pool.getUserAccountData subset (health factor is the 6th field).
interface IAavePool {
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

/// @title IERC4626Minimal
/// @notice ERC-4626 share→asset conversion.
interface IERC4626Minimal {
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// @title IPyth
/// @notice Pyth price-read subset. `Price` is ABI-compatible with PythStructs.Price.
interface IPyth {
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    function getPriceUnsafe(bytes32 id) external view returns (Price memory);
}

/**
 * @title OracleReadAdapter
 * @notice Typed, single-`uint256` oracle readers for the `query` condition gate.
 *
 * @dev QueryAdapter reads a gate value with `abi.decode(result, (uint256))`, which
 * takes only the FIRST 32-byte word of the callee's return. That is correct for a
 * single-`uint256` view but WRONG for a multi-field oracle return: pointing the gate
 * straight at a Chainlink feed's `latestRoundData()` decodes `roundId` (word 0), not
 * `answer` (word 1). This reader sits between the gate and the oracle and returns the
 * intended value as one word, so the query condition compares the right number:
 *
 *     query{ target: OracleReadAdapter, calldata: chainlinkPrice(feed), op, expected }
 *
 * Design:
 * - View-only periphery, staticcalled by QueryAdapter. It holds no state and exposes
 *   no privileged entrypoint, so it needs no processor pin and is safe to share
 *   across chains and callers. The intent author picks the trusted feed/pool address;
 *   this contract only forwards the read.
 * - On any read that cannot yield a trustworthy value (invalid answer, zero/future
 *   update time, staleness beyond the caller's bound), the function REVERTS. Through
 *   QueryAdapter's staticcall that surfaces as `QueryFailed()`, so the gate is treated
 *   as NOT-met and the keeper retries — a broken or stale oracle can never falsely
 *   satisfy a condition. A numeric sentinel is deliberately avoided: no single value
 *   is safe under both `<=` and `>=` comparisons.
 */
contract OracleReadAdapter {
    /// @notice Chainlink answer / Pyth price was negative — not representable unsigned.
    error NegativeAnswer();
    /// @notice The feed's `updatedAt`/`publishTime` is zero or in the future.
    error InvalidUpdateTime();
    /// @notice The reading is older than the caller's `maxAge`.
    error StalePrice();
    /// @notice Rescale exponent exceeds a sane bound (would overflow uint256).
    error ScaleOverflow();

    // ---------------------------------------------------------------------
    // Chainlink
    // ---------------------------------------------------------------------

    /**
     * @notice Latest Chainlink `answer` for `feed`, as uint256 (feed-native decimals).
     * @dev THE fix: returns `answer` (word 1), not `roundId`. Reverts on a negative
     * answer or a zero/future `updatedAt` (an uninitialized or malformed round).
     */
    function chainlinkPrice(address feed) external view returns (uint256) {
        (, int256 answer, , uint256 updatedAt, ) = AggregatorV3Interface(feed)
            .latestRoundData();
        _requireValidTime(updatedAt);
        if (answer < 0) revert NegativeAnswer();
        return uint256(answer);
    }

    /**
     * @notice Latest Chainlink price for `feed`, but only if updated within `maxAge`
     * seconds; otherwise reverts. Enforces price + freshness in one gate read.
     */
    function chainlinkFreshPrice(address feed, uint256 maxAge)
        external
        view
        returns (uint256)
    {
        (, int256 answer, , uint256 updatedAt, ) = AggregatorV3Interface(feed)
            .latestRoundData();
        _requireValidTime(updatedAt);
        if (block.timestamp - updatedAt > maxAge) revert StalePrice();
        if (answer < 0) revert NegativeAnswer();
        return uint256(answer);
    }

    /**
     * @notice Age of `feed`'s latest round in seconds (`block.timestamp - updatedAt`).
     * @dev A freshness gate reads this with `<= maxAge`. Reverts on a zero/future time.
     */
    function chainlinkStaleness(address feed) external view returns (uint256) {
        (, , , uint256 updatedAt, ) = AggregatorV3Interface(feed).latestRoundData();
        _requireValidTime(updatedAt);
        return block.timestamp - updatedAt;
    }

    /**
     * @notice Latest Chainlink price rescaled from the feed's own decimals to
     * `targetDecimals`, so an intent can compare against a threshold expressed in a
     * chosen precision. Reverts if the rescale exponent is unreasonably large.
     */
    function chainlinkPriceScaled(address feed, uint8 targetDecimals)
        external
        view
        returns (uint256)
    {
        AggregatorV3Interface agg = AggregatorV3Interface(feed);
        (, int256 answer, , uint256 updatedAt, ) = agg.latestRoundData();
        _requireValidTime(updatedAt);
        if (answer < 0) revert NegativeAnswer();
        uint256 price = uint256(answer);
        uint8 feedDecimals = agg.decimals();
        if (targetDecimals >= feedDecimals) {
            uint256 up = uint256(targetDecimals - feedDecimals);
            if (up > 77) revert ScaleOverflow();
            return price * (10 ** up); // checked; reverts on overflow
        }
        uint256 down = uint256(feedDecimals - targetDecimals);
        if (down > 77) revert ScaleOverflow();
        return price / (10 ** down);
    }

    // ---------------------------------------------------------------------
    // Aave v3
    // ---------------------------------------------------------------------

    /**
     * @notice `user`'s Aave v3 health factor (1e18-scaled; type(uint256).max if no
     * debt). Reads the 6th field of getUserAccountData — a liquidation-protection
     * gate fires on `healthFactor <= threshold`.
     */
    function aaveHealthFactor(address pool, address user)
        external
        view
        returns (uint256)
    {
        (, , , , , uint256 healthFactor) = IAavePool(pool).getUserAccountData(user);
        return healthFactor;
    }

    // ---------------------------------------------------------------------
    // ERC-4626 vault
    // ---------------------------------------------------------------------

    /**
     * @notice Assets returned for `shares` of an ERC-4626 `vault` (its live share
     * price). Gate on a vault appreciating past a target.
     */
    function erc4626ConvertToAssets(address vault, uint256 shares)
        external
        view
        returns (uint256)
    {
        return IERC4626Minimal(vault).convertToAssets(shares);
    }

    // ---------------------------------------------------------------------
    // Pyth
    // ---------------------------------------------------------------------

    /**
     * @notice Latest Pyth price for `id` as uint256, from `getPriceUnsafe`. Reverts on
     * a negative price. NOTE: unsafe = no on-read staleness check; pair with
     * `pythFreshPrice` (or a separate age gate) when freshness matters.
     */
    function pythPrice(address pyth, bytes32 id) external view returns (uint256) {
        IPyth.Price memory p = IPyth(pyth).getPriceUnsafe(id);
        if (p.price < 0) revert NegativeAnswer();
        return uint256(uint64(p.price));
    }

    /**
     * @notice Latest Pyth price for `id`, only if published within `maxAge` seconds;
     * otherwise reverts. Enforces price + freshness in one gate read.
     */
    function pythFreshPrice(address pyth, bytes32 id, uint256 maxAge)
        external
        view
        returns (uint256)
    {
        IPyth.Price memory p = IPyth(pyth).getPriceUnsafe(id);
        _requireValidTime(p.publishTime);
        if (block.timestamp - p.publishTime > maxAge) revert StalePrice();
        if (p.price < 0) revert NegativeAnswer();
        return uint256(uint64(p.price));
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /// @dev A trustworthy timestamp is non-zero and not in the future.
    function _requireValidTime(uint256 ts) internal view {
        if (ts == 0 || ts > block.timestamp) revert InvalidUpdateTime();
    }
}
