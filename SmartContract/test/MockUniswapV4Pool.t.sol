// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {MockUniswapV4Pool} from "../contracts/amm/MockUniswapV4Pool.sol";
import {IHooks} from "../contracts/hooks/IHooks.sol";
import {NoOpHooks} from "../contracts/hooks/NoOpHooks.sol";
import {MockERC20} from "../contracts/mocks/MockERC20.sol";

/// @notice Test double that records every hook call it receives, so tests
///         can assert the pool actually invoked the hooks it's supposed
///         to — not just that swaps/mints still work with a hook attached.
contract RecordingHooks is IHooks {
    uint256 public beforeSwapCalls;
    uint256 public afterSwapCalls;
    uint256 public beforeAddLiquidityCalls;
    uint256 public afterAddLiquidityCalls;

    // last-seen args, for assertions
    bool public lastZeroForOne;
    uint256 public lastAmountIn;
    uint256 public lastAmountOut;

    function beforeInitialize(address, uint256) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, uint256, int24) external pure returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, int24, int24, uint256) external returns (bytes4) {
        beforeAddLiquidityCalls++;
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(address, int24, int24, uint256, uint256, uint256) external returns (bytes4) {
        afterAddLiquidityCalls++;
        return IHooks.afterAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(address, int24, int24, uint256) external pure returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(address, int24, int24, uint256, uint256, uint256) external pure returns (bytes4) {
        return IHooks.afterRemoveLiquidity.selector;
    }

    function beforeSwap(address, bool zeroForOne, uint256 amountIn) external returns (bytes4, uint256, bool) {
        beforeSwapCalls++;
        lastZeroForOne = zeroForOne;
        lastAmountIn = amountIn;
        return (IHooks.beforeSwap.selector, 0, false);
    }

    function afterSwap(address, bool, uint256, uint256 amountOut) external returns (bytes4) {
        afterSwapCalls++;
        lastAmountOut = amountOut;
        return IHooks.afterSwap.selector;
    }
}

/// @notice Test double that overrides the swap fee to a fixed value,
///         exercising the dynamic-fee path.
contract FixedFeeOverrideHooks is IHooks {
    uint256 public immutable overrideFeeBps;

    constructor(uint256 _overrideFeeBps) {
        overrideFeeBps = _overrideFeeBps;
    }

    function beforeInitialize(address, uint256) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, uint256, int24) external pure returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, int24, int24, uint256) external pure returns (bytes4) {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(address, int24, int24, uint256, uint256, uint256) external pure returns (bytes4) {
        return IHooks.afterAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(address, int24, int24, uint256) external pure returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(address, int24, int24, uint256, uint256, uint256) external pure returns (bytes4) {
        return IHooks.afterRemoveLiquidity.selector;
    }

    function beforeSwap(address, bool, uint256) external view returns (bytes4, uint256, bool) {
        return (IHooks.beforeSwap.selector, overrideFeeBps, true);
    }

    function afterSwap(address, bool, uint256, uint256) external pure returns (bytes4) {
        return IHooks.afterSwap.selector;
    }
}

/// @notice Test double that returns the WRONG selector, to verify the
///         pool's magic-value check actually rejects malformed hooks.
contract BrokenHooks is IHooks {
    function beforeInitialize(address, uint256) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, uint256, int24) external pure returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, int24, int24, uint256) external pure returns (bytes4) {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(address, int24, int24, uint256, uint256, uint256) external pure returns (bytes4) {
        return IHooks.afterAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(address, int24, int24, uint256) external pure returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(address, int24, int24, uint256, uint256, uint256) external pure returns (bytes4) {
        return IHooks.afterRemoveLiquidity.selector;
    }

    function beforeSwap(address, bool, uint256) external pure returns (bytes4, uint256, bool) {
        return (bytes4(0xdeadbeef), 0, false); // wrong on purpose
    }

    function afterSwap(address, bool, uint256, uint256) external pure returns (bytes4) {
        return IHooks.afterSwap.selector;
    }
}

contract MockUniswapV4PoolTest is Test {
    MockERC20 internal token0;
    MockERC20 internal token1;
    address internal lp = makeAddr("lp");
    address internal trader = makeAddr("trader");

    int24 internal constant TICK_SPACING = 60;
    uint256 internal constant FEE_30BPS = 30;

    function setUp() public {
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);

        token0.mint(lp, 10_000_000 ether);
        token1.mint(lp, 10_000_000 ether);
        token0.mint(trader, 1_000_000 ether);
    }

    function _deployPool(address hooksAddr) internal returns (MockUniswapV4Pool pool) {
        pool = new MockUniswapV4Pool(address(token0), address(token1), FEE_30BPS, TICK_SPACING, 0, hooksAddr);

        vm.startPrank(lp);
        token0.approve(address(pool), type(uint256).max);
        token1.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        vm.prank(trader);
        token0.approve(address(pool), type(uint256).max);
    }

    // ----------------------------------------------------------------
    // Baseline: no hooks — should behave like MockUniswapV3Pool
    // ----------------------------------------------------------------

    function test_noHooks_mintAndSwapWork() public {
        MockUniswapV4Pool pool = _deployPool(address(0));

        vm.prank(lp);
        pool.mint(-6000, 6000, 5_000_000 ether);

        vm.prank(trader);
        uint256 out = pool.swap(true, 10_000 ether, 0, trader);

        assertGt(out, 0);
        assertEq(token1.balanceOf(trader), out);
    }

    // ----------------------------------------------------------------
    // Hook plumbing actually fires
    // ----------------------------------------------------------------

    function test_hooks_areActuallyCalled() public {
        RecordingHooks hooks = new RecordingHooks();
        MockUniswapV4Pool pool = _deployPool(address(hooks));

        vm.prank(lp);
        pool.mint(-6000, 6000, 5_000_000 ether);
        assertEq(hooks.beforeAddLiquidityCalls(), 1);
        assertEq(hooks.afterAddLiquidityCalls(), 1);

        vm.prank(trader);
        uint256 out = pool.swap(true, 10_000 ether, 0, trader);

        assertEq(hooks.beforeSwapCalls(), 1);
        assertEq(hooks.afterSwapCalls(), 1);
        assertTrue(hooks.lastZeroForOne());
        assertEq(hooks.lastAmountIn(), 10_000 ether);
        assertEq(hooks.lastAmountOut(), out);
    }

    function test_noOpHooks_doNotChangeSwapBehavior() public {
        MockUniswapV4Pool poolNoHooks = _deployPool(address(0));
        MockUniswapV4Pool poolNoOp = _deployPool(address(new NoOpHooks()));

        vm.startPrank(lp);
        poolNoHooks.mint(-6000, 6000, 5_000_000 ether);
        vm.stopPrank();

        // separate lp approval needed for second pool instance
        vm.startPrank(lp);
        poolNoOp.mint(-6000, 6000, 5_000_000 ether);
        vm.stopPrank();

        vm.prank(trader);
        uint256 outNoHooks = poolNoHooks.swap(true, 10_000 ether, 0, trader);

        token0.mint(trader, 10_000 ether);
        vm.prank(trader);
        token0.approve(address(poolNoOp), type(uint256).max);
        vm.prank(trader);
        uint256 outNoOp = poolNoOp.swap(true, 10_000 ether, 0, trader);

        assertEq(outNoHooks, outNoOp);
    }

    // ----------------------------------------------------------------
    // Dynamic fee override
    // ----------------------------------------------------------------

    function test_hookFeeOverride_changesOutputAmount() public {
        MockUniswapV4Pool poolBaseFee = _deployPool(address(0)); // 30 bps
        FixedFeeOverrideHooks highFeeHooks = new FixedFeeOverrideHooks(500); // 5%
        MockUniswapV4Pool poolHighFee = _deployPool(address(highFeeHooks));

        vm.prank(lp);
        poolBaseFee.mint(-6000, 6000, 5_000_000 ether);
        vm.prank(lp);
        poolHighFee.mint(-6000, 6000, 5_000_000 ether);

        vm.prank(trader);
        uint256 outBaseFee = poolBaseFee.swap(true, 10_000 ether, 0, trader);

        token0.mint(trader, 10_000 ether);
        vm.prank(trader);
        token0.approve(address(poolHighFee), type(uint256).max);
        vm.prank(trader);
        uint256 outHighFee = poolHighFee.swap(true, 10_000 ether, 0, trader);

        // A much higher fee should mean meaningfully less output for the
        // same nominal input.
        assertLt(outHighFee, outBaseFee);
    }

    // ----------------------------------------------------------------
    // Invalid hook responses are rejected
    // ----------------------------------------------------------------

    function test_brokenHook_revertsSwap() public {
        BrokenHooks hooks = new BrokenHooks();
        MockUniswapV4Pool pool = _deployPool(address(hooks));

        vm.prank(lp);
        pool.mint(-6000, 6000, 5_000_000 ether);

        vm.prank(trader);
        vm.expectRevert(MockUniswapV4Pool.InvalidHookResponse.selector);
        pool.swap(true, 10_000 ether, 0, trader);
    }
}
