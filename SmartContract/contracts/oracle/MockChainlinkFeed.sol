// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {AggregatorV3Interface} from "./AggregatorV3Interface.sol";

/// @notice Reference implementation of the real Chainlink
///         `AggregatorV3Interface` — stands in for a live Chainlink feed
///         (or any other AggregatorV3-compatible oracle) in tests and
///         local development, while matching the actual production
///         interface exactly, so swapping in a real feed address later
///         requires no code changes anywhere that reads from this type.
contract MockChainlinkFeed is AggregatorV3Interface {
    address public immutable owner;
    uint8 public immutable feedDecimals;
    string public feedDescription;

    struct Round {
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
    }

    mapping(uint80 => Round) public rounds;
    uint80 public latestRoundId;

    event AnswerUpdated(int256 indexed current, uint80 indexed roundId, uint256 updatedAt);

    error NotOwner();
    error InvalidRound();
    error InvalidAnswer();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param _decimals Precision of `answer`, matching real feeds (most
    ///        Chainlink USD pairs use 8).
    constructor(uint8 _decimals, string memory _description, int256 initialAnswer) {
        owner = msg.sender;
        feedDecimals = _decimals;
        feedDescription = _description;
        _pushRound(initialAnswer);
    }

    /// @notice Pushes a new round, as a real off-chain Chainlink node
    ///         (or, here, `realtime-price-pusher.js`) would.
    function pushRound(int256 answer) external onlyOwner {
        _pushRound(answer);
    }

    function _pushRound(int256 answer) internal {
        if (answer <= 0) revert InvalidAnswer();
        latestRoundId += 1;
        rounds[latestRoundId] = Round({answer: answer, startedAt: block.timestamp, updatedAt: block.timestamp});
        emit AnswerUpdated(answer, latestRoundId, block.timestamp);
    }

    // ----------------------------------------------------------------
    // AggregatorV3Interface
    // ----------------------------------------------------------------

    function decimals() external view returns (uint8) {
        return feedDecimals;
    }

    function description() external view returns (string memory) {
        return feedDescription;
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(
        uint80 _roundId
    ) external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) {
        Round memory r = rounds[_roundId];
        if (r.updatedAt == 0) revert InvalidRound();
        return (_roundId, r.answer, r.startedAt, r.updatedAt, _roundId);
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        Round memory r = rounds[latestRoundId];
        return (latestRoundId, r.answer, r.startedAt, r.updatedAt, latestRoundId);
    }
}
