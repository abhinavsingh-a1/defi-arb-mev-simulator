// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IPriceOracle} from "../oracle/IPriceOracle.sol";

/// @notice Test double / reference implementation of IPriceOracle.
///         Stands in for a real primary oracle adapter (yours or a third
///         party's) so the oracle module can be built and tested
///         standalone, without depending on any other project.
contract MockPrimaryOracle is IPriceOracle {
    mapping(bytes32 => uint256) public prices;
    mapping(bytes32 => uint256) public updatedAts;

    function setPrice(bytes32 assetId, uint256 price) external {
        prices[assetId] = price;
        updatedAts[assetId] = block.timestamp;
    }

    function getLatestPrice(bytes32 assetId) external view returns (uint256 price, uint256 updatedAt) {
        return (prices[assetId], updatedAts[assetId]);
    }
}
