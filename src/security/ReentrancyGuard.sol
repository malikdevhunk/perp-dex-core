// SPDX-License-Identifier: LicenseRef-SM-Source-Available-1.0
pragma solidity 0.8.28;

/// @title Single-slot reentrancy guard.
abstract contract ReentrancyGuard {
    uint256 private constant UNLOCKED = 1;
    uint256 private constant LOCKED = 2;

    uint256 private _status;

    error Reentrancy();

    constructor() {
        _status = UNLOCKED;
    }

    modifier nonReentrant() {
        if (_status == LOCKED) revert Reentrancy();
        _status = LOCKED;
        _;
        _status = UNLOCKED;
    }
}
