// SPDX-License-Identifier: LicenseRef-SM-Source-Available-1.0
pragma solidity 0.8.28;

/// @title Chainlink AggregatorV3 subset used by the oracle adapter.
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
