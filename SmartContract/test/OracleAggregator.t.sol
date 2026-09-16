// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {Test} from "forge-std/Test.sol";
import {OracleAggregator} from "../contracts/oracle/OracleAggregator.sol";
import {MockChainlinkFeed} from "../contracts/oracle/MockChainlinkFeed.sol";
import {MockPrimaryOracle} from "../contracts/mocks/MockPrimaryOracle.sol";

contract OracleAggregatorTest is Test {
    MockPrimaryOracle internal primary;
    MockChainlinkFeed internal secondary;
    OracleAggregator internal aggregator;

    bytes32 internal constant ASSET_ID = keccak256("ETH/USD");
    uint256 internal constant MAX_STALENESS = 1 hours;
    uint8 internal constant FEED_DECIMALS = 8; // matches real Chainlink USD feeds

    function setUp() public {
        primary = new MockPrimaryOracle();
        // MockChainlinkFeed uses its own `decimals` precision (8, like a
        // real Chainlink USD feed) — $2000 => 2000 * 1e8.
        secondary = new MockChainlinkFeed(FEED_DECIMALS, "ETH/USD", 2000 * 1e8);

        primary.setPrice(ASSET_ID, 2000 ether); // primary oracle is WAD-native

        aggregator = new OracleAggregator(address(primary), address(secondary), ASSET_ID, MAX_STALENESS);
    }

    function test_getPrices_agreeingFeeds_zeroDeviation() public view {
        (uint256 p, uint256 s, uint256 devBps) = aggregator.getPrices();
        assertEq(p, 2000 ether);
        assertEq(s, 2000 ether); // converted from 8-decimal Chainlink precision to WAD
        assertEq(devBps, 0);
    }

    function test_getPrices_divergingFeeds_reportsDeviation() public {
        secondary.pushRound(2100 * 1e8); // 5% higher

        (, , uint256 devBps) = aggregator.getPrices();
        // (2100-2000)/2000 = 5% = 500 bps
        assertEq(devBps, 500);
    }

    function test_getPrices_revertsOnStalePrimary() public {
        vm.warp(block.timestamp + MAX_STALENESS + 1);
        vm.expectRevert(OracleAggregator.StalePrice.selector);
        aggregator.getPrices();
    }

    function test_getPrices_freshUpdateResetsStaleness() public {
        vm.warp(block.timestamp + MAX_STALENESS + 1);
        primary.setPrice(ASSET_ID, 2050 ether); // refresh primary
        secondary.pushRound(2050 * 1e8); // refresh secondary

        (uint256 p, uint256 s, uint256 devBps) = aggregator.getPrices();
        assertEq(p, 2050 ether);
        assertEq(s, 2050 ether);
        assertEq(devBps, 0);
    }

    function test_constructor_revertsOnNonPositiveInitialAnswer() public {
        // MockChainlinkFeed enforces answer > 0 at construction (and on
        // every subsequent pushRound), mirroring the sanity checks a real
        // consumer should apply to Chainlink's `answer` field, which is
        // signed and can technically be <= 0 in degenerate feed states.
        vm.expectRevert(MockChainlinkFeed.InvalidAnswer.selector);
        new MockChainlinkFeed(FEED_DECIMALS, "BROKEN/USD", 0);
    }

    function test_decimalConversion_handlesNonWadFeedPrecision() public {
        // Sanity check the 8-decimals -> WAD conversion independent of the
        // "agreeing feeds" test above: push a price with a fractional cent
        // component representable at 8 decimals.
        secondary.pushRound(2000_12345678); // $2000.12345678 at 8 decimals
        primary.setPrice(ASSET_ID, 2000_12345678 * 1e10); // same value, WAD-native

        (uint256 p, uint256 s, uint256 devBps) = aggregator.getPrices();
        assertEq(p, s);
        assertEq(devBps, 0);
    }
}
