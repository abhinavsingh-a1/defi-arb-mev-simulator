// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

/// @title AggregatorV3Interface
/// @notice The standard interface Chainlink price feeds implement.
///         Reproduced here (function signatures only — this is the
///         de facto integration standard, not creative content) so
///         `OracleAggregator` reads from something matching what a real
///         production oracle looks like, rather than a bespoke mock
///         interface.
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);

    function description() external view returns (string memory);

    function version() external view returns (uint256);

    function getRoundData(
        uint80 _roundId
    )
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
