// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {MockUniswapV2Pool} from "../contracts/amm/MockUniswapV2Pool.sol";
import {MockERC20} from "../contracts/mocks/MockERC20.sol";

contract MockUniswapV2PoolTest is Test {
    MockUniswapV2Pool internal pool;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;

    address internal lp = makeAddr("lp");
    address internal trader = makeAddr("trader");

    uint256 internal constant FEE_30BPS = 30;

    function setUp() public {
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);

        // Pool expects token0/token1 as constructor args — order doesn't
        // matter for these tests as long as we're consistent.
        pool = new MockUniswapV2Pool(address(tokenA), address(tokenB), FEE_30BPS);

        // Fund LP and trader
        tokenA.mint(lp, 1_000_000 ether);
        tokenB.mint(lp, 1_000_000 ether);
        tokenA.mint(trader, 10_000 ether);

        vm.prank(lp);
        tokenA.approve(address(pool), type(uint256).max);
        vm.prank(lp);
        tokenB.approve(address(pool), type(uint256).max);

        vm.prank(trader);
        tokenA.approve(address(pool), type(uint256).max);
    }

    // ----------------------------------------------------------------
    // Liquidity provision
    // ----------------------------------------------------------------

    function test_addLiquidity_firstMint_locksMinimumLiquidity() public {
        vm.prank(lp);
        uint256 liquidity = pool.addLiquidity(100_000 ether, 100_000 ether);

        // sqrt(100_000e18 * 100_000e18) - MINIMUM_LIQUIDITY
        uint256 expected = _sqrt(100_000 ether * 100_000 ether) - pool.MINIMUM_LIQUIDITY();
        assertEq(liquidity, expected);
        assertEq(pool.liquidityOf(address(0)), pool.MINIMUM_LIQUIDITY());

        (uint256 r0, uint256 r1) = pool.getReserves();
        assertEq(r0, 100_000 ether);
        assertEq(r1, 100_000 ether);
    }

    function test_addLiquidity_secondMint_proportional() public {
        vm.startPrank(lp);
        pool.addLiquidity(100_000 ether, 100_000 ether);

        uint256 liquidityBefore = pool.totalLiquidity();
        uint256 added = pool.addLiquidity(10_000 ether, 10_000 ether); // 10% of pool
        vm.stopPrank();

        // Should mint ~10% of prior total liquidity
        uint256 expected = liquidityBefore / 10;
        // allow small rounding tolerance
        assertApproxEqAbs(added, expected, 2);
    }

    function test_removeLiquidity_returnsProportionalTokens() public {
        vm.startPrank(lp);
        uint256 liquidity = pool.addLiquidity(100_000 ether, 100_000 ether);

        uint256 balBefore = tokenA.balanceOf(lp);
        (uint256 amount0, uint256 amount1) = pool.removeLiquidity(liquidity);
        vm.stopPrank();

        assertGt(amount0, 0);
        assertGt(amount1, 0);
        assertEq(tokenA.balanceOf(lp), balBefore + amount0);
    }

    function test_addLiquidity_revertsOnZeroAmount() public {
        vm.prank(lp);
        vm.expectRevert(MockUniswapV2Pool.ZeroAmount.selector);
        pool.addLiquidity(0, 100 ether);
    }

    // ----------------------------------------------------------------
    // Swaps
    // ----------------------------------------------------------------

    function test_swap_matchesPoolMathQuote() public {
        vm.prank(lp);
        pool.addLiquidity(100_000 ether, 100_000 ether);

        uint256 amountIn = 1_000 ether;
        uint256 quoted = pool.quote(address(tokenA), amountIn);

        vm.prank(trader);
        uint256 amountOut = pool.swap(address(tokenA), amountIn, 0, trader);

        assertEq(amountOut, quoted);
        assertEq(tokenB.balanceOf(trader), amountOut);
    }

    function test_swap_revertsBelowMinAmountOut() public {
        vm.prank(lp);
        pool.addLiquidity(100_000 ether, 100_000 ether);

        uint256 amountIn = 1_000 ether;
        uint256 quoted = pool.quote(address(tokenA), amountIn);

        vm.prank(trader);
        vm.expectRevert(MockUniswapV2Pool.InsufficientOutputAmount.selector);
        pool.swap(address(tokenA), amountIn, quoted + 1, trader); // demand more than possible
    }

    function test_swap_revertsOnInvalidToken() public {
        vm.prank(lp);
        pool.addLiquidity(100_000 ether, 100_000 ether);

        MockERC20 randomToken = new MockERC20("Random", "RND", 18);
        vm.prank(trader);
        vm.expectRevert(MockUniswapV2Pool.InvalidToken.selector);
        pool.swap(address(randomToken), 100 ether, 0, trader);
    }

    function test_swap_kNeverDecreases() public {
        vm.prank(lp);
        pool.addLiquidity(100_000 ether, 100_000 ether);

        (uint256 r0Before, uint256 r1Before) = pool.getReserves();
        uint256 kBefore = r0Before * r1Before;

        vm.prank(trader);
        pool.swap(address(tokenA), 5_000 ether, 0, trader);

        (uint256 r0After, uint256 r1After) = pool.getReserves();
        uint256 kAfter = r0After * r1After;

        assertGe(kAfter, kBefore);
    }

    function testFuzz_swap_neverRevertsForReasonableInputs(uint96 amountIn) public {
        vm.assume(amountIn > 0.001 ether && amountIn < 5_000 ether);

        vm.prank(lp);
        pool.addLiquidity(100_000 ether, 100_000 ether);

        tokenA.mint(trader, amountIn);
        vm.prank(trader);
        uint256 out = pool.swap(address(tokenA), amountIn, 0, trader);

        assertGt(out, 0);
    }

    // ----------------------------------------------------------------
    // helpers
    // ----------------------------------------------------------------

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
