// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {DeviationWatcher} from "../contracts/oracle/DeviationWatcher.sol";
import {OracleAggregator} from "../contracts/oracle/OracleAggregator.sol";
import {MockChainlinkFeed} from "../contracts/oracle/MockChainlinkFeed.sol";
import {MockPrimaryOracle} from "../contracts/mocks/MockPrimaryOracle.sol";
import {MockUniswapV2Pool} from "../contracts/amm/MockUniswapV2Pool.sol";
import {MockERC20} from "../contracts/mocks/MockERC20.sol";

contract DeviationWatcherTest is Test {
    DeviationWatcher internal watcher;
    OracleAggregator internal aggregator;
    MockPrimaryOracle internal primary;
    MockChainlinkFeed internal secondary;
    MockUniswapV2Pool internal pool;
    MockERC20 internal asset; // token0
    MockERC20 internal usd; // token1

    address internal owner = address(this);
    address internal lp = makeAddr("lp");

    bytes32 internal constant ASSET_ID = keccak256("ETH/USD");
    uint256 internal constant FEE_30BPS = 30;
    uint256 internal constant ORACLE_PRICE = 2000 ether; // $2000

    function setUp() public {
        asset = new MockERC20("Asset", "AST", 18);
        usd = new MockERC20("USD", "USD", 18);

        // Pool priced so spot price (token1/token0) == $2000, matching the oracle.
        pool = new MockUniswapV2Pool(address(asset), address(usd), FEE_30BPS);
        asset.mint(lp, 1_000 ether);
        usd.mint(lp, 2_000_000 ether);
        vm.startPrank(lp);
        asset.approve(address(pool), type(uint256).max);
        usd.approve(address(pool), type(uint256).max);
        pool.addLiquidity(1_000 ether, 2_000_000 ether); // 1000 asset : 2,000,000 usd => price 2000
        vm.stopPrank();

        primary = new MockPrimaryOracle();
        primary.setPrice(ASSET_ID, ORACLE_PRICE);
        secondary = new MockChainlinkFeed(8, "ETH/USD", 2000 * 1e8); // $2000 at 8-decimal Chainlink precision

        aggregator = new OracleAggregator(address(primary), address(secondary), ASSET_ID, 1 hours);

        watcher = new DeviationWatcher();
        watcher.addWatch(address(pool), address(aggregator), true, 300); // 3% threshold
    }

    function test_computeDeviation_matchingPrices_zeroDeviation() public view {
        (uint256 ammPrice, uint256 oraclePrice, uint256 devBps) = watcher.computeDeviation(0);
        assertEq(ammPrice, ORACLE_PRICE);
        assertEq(oraclePrice, ORACLE_PRICE);
        assertEq(devBps, 0);
    }

    function test_poke_belowThreshold_doesNotTrigger() public {
        // Nudge oracle price slightly (1%) — below the 3% threshold.
        primary.setPrice(ASSET_ID, 2020 ether);

        bool triggered = watcher.poke(0);
        assertFalse(triggered);
    }

    function test_poke_aboveThreshold_triggersAndEmits() public {
        // Oracle moves to $2200 (10% above AMM's $2000) — above 3% threshold.
        primary.setPrice(ASSET_ID, 2200 ether);

        vm.expectEmit(true, false, false, false);
        emit DeviationWatcher.DeviationDetected(0, 0, 0, 0, 0); // topic-only match on watchId
        bool triggered = watcher.poke(0);

        assertTrue(triggered);
    }

    function test_poke_ammDivergesFromBothOracleFeeds_triggers() public {
        // Simulate a large AMM trade pushing the pool price away from a
        // stable oracle — the scenario this contract exists to catch.
        address trader = makeAddr("trader");
        asset.mint(trader, 500 ether);
        vm.startPrank(trader);
        asset.approve(address(pool), type(uint256).max);
        pool.swap(address(asset), 500 ether, 0, trader); // big buy pressure on usd out
        vm.stopPrank();

        bool triggered = watcher.poke(0);
        assertTrue(triggered);
    }

    function test_addWatch_onlyOwner() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert(DeviationWatcher.NotOwner.selector);
        watcher.addWatch(address(pool), address(aggregator), true, 300);
    }

    function test_deactivateWatch_blocksFurtherChecks() public {
        watcher.deactivateWatch(0);
        vm.expectRevert(DeviationWatcher.WatchInactive.selector);
        watcher.computeDeviation(0);
    }

    function test_computeDeviation_revertsOnInvalidWatchId() public {
        vm.expectRevert(DeviationWatcher.InvalidWatch.selector);
        watcher.computeDeviation(99);
    }
}
