// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

/// @title PoolMath
/// @notice Pure math library for constant-product (x*y=k) AMM pricing.
/// @dev Mirrors Uniswap v2's fee-adjusted swap formula. All amounts are in
///      the smallest unit (wei-equivalent) of their respective tokens.
///      No state, no external calls — every function is `pure` so it can be
///      unit tested in isolation and reused by both on-chain scanners and
///      off-chain bots (via the same formulas re-implemented in TS/Python).
library PoolMath {
    /// @notice Fee denominator. A `feeBps` of 30 == 0.30% (Uniswap v2 default).
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    error ZeroInput();
    error InsufficientLiquidity();
    error InvalidFee();

    /// @notice Computes the output amount for a constant-product swap,
    ///         net of a trading fee, given input reserves.
    /// @param amountIn      Amount of the input token being sold into the pool.
    /// @param reserveIn     Current pool reserve of the input token.
    /// @param reserveOut    Current pool reserve of the output token.
    /// @param feeBps        Fee in basis points (e.g. 30 = 0.30%).
    /// @return amountOut    Amount of the output token the trader receives.
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 feeBps
    ) internal pure returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroInput();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        if (feeBps >= BPS_DENOMINATOR) revert InvalidFee();

        uint256 amountInWithFee = amountIn * (BPS_DENOMINATOR - feeBps);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = (reserveIn * BPS_DENOMINATOR) + amountInWithFee;
        amountOut = numerator / denominator;
    }

    /// @notice Computes the input amount required to receive an exact output
    ///         amount, net of fee. Inverse of {getAmountOut}.
    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 feeBps
    ) internal pure returns (uint256 amountIn) {
        if (amountOut == 0) revert ZeroInput();
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientLiquidity();
        if (amountOut >= reserveOut) revert InsufficientLiquidity();
        if (feeBps >= BPS_DENOMINATOR) revert InvalidFee();

        uint256 numerator = reserveIn * amountOut * BPS_DENOMINATOR;
        uint256 denominator = (reserveOut - amountOut) * (BPS_DENOMINATOR - feeBps);
        amountIn = (numerator / denominator) + 1; // +1 to round up in the pool's favor
    }

    /// @notice The pool's current mid/spot price of the input token,
    ///         expressed in output-token units, scaled by 1e18.
    /// @dev This ignores fees and trade size — it's the theoretical price at
    ///      the current reserves, i.e. the price an infinitesimally small
    ///      trade would receive.
    function spotPrice(
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 priceX18) {
        if (reserveIn == 0) revert InsufficientLiquidity();
        priceX18 = (reserveOut * 1e18) / reserveIn;
    }

    /// @notice The effective price actually paid for a given trade size:
    ///         amountIn / amountOut, scaled by 1e18. Always worse than
    ///         {spotPrice} for a nonzero trade due to slippage + fees.
    function effectivePrice(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 feeBps
    ) internal pure returns (uint256 priceX18) {
        uint256 amountOut = getAmountOut(amountIn, reserveIn, reserveOut, feeBps);
        if (amountOut == 0) revert InsufficientLiquidity();
        priceX18 = (amountIn * 1e18) / amountOut;
    }

    /// @notice Price impact of a trade: how much worse the effective price is
    ///         than the pre-trade spot price, in basis points.
    /// @dev impactBps = (effectivePrice - spotPrice) / spotPrice * 10_000
    ///      Returned as an unsigned value; the effective price is always
    ///      greater than or equal to the spot price for a real trade.
    function priceImpactBps(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 feeBps
    ) internal pure returns (uint256 impactBps) {
        uint256 spot = spotPrice(reserveIn, reserveOut);
        uint256 effective = effectivePrice(amountIn, reserveIn, reserveOut, feeBps);

        if (effective <= spot) return 0; // shouldn't happen for amountIn > 0, guarded for safety
        impactBps = ((effective - spot) * BPS_DENOMINATOR) / spot;
    }

    /// @notice Slippage relative to a trader-supplied expected price,
    ///         in basis points. Positive means the trader received a worse
    ///         price than expected.
    /// @param expectedPriceX18 The price (input per output, scaled 1e18) the
    ///        trader expected when they submitted the trade — e.g. the spot
    ///        price they quoted before the pool state moved.
    function slippageBps(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 feeBps,
        uint256 expectedPriceX18
    ) internal pure returns (uint256 bps) {
        if (expectedPriceX18 == 0) revert ZeroInput();
        uint256 effective = effectivePrice(amountIn, reserveIn, reserveOut, feeBps);

        if (effective <= expectedPriceX18) return 0;
        bps = ((effective - expectedPriceX18) * BPS_DENOMINATOR) / expectedPriceX18;
    }

    /// @notice Computes the reserves resulting from a swap, useful for
    ///         chaining multi-hop or simulating post-trade pool state
    ///         (e.g. for arb/sandwich simulation).
    function reservesAfterSwap(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 feeBps
    ) internal pure returns (uint256 newReserveIn, uint256 newReserveOut) {
        uint256 amountOut = getAmountOut(amountIn, reserveIn, reserveOut, feeBps);
        newReserveIn = reserveIn + amountIn;
        newReserveOut = reserveOut - amountOut;
    }
}
