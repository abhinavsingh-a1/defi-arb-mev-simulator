// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "../contracts/amm/TickMath.sol";
import {MockUniswapV3Pool} from "../contracts/amm/MockUniswapV3Pool.sol";
import {MockERC20} from "../contracts/mocks/MockERC20.sol";

/// @notice Thin external wrapper so vm.expectRevert can catch a revert from
///         TickMath's internal function — same reasoning as
///         PoolMathHarness in PoolMath.t.sol: internal library calls get
///         inlined (no new call frame), which vm.expectRevert can't see
///         into on its own.
contract TickMathHarness {
    function getSqrtPriceAtTick(int24 tick) external pure returns (uint256) {
        return TickMath.getSqrtPriceAtTick(tick);
    }
}

contract TickMathTest is Test {
    TickMathHarness internal harness;

    function setUp() public {
        harness = new TickMathHarness();
    }

    function test_sqrtPriceAtTick_zeroIsOne() public pure {
        assertEq(TickMath.getSqrtPriceAtTick(0), 1e18);
    }

    function test_sqrtPriceAtTick_negativeIsReciprocalOfPositive() public pure {
        uint256 pos = TickMath.getSqrtPriceAtTick(1000);
        uint256 neg = TickMath.getSqrtPriceAtTick(-1000);
        // pos * neg should be ~1e36 (i.e. ~1.0 in WAD^2 terms), within rounding tolerance
        uint256 product = (pos * neg) / 1e18;
        assertApproxEqAbs(product, 1e18, 1e9); // tight tolerance at this tick range
    }

    function test_sqrtPriceAtTick_monotonicIncreasing() public pure {
        uint256 low = TickMath.getSqrtPriceAtTick(-500);
        uint256 mid = TickMath.getSqrtPriceAtTick(0);
        uint256 high = TickMath.getSqrtPriceAtTick(500);
        assertLt(low, mid);
        assertLt(mid, high);
    }

    function test_sqrtPriceAtTick_revertsOutOfRange() public {
        vm.expectRevert(TickMath.TickOutOfRange.selector);
        harness.getSqrtPriceAtTick(TickMath.MAX_TICK + 1);
    }
}

