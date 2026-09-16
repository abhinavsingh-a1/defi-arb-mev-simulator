// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {PoolMath} from "../contracts/amm/PoolMath.sol";

/// @notice Thin external wrapper around PoolMath's internal functions.
/// @dev PoolMath's functions are `internal` — calling them directly from a
///      test gets inlined by the compiler (no new EVM call frame), so
///      `vm.expectRevert()` can't intercept the revert: it only catches
///      reverts that happen in a call *deeper* than where the cheatcode
///      was set. Routing through this external contract creates a real
///      `CALL`, giving `vm.expectRevert()` something to actually catch.
///      (The revert itself was always correct — visible right in the
///      trace as `[Revert] InsufficientLiquidity()` — Foundry just
///      couldn't see it in time without this boundary.)
contract PoolMathHarness {
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 feeBps
    ) external pure returns (uint256) {
        return PoolMath.getAmountOut(amountIn, reserveIn, reserveOut, feeBps);
    }
}

/// @notice Unit tests for PoolMath. Run with `forge test -vv`.
contract PoolMathTest is Test {
    uint256 constant FEE_30BPS = 30; // 0.30%, Uniswap v2 default
    PoolMathHarness internal harness;

    function setUp() public {
        harness = new PoolMathHarness();
    }

    // ----------------------------------------------------------------
    // getAmountOut
    // ----------------------------------------------------------------

    function test_getAmountOut_knownValue() public pure {
        // Classic Uniswap v2 worked example:
        // reserveIn = 1000, reserveOut = 1000, amountIn = 100, fee = 0.30%
        // amountInWithFee = 100 * 9970 = 997000
        // numerator = 997000 * 1000 = 997,000,000
        // denominator = 1000*10000 + 997000 = 10,997,000
        // amountOut = 997000000 / 10997000 = 90 (integer division)
        uint256 out = PoolMath.getAmountOut(100, 1000, 1000, FEE_30BPS);
        assertEq(out, 90);
    }

    function test_getAmountOut_zeroFee_matchesConstantProduct() public pure {
        // With zero fee, output should satisfy (x+dx)(y-dy) = x*y as closely
        // as integer division allows.
        uint256 reserveIn = 5000 ether;
        uint256 reserveOut = 3000 ether;
        uint256 amountIn = 100 ether;

        uint256 out = PoolMath.getAmountOut(amountIn, reserveIn, reserveOut, 0);

        uint256 kBefore = reserveIn * reserveOut;
        uint256 kAfter = (reserveIn + amountIn) * (reserveOut - out);
        // k must never decrease after a swap
        assertGe(kAfter, kBefore);
    }

    function test_getAmountOut_revertsOnZeroInput() public {
        vm.expectRevert(PoolMath.ZeroInput.selector);
        harness.getAmountOut(0, 1000, 1000, FEE_30BPS);
    }

    function test_getAmountOut_revertsOnEmptyReserves() public {
        vm.expectRevert(PoolMath.InsufficientLiquidity.selector);
        harness.getAmountOut(100, 0, 1000, FEE_30BPS);
    }

    function test_getAmountOut_revertsOnInvalidFee() public {
        vm.expectRevert(PoolMath.InvalidFee.selector);
        harness.getAmountOut(100, 1000, 1000, 10_000); // 100% fee, invalid
    }

    function testFuzz_getAmountOut_neverExceedsReserveOut(
        uint128 amountIn,
        uint128 reserveIn,
        uint128 reserveOut
    ) public pure {
        // Bounded to realistic token-amount magnitudes rather than the
        // full uint128 range. PoolMath (unlike real Uniswap v2, which
        // caps reserves to uint112 specifically for this reason) doesn't
        // guard against amountInWithFee * reserveOut overflowing uint256
        // — which a genuinely unrealistic combination (both operands near
        // ~3.4e38, far beyond any real 18-decimal token's total supply)
        // can trigger. Solidity's checked arithmetic correctly reverts
        // rather than producing a wrong answer, so this was never a
        // silent-bad-output risk — just a fuzz bound wider than reality.
        // 1e30 leaves enormous headroom over any realistic reserve/amount
        // while still fuzzing across many orders of magnitude.
        vm.assume(amountIn > 0 && reserveIn > 0 && reserveOut > 0);
        vm.assume(amountIn < 1e30 && reserveIn < 1e30 && reserveOut < 1e30);
        uint256 out = PoolMath.getAmountOut(amountIn, reserveIn, reserveOut, FEE_30BPS);
        assertLt(out, reserveOut); // can never drain the pool fully
    }

    // ----------------------------------------------------------------
    // getAmountIn (inverse check)
    // ----------------------------------------------------------------

    function test_getAmountIn_roundTripsWithGetAmountOut() public pure {
        uint256 reserveIn = 10_000 ether;
        uint256 reserveOut = 10_000 ether;
        uint256 amountOut = 500 ether;

        uint256 requiredIn = PoolMath.getAmountIn(amountOut, reserveIn, reserveOut, FEE_30BPS);
        uint256 actualOut = PoolMath.getAmountOut(requiredIn, reserveIn, reserveOut, FEE_30BPS);

        // Due to rounding, actualOut should be >= requested amountOut
        assertGe(actualOut, amountOut);
    }

    // ----------------------------------------------------------------
    // spotPrice
    // ----------------------------------------------------------------

    function test_spotPrice_basic() public pure {
        // 1000 reserveIn, 2000 reserveOut -> spot price = 2.0 (scaled 1e18)
        uint256 price = PoolMath.spotPrice(1000, 2000);
        assertEq(price, 2e18);
    }

    // ----------------------------------------------------------------
    // priceImpactBps
    // ----------------------------------------------------------------

    function test_priceImpact_increasesWithTradeSize() public pure {
        uint256 reserveIn = 100_000 ether;
        uint256 reserveOut = 100_000 ether;

        uint256 smallImpact = PoolMath.priceImpactBps(10 ether, reserveIn, reserveOut, FEE_30BPS);
        uint256 largeImpact = PoolMath.priceImpactBps(10_000 ether, reserveIn, reserveOut, FEE_30BPS);

        assertGt(largeImpact, smallImpact);
    }

    function test_priceImpact_tinyTradeIsNearZero() public pure {
        uint256 reserveIn = 1_000_000 ether;
        uint256 reserveOut = 1_000_000 ether;

        uint256 impact = PoolMath.priceImpactBps(1 ether, reserveIn, reserveOut, FEE_30BPS);
        // A 1-in-1,000,000 trade should have well under 1% (100 bps) impact
        assertLt(impact, 100);
    }

    // ----------------------------------------------------------------
    // slippageBps
    // ----------------------------------------------------------------

    function test_slippage_zeroWhenEffectiveBeatsExpected() public pure {
        uint256 reserveIn = 100_000 ether;
        uint256 reserveOut = 100_000 ether;
        uint256 amountIn = 10 ether;

        uint256 effective = PoolMath.effectivePrice(amountIn, reserveIn, reserveOut, FEE_30BPS);
        // Set expected price above the effective price -> no negative slippage reported
        uint256 slip = PoolMath.slippageBps(amountIn, reserveIn, reserveOut, FEE_30BPS, effective + 1e18);
        assertEq(slip, 0);
    }

    function test_slippage_positiveWhenWorseThanExpected() public pure {
        uint256 reserveIn = 100_000 ether;
        uint256 reserveOut = 100_000 ether;
        uint256 amountIn = 10_000 ether; // large trade -> real slippage

        uint256 spot = PoolMath.spotPrice(reserveIn, reserveOut);
        uint256 slip = PoolMath.slippageBps(amountIn, reserveIn, reserveOut, FEE_30BPS, spot);

        assertGt(slip, 0);
    }

    // ----------------------------------------------------------------
    // reservesAfterSwap
    // ----------------------------------------------------------------

    function test_reservesAfterSwap_conservesInvariantDirection() public pure {
        uint256 reserveIn = 5000 ether;
        uint256 reserveOut = 5000 ether;
        uint256 amountIn = 200 ether;

        (uint256 newIn, uint256 newOut) = PoolMath.reservesAfterSwap(amountIn, reserveIn, reserveOut, FEE_30BPS);

        assertEq(newIn, reserveIn + amountIn);
        assertLt(newOut, reserveOut);
    }
}
