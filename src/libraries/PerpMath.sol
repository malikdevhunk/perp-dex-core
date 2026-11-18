// SPDX-License-Identifier: LicenseRef-SM-Source-Available-1.0
pragma solidity 0.8.28;

/// @title Fixed-point helpers for the perpetual engine.
library PerpMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    error AbsOverflow();

    /// @notice Absolute value. Reverts on `type(int256).min`.
    function abs(int256 x) internal pure returns (uint256) {
        if (x == type(int256).min) revert AbsOverflow();
        return uint256(x >= 0 ? x : -x);
    }

    /// @notice Quote notional of `size` base units at `price` (both 1e18).
    function notional(uint256 size, uint256 price) internal pure returns (uint256) {
        return size * price / WAD;
    }

    /// @notice `amount * bps / 10_000`, rounded up.
    function mulBpsUp(uint256 amount, uint256 bps) internal pure returns (uint256) {
        if (amount == 0 || bps == 0) return 0;
        return (amount * bps + BPS - 1) / BPS;
    }

    /// @notice `a * b / d`, rounded up. `d` must be non-zero.
    function mulDivUp(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        if (a == 0 || b == 0) return 0;
        return (a * b + d - 1) / d;
    }
}
