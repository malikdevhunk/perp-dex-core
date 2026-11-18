// SPDX-License-Identifier: LicenseRef-SM-Source-Available-1.0
pragma solidity 0.8.28;

import {BaseTest} from "./Base.sol";

contract PerpMarketFuzzTest is BaseTest {
    function testFuzz_openRespectsLeverage(uint256 sizeRaw, uint256 extraRaw, uint256 priceRaw) public {
        uint256 price = bound(priceRaw, 500e18, 20_000e18);
        _setPrices(price, price);
        (uint256 mark,) = market.previewPrices();

        uint256 size = bound(sizeRaw, 0.2e18, 5e18);
        uint256 notion = size * mark / WAD;
        vm.assume(notion >= 10e18);
        uint256 minMargin = (notion * WAD + 10e18 - 1) / 10e18;
        uint256 margin = minMargin + bound(extraRaw, 0, minMargin);

        _open(alice, int256(size), margin);

        (, uint256 posted,,) = market.positions(alice);
        uint256 liveNotional = size * mark / WAD;
        assertGe(posted, (liveNotional * WAD + 10e18 - 1) / 10e18);
        _assertSolvent();
    }

    function testFuzz_longPnlRisesWithMark(uint256 sizeRaw, uint256 stepRaw) public {
        uint256 size = bound(sizeRaw, 0.2e18, 5e18);
        _open(alice, int256(size), 20_000e18);
        (, int256 pnlBefore,,,) = market.positionEquity(alice);

        uint256 step = bound(stepRaw, 1, 25);
        _setPrices(2_000e18 * (100 + step) / 100, 2_000e18 * (100 + step) / 100);
        (, int256 pnlAfter,,,) = market.positionEquity(alice);
        assertGt(pnlAfter, pnlBefore);
    }

    function testFuzz_shortPnlRisesWhenMarkFalls(uint256 sizeRaw, uint256 stepRaw) public {
        uint256 size = bound(sizeRaw, 0.2e18, 5e18);
        _open(alice, -int256(size), 20_000e18);
        (, int256 pnlBefore,,,) = market.positionEquity(alice);

        uint256 step = bound(stepRaw, 1, 25);
        _setPrices(2_000e18 * (100 - step) / 100, 2_000e18 * (100 - step) / 100);
        (, int256 pnlAfter,,,) = market.positionEquity(alice);
        assertGt(pnlAfter, pnlBefore);
    }

    /// @notice A full close never credits more than post-funding margin plus positive PnL.
    function testFuzz_closePayoutBounded(uint256 sizeRaw, uint256 extraRaw, uint256 exitRaw, bool isShort) public {
        uint256 entryHint = bound(exitRaw, 800e18, 4_000e18);
        // `exitRaw` seeds both ends so the fuzzer explores the whole range; re-bound the exit below.
        _setPrices(2_000e18, 2_000e18);
        (uint256 entry,) = market.previewPrices();

        uint256 size = bound(sizeRaw, 0.2e18, 5e18);
        uint256 notion = size * entry / WAD;
        uint256 minMargin = (notion * WAD + 10e18 - 1) / 10e18;
        uint256 margin = minMargin + bound(extraRaw, 1e18, minMargin + 1e18);

        int256 sizeDelta = isShort ? -int256(size) : int256(size);
        _open(alice, sizeDelta, margin);

        uint256 exitHint = bound(entryHint, entry * 60 / 100, entry * 160 / 100);
        _setPrices(exitHint, exitHint);
        (uint256 exitPx,) = market.previewPrices();

        (int256 sz, uint256 marginNow, int256 openNotional,) = market.positions(alice);
        int256 expectedPnl = sz * int256(exitPx) / int256(WAD) - openNotional;
        uint256 absSize = sz >= 0 ? uint256(sz) : uint256(-sz);

        uint256 freeBefore = vault.freeBalance(alice);
        vm.prank(alice);
        uint256 payout = market.closePosition(absSize);
        uint256 received = vault.freeBalance(alice) - freeBefore;

        uint256 cap = marginNow;
        if (expectedPnl > 0) cap += uint256(expectedPnl);
        assertLe(received, cap);
        assertLe(payout, cap);
        assertEq(received, payout);
        _assertSolvent();
    }

    function testFuzz_fundingPaymentRespectsPremiumCap(uint256 dtRaw) public {
        _open(alice, 1e18, 5_000e18);
        // 10% rich mark, clamped to the 5% premium cap.
        _setPrices(2_000e18, 2_200e18);
        uint256 dt = bound(dtRaw, 1 hours, 6 hours);
        vm.warp(block.timestamp + dt);

        uint256 marginBefore;
        (, marginBefore,,) = market.positions(alice);
        market.settleFunding(alice);
        (, uint256 marginAfter,,) = market.positions(alice);

        // payment <= size * maxPremium * index * dt / fundingPeriod
        //         = 0.05 * 2000e18 * dt / 1 hours
        uint256 maxPay = 100e18 * dt / 1 hours;
        assertLe(marginBefore - marginAfter, maxPay);
        _assertSolvent();
    }
}
