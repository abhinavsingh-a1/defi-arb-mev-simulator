// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

/// @title TickMath (simplified)
/// @notice Converts between ticks and sqrt(price), where price = token1/token0.
/// @dev IMPORTANT — this is a deliberately simplified, pedagogical stand-in
///      for Uniswap v3's `TickMath.sol`. Real Uniswap v3 represents
///      sqrtPrice in Q64.96 fixed point and derives `getSqrtRatioAtTick`
///      from ~20 precomputed high-precision magic constants (one per bit of
///      the tick, combined via bit-shifting) specifically to avoid
///      compounding rounding error across up to 887,272 squarings.
///
///      This version instead uses plain WAD (1e18) fixed point and
///      straightforward repeated squaring of sqrt(1.0001). That's easier to
///      read and reason about, but accumulates more rounding error at
///      extreme ticks (very large |tick|). It is accurate enough for demo
///      ranges near the current price (the only ranges this project's
///      tests/dashboard actually use) but should NOT be treated as
///      production-precision math.
library TickMath {
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;
    uint256 internal constant WAD = 1e18;

    /// @dev sqrt(1.0001) * 1e18, precomputed off-chain (see repo notes).
    uint256 internal constant SQRT_1_0001_WAD = 1000049998750062496;

    error TickOutOfRange();

    /// @notice Returns sqrt(1.0001^tick) scaled by 1e18.
    /// @dev Uses exponentiation-by-squaring on the WAD-scaled base above.
    ///      Negative ticks take the reciprocal of the positive-tick result.
    function getSqrtPriceAtTick(int24 tick) internal pure returns (uint256 sqrtPriceWad) {
        if (tick < MIN_TICK || tick > MAX_TICK) revert TickOutOfRange();

        uint256 absTick = tick < 0 ? uint256(uint24(-tick)) : uint256(uint24(tick));

        uint256 result = WAD;
        uint256 b = SQRT_1_0001_WAD;
        uint256 e = absTick;

        while (e > 0) {
            if (e & 1 == 1) {
                result = (result * b) / WAD;
            }
            b = (b * b) / WAD;
            e >>= 1;
        }

        sqrtPriceWad = tick >= 0 ? result : (WAD * WAD) / result;
    }

    /// @notice WAD-scaled reciprocal: returns (1e18 * 1e18) / x, i.e. 1/x in WAD terms.
    function reciprocalWad(uint256 x) internal pure returns (uint256) {
        return (WAD * WAD) / x;
    }

    function wmul(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b) / WAD;
    }

    function wdiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * WAD) / b;
    }
}
