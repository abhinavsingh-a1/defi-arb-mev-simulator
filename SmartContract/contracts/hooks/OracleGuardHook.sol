// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IHooks} from "./IHooks.sol";
import {OracleAggregator} from "../oracle/OracleAggregator.sol";

/// @title OracleGuardHook
/// @notice A real, useful v4 hook pattern: an oracle-backed circuit
///         breaker. Attached to a `MockUniswapV4Pool`, it checks every
///         swap's *actual executed price* against `OracleAggregator` and
///         reverts the entire swap if it diverges beyond a threshold.
/// @dev This is the kind of hook flash-loan oracle-manipulation attacks
///      are specifically designed to defeat — a single large trade that
///      pushes the pool price far from the trusted reference gets
///      rejected outright, at the cost of the attacker's gas, rather than
///      succeeding and leaving a manipulated price for the rest of the
///      transaction (or block) to exploit.
///
///      Deliberately reads only the `amountIn`/`amountOut` the pool
///      passes to `afterSwap` — not the pool's own storage — so this hook
///      never needs to know the pool's address. That sidesteps an
///      otherwise-real circular dependency (the pool needs the hook's
///      address at construction; if the hook also needed the pool's
///      address, one of the two would have to be wired up after
///      deployment instead of set immutable).
contract OracleGuardHook is IHooks {
    OracleAggregator public immutable aggregator;
    bool public immutable assetIsToken0;
    uint256 public immutable maxDeviationBps;

    error SwapDeviatesTooFar(uint256 deviationBps, uint256 maxDeviationBps);

    /// @param _assetIsToken0 Whether the asset `aggregator` prices is the
    ///        guarded pool's token0 (true) or token1 (false) — same
    ///        convention as `DeviationWatcher`.
    constructor(address _aggregator, bool _assetIsToken0, uint256 _maxDeviationBps) {
        aggregator = OracleAggregator(_aggregator);
        assetIsToken0 = _assetIsToken0;
        maxDeviationBps = _maxDeviationBps;
    }

    // ----------------------------------------------------------------
    // The only hook this contract actually cares about
    // ----------------------------------------------------------------

    function afterSwap(
        address,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOut
    ) external view returns (bytes4) {
        if (amountOut == 0) return IHooks.afterSwap.selector;

        // Whichever side of the trade is the priced asset determines
        // which amount is the "denominator" of the executed price.
        bool assetIsInput = (zeroForOne == assetIsToken0);
        uint256 executedPriceWad = assetIsInput
            ? (amountOut * 1e18) / amountIn // asset in, quote out: price = quote/asset = out/in
            : (amountIn * 1e18) / amountOut; // quote in, asset out: price = quote/asset = in/out

        (uint256 oraclePrice, , ) = aggregator.getPrices();

        uint256 diff = executedPriceWad > oraclePrice
            ? executedPriceWad - oraclePrice
            : oraclePrice - executedPriceWad;
        uint256 deviationBps = (diff * 10_000) / oraclePrice;

        if (deviationBps > maxDeviationBps) {
            revert SwapDeviatesTooFar(deviationBps, maxDeviationBps);
        }

        return IHooks.afterSwap.selector;
    }

    // ----------------------------------------------------------------
    // Every other hook: no-op, correct selector
    // ----------------------------------------------------------------

    function beforeInitialize(address, uint256) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, uint256, int24) external pure returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, int24, int24, uint256) external pure returns (bytes4) {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        int24,
        int24,
        uint256,
        uint256,
        uint256
    ) external pure returns (bytes4) {
        return IHooks.afterAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(address, int24, int24, uint256) external pure returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        int24,
        int24,
        uint256,
        uint256,
        uint256
    ) external pure returns (bytes4) {
        return IHooks.afterRemoveLiquidity.selector;
    }

    function beforeSwap(address, bool, uint256) external pure returns (bytes4, uint256, bool) {
        return (IHooks.beforeSwap.selector, 0, false);
    }
}
