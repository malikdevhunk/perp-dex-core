// SPDX-License-Identifier: LicenseRef-SM-Source-Available-1.0
pragma solidity 0.8.28;

import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {Ownable2Step} from "../access/Ownable2Step.sol";

/// @title Chainlink-style oracle adapter with staleness and deviation guards.
/// @notice Scales aggregator answers to 1e18. The first accepted price sets the
///         deviation anchor. Later reads revert when the move exceeds
///         `maxDeviationBps` (set it to 0 to disable the check).
/// @dev Prices outside [$0.001, $100,000,000] are rejected so downstream math
///      cannot be forced into extreme values by a broken feed.
contract OracleAdapter is IPriceOracle, Ownable2Step {
    uint256 public constant MIN_PRICE = 1e15;
    uint256 public constant MAX_PRICE = 100_000_000e18;
    uint256 public constant MAX_DEVIATION_BPS = 10_000;

    AggregatorV3Interface public immutable aggregator;
    uint8 public immutable feedDecimals;

    uint256 public maxStaleness;
    uint256 public maxDeviationBps;
    uint256 public lastAcceptedPrice;

    event PriceAccepted(uint256 price, uint256 updatedAt);
    event ParamsUpdated(uint256 maxStaleness, uint256 maxDeviationBps);
    event AnchorReset(address indexed caller);

    error InvalidPrice();
    error StalePrice(uint256 updatedAt, uint256 nowTs);
    error IncompleteRound(uint80 roundId, uint80 answeredInRound);
    error PriceDeviation(uint256 price, uint256 anchor);
    error PriceOutOfBounds(uint256 price);
    error UnsupportedDecimals(uint8 decimals);
    error BadParams();

    /// @param maxStaleness_ Maximum age of `updatedAt`, in seconds. Must be non-zero.
    /// @param maxDeviationBps_ Inclusive deviation from the last accepted price. 0 disables it.
    constructor(address aggregator_, uint256 maxStaleness_, uint256 maxDeviationBps_, address owner_)
        Ownable2Step(owner_)
    {
        if (aggregator_ == address(0)) revert ZeroAddress();
        _validateParams(maxStaleness_, maxDeviationBps_);

        aggregator = AggregatorV3Interface(aggregator_);
        uint8 decimals_ = aggregator.decimals();
        if (decimals_ > 18) revert UnsupportedDecimals(decimals_);
        feedDecimals = decimals_;
        maxStaleness = maxStaleness_;
        maxDeviationBps = maxDeviationBps_;
    }

    /// @notice Owner update of the heartbeat and deviation limits.
    function setParams(uint256 maxStaleness_, uint256 maxDeviationBps_) external onlyOwner {
        _validateParams(maxStaleness_, maxDeviationBps_);
        maxStaleness = maxStaleness_;
        maxDeviationBps = maxDeviationBps_;
        emit ParamsUpdated(maxStaleness_, maxDeviationBps_);
    }

    /// @notice Clear the deviation anchor after a halted market so trading can resume.
    /// @dev The next {getPrice} accepts any in-range fresh price. This is an admin trust assumption.
    function resetAnchor() external onlyOwner {
        lastAcceptedPrice = 0;
        emit AnchorReset(msg.sender);
    }

    /// @inheritdoc IPriceOracle
    function peek() public view returns (uint256 price, uint256 updatedAt) {
        (price, updatedAt) = _read();
    }

    /// @inheritdoc IPriceOracle
    function getPrice() external returns (uint256 price) {
        uint256 updatedAt;
        (price, updatedAt) = _read();
        uint256 anchor = lastAcceptedPrice;
        uint256 deviationBps = maxDeviationBps;
        if (anchor != 0 && deviationBps != 0) {
            uint256 diff = price > anchor ? price - anchor : anchor - price;
            if (diff * 10_000 / anchor > deviationBps) revert PriceDeviation(price, anchor);
        }
        lastAcceptedPrice = price;
        emit PriceAccepted(price, updatedAt);
    }

    function _read() internal view returns (uint256 price, uint256 updatedAt) {
        (uint80 roundId, int256 answer,, uint256 updated, uint80 answeredInRound) = aggregator.latestRoundData();
        if (answer <= 0) revert InvalidPrice();
        if (updated == 0 || updated > block.timestamp || block.timestamp - updated > maxStaleness) {
            revert StalePrice(updated, block.timestamp);
        }
        if (answeredInRound < roundId) revert IncompleteRound(roundId, answeredInRound);

        price = uint256(answer);
        if (feedDecimals < 18) price *= 10 ** (18 - feedDecimals);
        if (price < MIN_PRICE || price > MAX_PRICE) revert PriceOutOfBounds(price);
        updatedAt = updated;
    }

    function _validateParams(uint256 maxStaleness_, uint256 maxDeviationBps_) internal pure {
        if (maxStaleness_ == 0 || maxDeviationBps_ > MAX_DEVIATION_BPS) revert BadParams();
    }
}
