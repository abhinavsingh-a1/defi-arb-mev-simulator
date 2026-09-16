// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolMath} from "../amm/PoolMath.sol";
import {MockUniswapV2Pool} from "../amm/MockUniswapV2Pool.sol";
import {OracleAggregator} from "./OracleAggregator.sol";

/// @title DeviationWatcher
/// @notice Compares an AMM pool's spot price against an oracle-reported
///         price and flags when they diverge beyond a configurable
///         threshold. This is the mechanism both an arb scanner (AMM price
///         vs oracle price = arb signal) and an oracle-manipulation
///         detector (a sudden AMM/oracle gap = possible attack in
///         progress) key off of.
/// @dev Deliberately permissionless to call `poke` — in production this
///      would run as a keeper/off-chain bot loop hitting `poke` on a
///      schedule, but any address can trigger a check, which matters if
///      you want this to double as a public "someone please look at this"
///      alarm.
contract DeviationWatcher {
    struct Watch {
        MockUniswapV2Pool pool;
        OracleAggregator aggregator;
        bool assetIsToken0; // true if the asset being priced is pool.token0()
        uint256 thresholdBps;
        bool active;
    }

    address public immutable owner;
    Watch[] public watches;

    event WatchAdded(uint256 indexed watchId, address pool, address aggregator, uint256 thresholdBps);
    event WatchThresholdUpdated(uint256 indexed watchId, uint256 newThresholdBps);
    event WatchDeactivated(uint256 indexed watchId);
    event DeviationDetected(
        uint256 indexed watchId,
        uint256 ammPriceWad,
        uint256 oraclePriceWad,
        uint256 deviationBps,
        uint256 thresholdBps
    );

    error NotOwner();
    error InvalidWatch();
    error WatchInactive();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    /// @notice Registers a new pool/oracle pair to monitor.
    /// @param assetIsToken0 Whether the asset priced by `aggregator` is
    ///        `pool.token0()` (true) or `pool.token1()` (false) — needed to
    ///        read the AMM spot price in the same "asset per quote-currency"
    ///        orientation as the oracle price.
    function addWatch(
        address pool,
        address aggregator,
        bool assetIsToken0,
        uint256 thresholdBps
    ) external onlyOwner returns (uint256 watchId) {
        watches.push(
            Watch({
                pool: MockUniswapV2Pool(pool),
                aggregator: OracleAggregator(aggregator),
                assetIsToken0: assetIsToken0,
                thresholdBps: thresholdBps,
                active: true
            })
        );
        watchId = watches.length - 1;
        emit WatchAdded(watchId, pool, aggregator, thresholdBps);
    }

    function updateThreshold(uint256 watchId, uint256 newThresholdBps) external onlyOwner {
        _requireValidWatch(watchId);
        watches[watchId].thresholdBps = newThresholdBps;
        emit WatchThresholdUpdated(watchId, newThresholdBps);
    }

    function deactivateWatch(uint256 watchId) external onlyOwner {
        _requireValidWatch(watchId);
        watches[watchId].active = false;
        emit WatchDeactivated(watchId);
    }

    /// @notice Read-only check: returns the AMM price, oracle price, and
    ///         deviation in bps, without emitting anything. Useful for an
    ///         off-chain bot deciding whether `poke` is even worth the gas.
    function computeDeviation(
        uint256 watchId
    ) public view returns (uint256 ammPriceWad, uint256 oraclePriceWad, uint256 deviationBps) {
        _requireValidWatch(watchId);
        Watch storage w = watches[watchId];
        if (!w.active) revert WatchInactive();

        (uint256 reserve0, uint256 reserve1) = w.pool.getReserves();
        ammPriceWad = w.assetIsToken0
            ? PoolMath.spotPrice(reserve0, reserve1)
            : PoolMath.spotPrice(reserve1, reserve0);

        (uint256 primaryPrice, , ) = w.aggregator.getPrices();
        oraclePriceWad = primaryPrice;

        uint256 diff = ammPriceWad > oraclePriceWad ? ammPriceWad - oraclePriceWad : oraclePriceWad - ammPriceWad;
        deviationBps = (diff * PoolMath.BPS_DENOMINATOR) / oraclePriceWad;
    }

    /// @notice Checks a watch and emits `DeviationDetected` if the
    ///         deviation exceeds its threshold. Callable by anyone —
    ///         intended to be driven by an off-chain keeper loop.
    /// @return triggered Whether the threshold was exceeded (and an event emitted).
    function poke(uint256 watchId) external returns (bool triggered) {
        (uint256 ammPrice, uint256 oraclePrice, uint256 deviationBps) = computeDeviation(watchId);
        Watch storage w = watches[watchId];

        if (deviationBps > w.thresholdBps) {
            emit DeviationDetected(watchId, ammPrice, oraclePrice, deviationBps, w.thresholdBps);
            triggered = true;
        }
    }

    function watchCount() external view returns (uint256) {
        return watches.length;
    }

    function _requireValidWatch(uint256 watchId) internal view {
        if (watchId >= watches.length) revert InvalidWatch();
    }
}
