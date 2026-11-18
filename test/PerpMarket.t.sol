// SPDX-License-Identifier: LicenseRef-SM-Source-Available-1.0
pragma solidity 0.8.28;

import {BaseTest} from "./Base.sol";
import {PerpMarket} from "../src/core/PerpMarket.sol";
import {CollateralVault} from "../src/vault/CollateralVault.sol";
import {Ownable2Step} from "../src/access/Ownable2Step.sol";
import {Pausable} from "../src/security/Pausable.sol";

contract PerpMarketTest is BaseTest {
    function test_depositCreditsInternalUnits() public view {
        assertEq(vault.scaleFactor(), 1e12);
        assertEq(vault.freeBalance(alice), 100_000e18);
        assertEq(market.tokenToInternal(1e6), 1e18);
    }

    function test_withdrawReturnsTokensAndLeavesLockedAlone() public {
        _open(alice, 1e18, 500e18);
        uint256 freeTokens = vault.freeBalance(alice) / 1e12;
        uint256 lockedBefore = vault.lockedBalance(alice);

        vm.prank(alice);
        vault.withdraw(freeTokens);

        assertEq(vault.freeBalance(alice), 0);
        assertEq(vault.lockedBalance(alice), lockedBefore);
        vm.prank(alice);
        vm.expectRevert(CollateralVault.InsufficientBalance.selector);
        vault.withdraw(1);
        _assertSolvent();
    }

    function test_openLongLocksMarginChargesFeeAndCapsLeverage() public {
        uint256 insuranceBefore = vault.insuranceFund();
        uint256 feesBefore = vault.protocolFees();

        _open(alice, 1e18, 500e18);

        (int256 size, uint256 margin, int256 openNotional, int256 fundingIndex) = market.positions(alice);
        assertEq(size, 1e18);
        assertEq(margin, 500e18);
        assertEq(openNotional, 2_000e18);
        assertEq(fundingIndex, 0);
        assertEq(market.netSize(), 1e18);
        assertEq(market.totalOpenInterest(), 1e18);
        assertEq(vault.lockedBalance(alice), 500e18);
        // 0.10% of $2,000 = $2, split evenly.
        assertEq(vault.insuranceFund(), insuranceBefore + 1e18);
        assertEq(vault.protocolFees(), feesBefore + 1e18);
        _assertSolvent();
    }

    function test_openRevertsAboveLeverageOrBelowMinNotional() public {
        vm.prank(alice);
        vm.expectRevert(PerpMarket.LeverageExceeded.selector);
        market.openPosition(1e18, 200e18 - 1);

        vm.prank(alice);
        vm.expectRevert(PerpMarket.BelowMinNotional.selector);
        market.openPosition(0.001e18, 500e18);
    }

    function test_cannotFlipDirection() public {
        _open(alice, 1e18, 500e18);
        vm.prank(alice);
        vm.expectRevert(PerpMarket.OppositeDirection.selector);
        market.openPosition(-1e18, 500e18);
    }

    function test_increaseAveragesEntry() public {
        _open(alice, 1e18, 500e18);
        _setPrices(2_200e18, 2_200e18);
        _open(alice, 1e18, 500e18);

        (int256 size,, int256 openNotional,) = market.positions(alice);
        assertEq(size, 2e18);
        assertEq(openNotional, 4_200e18);
        assertEq(market.totalOpenInterest(), 2e18);
    }

    function test_longProfitAndShortLossNetToFees() public {
        _open(alice, 1e18, 500e18);
        _open(bob, -1e18, 500e18);
        _setPrices(2_200e18, 2_200e18);

        uint256 insuranceBefore = vault.insuranceFund();
        uint256 aliceBefore = vault.freeBalance(alice);

        vm.prank(alice);
        uint256 alicePayout = market.closePosition(1e18);
        vm.prank(bob);
        uint256 bobPayout = market.closePosition(1e18);

        // Long PnL +200, short PnL -200. Close notional $2,200, fee $2.20 each.
        assertEq(alicePayout, 700e18 - 2.2e18);
        assertEq(bobPayout, 300e18 - 2.2e18);
        assertEq(vault.freeBalance(alice) - aliceBefore, alicePayout);
        // Insurance paid 200 and received 200, plus half of both close fees ($1.10 twice).
        assertEq(vault.insuranceFund(), insuranceBefore + 2.2e18);
        assertEq(market.netSize(), 0);
        assertEq(market.totalOpenInterest(), 0);
        assertLe(alicePayout, 500e18 + 200e18);
        assertLe(bobPayout, 500e18);
        _assertSolvent();
    }

    function test_lossClosePaysRemainderOnly() public {
        _open(alice, 1e18, 500e18);
        _setPrices(1_900e18, 1_900e18);
        uint256 before = vault.freeBalance(alice);

        vm.prank(alice);
        uint256 payout = market.closePosition(1e18);

        // PnL -100, fee 0.10% of $1,900 = $1.90.
        assertEq(payout, 400e18 - 1.9e18);
        assertEq(vault.freeBalance(alice) - before, payout);
        assertLe(payout, 500e18);
        _assertSolvent();
    }

    function test_partialCloseReleasesProRataMargin() public {
        _open(alice, 2e18, 1_000e18);
        uint256 before = vault.freeBalance(alice);

        vm.prank(alice);
        uint256 payout = market.closePosition(1e18);

        (int256 size, uint256 margin,,) = market.positions(alice);
        assertEq(size, 1e18);
        assertEq(margin, 500e18);
        assertEq(payout, 500e18 - 2e18);
        assertEq(vault.freeBalance(alice) - before, payout);
        assertEq(market.totalOpenInterest(), 1e18);
        _assertSolvent();
    }

    function test_profitIsCappedByTheInsuranceFund() public {
        // 100 ETH long. A move to $13,000 creates $1.1m of PnL, more than the seeded fund.
        _open(alice, 100e18, 20_000e18);
        _setPrices(13_000e18, 13_000e18);

        vm.prank(alice);
        uint256 payout = market.closePosition(100e18);

        (uint256 recorded, uint256 marginBefore, int256 pnl, bool active) = market.lastSettlement();
        assertTrue(active);
        assertEq(pnl, 1_100_000e18);
        assertEq(marginBefore, 20_000e18);
        // Insurance before the close was 1,000,100 (seed plus half of the $200 open fee).
        // Close fee is $1,300, and half of it returns to the fund after the profit is paid.
        assertEq(payout, 20_000e18 + 1_000_100e18 - 1_300e18);
        assertEq(recorded, payout);
        assertLe(payout, marginBefore + uint256(pnl));
        assertLt(payout, marginBefore + uint256(pnl));
        assertEq(vault.insuranceFund(), 650e18);
        _assertSolvent();
    }

    function test_matchedFundingIsZeroSum() public {
        _open(alice, 1e18, 500e18);
        _open(bob, -1e18, 500e18);
        _setPrices(2_000e18, 2_100e18);
        vm.warp(block.timestamp + 1 hours);

        uint256 insuranceBefore = vault.insuranceFund();
        market.settleFunding(alice);
        market.settleFunding(bob);

        assertEq(market.cumulativeFundingIndex(), 100e18);
        (, uint256 aliceMargin,,) = market.positions(alice);
        (, uint256 bobMargin,,) = market.positions(bob);
        assertEq(aliceMargin, 400e18);
        assertEq(bobMargin, 600e18);
        assertEq(vault.insuranceFund(), insuranceBefore);
        _assertSolvent();
    }

    function test_negativePremiumPaysTheLong() public {
        _open(alice, 1e18, 500e18);
        _setPrices(2_000e18, 1_900e18);
        vm.warp(block.timestamp + 1 hours);

        market.settleFunding(alice);

        assertEq(market.cumulativeFundingIndex(), -100e18);
        (, uint256 margin,,) = market.positions(alice);
        assertEq(margin, 600e18);
    }

    function test_addAndRemoveMargin() public {
        _open(alice, 1e18, 500e18);

        _openMoreMargin(alice, 50e18);
        (, uint256 margin,,) = market.positions(alice);
        assertEq(margin, 550e18);

        vm.prank(alice);
        market.removeMargin(350e18);
        (, margin,,) = market.positions(alice);
        assertEq(margin, 200e18);

        vm.prank(alice);
        vm.expectRevert(PerpMarket.LeverageExceeded.selector);
        market.removeMargin(1);
        _assertSolvent();
    }

    function test_liquidationPaysRewardFromRemainingEquity() public {
        _open(alice, 1e18, 200e18);

        // Healthy at the entry mark: equity 200, maintenance 100.
        vm.prank(liquidator);
        vm.expectRevert(PerpMarket.NotLiquidatable.selector);
        market.liquidate(alice);

        // At $1,850, PnL is -150 and equity is 50, below $92.50 maintenance.
        _setPrices(1_850e18, 1_850e18);
        uint256 insuranceBefore = vault.insuranceFund();
        uint256 liqBefore = vault.freeBalance(liquidator);

        vm.prank(liquidator);
        market.liquidate(alice);

        assertEq(vault.freeBalance(liquidator) - liqBefore, 2.5e18);
        assertEq(vault.insuranceFund(), insuranceBefore + 150e18);
        (int256 size, uint256 margin,,) = market.positions(alice);
        assertEq(size, 0);
        assertEq(margin, 0);
        assertEq(market.totalOpenInterest(), 0);

        (uint256 payout, uint256 marginBefore, int256 pnl, bool active) = market.lastSettlement();
        assertTrue(active);
        assertEq(pnl, -150e18);
        assertEq(marginBefore, 200e18);
        // Trader receives 47.5 of the 50 equity; liquidator receives 2.5. Sum is the equity.
        assertEq(payout, 50e18);
        assertLe(payout, marginBefore);
        _assertSolvent();
    }

    function test_gapCreatesBadDebtWithoutDrainingInsurance() public {
        _open(alice, 1e18, 200e18);
        _setPrices(1_600e18, 1_600e18);

        uint256 freeBefore = vault.freeBalance(alice);
        uint256 lockedBefore = vault.lockedBalance(alice);
        uint256 insuranceBefore = vault.insuranceFund();

        vm.prank(alice);
        market.liquidate(alice);

        // Tip is the 0.10% close-fee schedule on the $1,600 notional = $1.60,
        // and it cannot exceed the seized margin.
        assertEq(vault.freeBalance(alice) - freeBefore, 1.6e18);
        assertLt(vault.freeBalance(alice), freeBefore + lockedBefore);
        assertEq(vault.insuranceFund(), insuranceBefore + 200e18 - 1.6e18);
        assertEq(market.totalBadDebt(), 200e18);
        (uint256 payout, uint256 marginBefore, int256 pnl,) = market.lastSettlement();
        assertEq(pnl, -400e18);
        assertEq(marginBefore, 200e18);
        assertEq(payout, 1.6e18);
        assertLe(payout, marginBefore);
        _assertSolvent();
    }

    function test_pauseBlocksNewRiskAndAllowsClose() public {
        _open(alice, 1e18, 500e18);
        market.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        market.openPosition(1e18, 500e18);

        vm.prank(alice);
        market.closePosition(1e18);
        (int256 size,,,) = market.positions(alice);
        assertEq(size, 0);

        market.unpause();
        _open(alice, 1e18, 500e18);
    }

    function test_ownerControlsConfigOraclesAndOwnership() public {
        PerpMarket.MarketConfig memory cfg = _marketConfig();
        cfg.maintenanceMarginBps = 1_000;
        vm.expectRevert(PerpMarket.InvalidConfig.selector);
        market.setConfig(cfg);

        cfg.maintenanceMarginBps = 400;
        market.setConfig(cfg);
        assertEq(market.getConfig().maintenanceMarginBps, 400);

        vm.expectRevert(Ownable2Step.ZeroAddress.selector);
        market.setOracles(address(0), address(markOracle));

        market.transferOwnership(bob);
        vm.prank(alice);
        vm.expectRevert(Ownable2Step.NotPendingOwner.selector);
        market.acceptOwnership();
        vm.prank(bob);
        market.acceptOwnership();
        assertEq(market.owner(), bob);
    }

    function test_directTokenTransferIsExcessReserve() public {
        _assertSolvent();
        usdc.mint(address(this), 10e6);
        usdc.transfer(address(vault), 10e6);
        assertGt(usdc.balanceOf(address(vault)) * vault.scaleFactor(), vault.totalAccounted());
    }

    function test_onlyMarketMovesMargin() public {
        vm.expectRevert(CollateralVault.NotMarket.selector);
        vault.lock(alice, 1);
        vm.expectRevert(CollateralVault.MarketAlreadySet.selector);
        vault.setMarket(address(1));
    }

    function test_positionEquityMatchesMark() public view {
        // View path is checked after an open in the stateful tests; this guards the zero position.
        (int256 equity,,,, bool liquidatable) = market.positionEquity(alice);
        assertEq(equity, 0);
        assertFalse(liquidatable);
    }

    function test_equityViewTracksPnl() public {
        _open(alice, 1e18, 500e18);
        _setPrices(2_100e18, 2_100e18);
        (int256 equity, int256 pnl,, uint256 mark, bool liquidatable) = market.positionEquity(alice);
        assertEq(mark, 2_100e18);
        assertEq(pnl, 100e18);
        assertEq(equity, 600e18);
        assertFalse(liquidatable);
    }

    function _openMoreMargin(address user, uint256 amount) internal {
        vm.prank(user);
        market.addMargin(amount);
    }
}
