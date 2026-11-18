// SPDX-License-Identifier: LicenseRef-SM-Source-Available-1.0
pragma solidity 0.8.28;

/// @title Price oracle consumed by the perpetual market.
/// @notice Prices are USD quote per 1 base unit, scaled by 1e18.
interface IPriceOracle {
    /// @notice Fresh price that also enforces the deviation guard and stores the anchor.
    function getPrice() external returns (uint256 price);

    /// @notice Fresh price that does not move the deviation anchor.
    function peek() external view returns (uint256 price, uint256 updatedAt);
}
