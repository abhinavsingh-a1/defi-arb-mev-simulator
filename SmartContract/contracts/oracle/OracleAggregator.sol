// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IPriceOracle} from "./IPriceOracle.sol";
import {AggregatorV3Interface} from "./AggregatorV3Interface.sol";

/// @title OracleAggregator
/// @notice Reads a primary price oracle (IPriceOracle) and a secondary
///         feed implementing the real Chainlink AggregatorV3Interface,
///         and exposes both prices plus their deviation in one call. This
///         is the data layer for `DeviationWatcher` and `OracleGuardHook`
///         — it doesn't decide what counts as "too much" deviation, it
///         just measures it.
/// @dev Deliberately holds no opinion about which price is "right" — a
///      primary/secondary disagreement is itself the signal (it's exactly
///      the kind of gap flash-loan oracle-manipulation attacks try to
///      create), so this contract just reports the gap and lets its
///      callers apply a threshold.
///
///      The secondary feed is read via the actual AggregatorV3Interface
///      (not a bespoke mock interface) so this contract works unmodified
///      against a real Chainlink feed address in a live deployment —
///      `MockChainlinkFeed` is the test/local-dev stand-in, matching that
///      interface exactly.
contract OracleAggregator {
    IPriceOracle public immutable primaryOracle;
    AggregatorV3Interface public immutable secondaryFeed;
    bytes32 public immutable assetId;
    uint8 public immutable secondaryFeedDecimals;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    error StalePrice();
    error InvalidSecondaryAnswer();

    /// @notice Max age (seconds) either price can be before `getPrices`
    ///         reverts — protects callers from silently acting on a
    ///         frozen/abandoned feed.
    uint256 public immutable maxStaleness;

    /// @param _primaryOracle Address of the primary IPriceOracle implementation.
    /// @param _secondaryFeed Address of an AggregatorV3Interface-compatible
    ///        feed — a real Chainlink feed in production, `MockChainlinkFeed`
    ///        in tests/local dev.
    /// @param _assetId       Asset identifier passed through to the primary oracle.
    /// @param _maxStaleness  Max age (seconds) either price can be before
    ///        `getPrices` reverts — protects callers from silently acting
    ///        on a frozen/abandoned feed.
    constructor(
        address _primaryOracle,
        address _secondaryFeed,
        bytes32 _assetId,
        uint256 _maxStaleness
    ) {
        primaryOracle = IPriceOracle(_primaryOracle);
        secondaryFeed = AggregatorV3Interface(_secondaryFeed);
        assetId = _assetId;
        maxStaleness = _maxStaleness;
        secondaryFeedDecimals = secondaryFeed.decimals();
    }

    /// @notice Returns both prices and the deviation between them.
    /// @return primaryPrice   WAD-scaled price from the primary oracle.
    /// @return secondaryPrice WAD-scaled price from the secondary
    ///         (Chainlink-compatible) feed, converted from its native
    ///         decimals to WAD.
    /// @return deviationBps   |primary - secondary| / primary, in basis points.
    function getPrices()
        external
        view
        returns (uint256 primaryPrice, uint256 secondaryPrice, uint256 deviationBps)
    {
        uint256 primaryUpdatedAt;
        (primaryPrice, primaryUpdatedAt) = primaryOracle.getLatestPrice(assetId);

        (, int256 answer, , uint256 secondaryUpdatedAt, ) = secondaryFeed.latestRoundData();
        if (answer <= 0) revert InvalidSecondaryAnswer();
        secondaryPrice = _toWad(uint256(answer), secondaryFeedDecimals);

        if (block.timestamp - primaryUpdatedAt > maxStaleness) revert StalePrice();
        if (block.timestamp - secondaryUpdatedAt > maxStaleness) revert StalePrice();

        deviationBps = _deviationBps(primaryPrice, secondaryPrice);
    }

    /// @dev Converts a value at `decimals` precision to WAD (1e18).
    function _toWad(uint256 value, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) return value;
        if (decimals < 18) return value * (10 ** (18 - decimals));
        return value / (10 ** (decimals - 18));
    }

    function _deviationBps(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 diff = a > b ? a - b : b - a;
        return (diff * BPS_DENOMINATOR) / a;
    }
}
