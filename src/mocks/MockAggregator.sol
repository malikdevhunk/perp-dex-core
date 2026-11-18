// SPDX-License-Identifier: LicenseRef-SM-Source-Available-1.0
pragma solidity 0.8.28;

import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";

/// @title Controllable Chainlink-style feed for local runs and tests.
contract MockAggregator is AggregatorV3Interface {
    uint8 public decimals;
    int256 public answer;
    uint80 public roundId;
    uint80 public answeredInRound;
    uint256 public updatedAt;

    constructor(uint8 decimals_) {
        decimals = decimals_;
        roundId = 1;
        answeredInRound = 1;
        updatedAt = block.timestamp;
        answer = 1;
    }

    /// @notice Set the price and start a completed round stamped at `block.timestamp`.
    function setPrice(int256 answer_) external {
        answer = answer_;
        roundId += 1;
        answeredInRound = roundId;
        updatedAt = block.timestamp;
    }

    /// @notice Refresh the heartbeat without changing the price.
    function poke() external {
        roundId += 1;
        answeredInRound = roundId;
        updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 timestamp) external {
        updatedAt = timestamp;
    }

    function setAnsweredInRound(uint80 value) external {
        answeredInRound = value;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }
}