contract MockUniswapV3PoolTest is Test {
    MockUniswapV3Pool internal pool;
    MockERC20 internal token0;
    MockERC20 internal token1;

    address internal lp = makeAddr("lp");
    address internal trader = makeAddr("trader");

    int24 internal constant TICK_SPACING = 60;
    uint256 internal constant FEE_30BPS = 30;

    function setUp() public {
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);

        // Start pool at tick 0 -> price = 1.0 (token1 per token0)
        pool = new MockUniswapV3Pool(address(token0), address(token1), FEE_30BPS, TICK_SPACING, 0);

        token0.mint(lp, 10_000_000 ether);
        token1.mint(lp, 10_000_000 ether);
        token0.mint(trader, 1_000_000 ether);

        vm.startPrank(lp);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        vm.prank(trader);
        token0.approve(address(pool), type(uint256).max);
    }

    function test_mint_symmetricRangeAroundCurrentPrice_requiresBothTokens() public {
        vm.prank(lp);
        (uint256 amount0, uint256 amount1) = pool.mint(-1000, 1000, 1_000_000 ether);

        assertGt(amount0, 0);
        assertGt(amount1, 0);
        assertEq(pool.positionLiquidity(lp, -1000, 1000), 1_000_000 ether);
    }

    function test_mint_rangeEntirelyAboveCurrentPrice_requiresOnlyToken0() public {
        // current tick is 0; a range starting above 0 should be entirely token0
        vm.prank(lp);
        (uint256 amount0, uint256 amount1) = pool.mint(1000, 2000, 1_000_000 ether);

        assertGt(amount0, 0);
        assertEq(amount1, 0);
    }

    function test_mint_rangeEntirelyBelowCurrentPrice_requiresOnlyToken1() public {
        vm.prank(lp);
        (uint256 amount0, uint256 amount1) = pool.mint(-2000, -1000, 1_000_000 ether);

        assertEq(amount0, 0);
        assertGt(amount1, 0);
    }

    function test_mint_activatesLiquidityWhenRangeCoversCurrentTick() public {
        vm.prank(lp);
        pool.mint(-1000, 1000, 1_000_000 ether);

        assertEq(pool.liquidity(), 1_000_000 ether);
    }

    function test_mint_doesNotActivateLiquidityWhenRangeExcludesCurrentTick() public {
        vm.prank(lp);
        pool.mint(1000, 2000, 1_000_000 ether);

        assertEq(pool.liquidity(), 0);
    }

    function test_swap_withinSingleRange_movesTickTowardZero() public {
        vm.prank(lp);
        pool.mint(-6000, 6000, 5_000_000 ether);

        int24 tickBefore = pool.currentTick();

        vm.prank(trader);
        uint256 out = pool.swap(true, 10_000 ether, 0, trader);

        int24 tickAfter = pool.currentTick();

        assertGt(out, 0);
        assertLe(tickAfter, tickBefore); // selling token0 pushes price (and tick) down
        assertEq(token1.balanceOf(trader), out);
    }

    function test_swap_revertsBelowMinAmountOut() public {
        vm.prank(lp);
        pool.mint(-6000, 6000, 5_000_000 ether);

        vm.prank(trader);
        vm.expectRevert(MockUniswapV3Pool.InsufficientOutputAmount.selector);
        pool.swap(true, 10_000 ether, type(uint256).max, trader);
    }

    function test_swap_withNoLiquidity_refundsAndReturnsZero() public {
        // No mint() called — pool has zero active liquidity everywhere.
        // NOTE: balance read happens BEFORE the prank, not after — vm.prank
        // only applies to the single next call, and a read here would have
        // consumed it, leaving the actual swap() call running as the test
        // contract itself rather than `trader` (this was a real bug caught
        // by running the suite: it failed with "insufficient allowance"
        // because the test contract, not trader, was the effective caller).
        uint256 balBefore = token0.balanceOf(trader);

        vm.prank(trader);
        uint256 out = pool.swap(true, 1_000 ether, 0, trader);

        assertEq(out, 0);
        // Full amount should have been refunded since nothing could fill.
        assertEq(token0.balanceOf(trader), balBefore);
    }

    function test_burn_returnsUnderlyingTokens() public {
        vm.startPrank(lp);
        pool.mint(-1000, 1000, 1_000_000 ether);

        uint256 bal0Before = token0.balanceOf(lp);
        uint256 bal1Before = token1.balanceOf(lp);

        (uint256 amount0, uint256 amount1) = pool.burn(-1000, 1000, 1_000_000 ether);
        vm.stopPrank();

        assertGt(amount0, 0);
        assertGt(amount1, 0);
        assertEq(token0.balanceOf(lp), bal0Before + amount0);
        assertEq(token1.balanceOf(lp), bal1Before + amount1);
        assertEq(pool.positionLiquidity(lp, -1000, 1000), 0);
    }

    function test_swap_crossesIntoAdjacentRange() public {
        // Two adjacent liquidity ranges: a tight one around 0, and a wider
        // one further out. A large swap should cross out of the tight range
        // into the wider one rather than reverting or stalling.
        vm.startPrank(lp);
        pool.mint(-600, 600, 500_000 ether); // tight range
        pool.mint(-6000, 6000, 2_000_000 ether); // wide range, also covers current tick
        vm.stopPrank();

        uint256 liquidityBefore = pool.liquidity();
        assertEq(liquidityBefore, 2_500_000 ether); // both ranges active at tick 0

        vm.prank(trader);
        // 150,000 tokens — comfortably above the ~76,362 needed to reach
        // tick -600 (computed and verified by simulating this exact swap
        // math beforehand, not guessed: the original 50,000 here was a
        // real bug — it fell short of the threshold, so the swap never
        // actually crossed the tight range's boundary, and the test's
        // assertion below correctly failed).
        uint256 out = pool.swap(true, 150_000 ether, 0, trader);

        assertGt(out, 0);
        // After crossing tick -600 (exiting the tight range), active
        // liquidity should drop back to just the wide range's contribution.
        assertLt(pool.liquidity(), liquidityBefore);
    }
}
