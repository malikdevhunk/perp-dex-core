// SPDX-License-Identifier: LicenseRef-SM-Source-Available-1.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockAggregator} from "../../src/mocks/MockAggregator.sol";
import {OracleAdapter} from "../../src/oracle/OracleAdapter.sol";
import {CollateralVault} from "../../src/vault/CollateralVault.sol";
import {PerpMarket} from "../../src/core/PerpMarket.sol";
import {PerpHandler} from "./PerpHandler.sol";

/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 30
/// forge-config: default.invariant.fail_on_revert = false
contract PerpInvariantTest is Test {
    MockERC20 internal usdc;
    MockAggregator internal indexFeed;
    MockAggregator internal markFeed;
    CollateralVault internal vault;
    PerpMarket internal market;
    PerpHandler internal handler;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        indexFeed = new MockAggregator(8);
        markFeed = new MockAggregator(8);
        indexFeed.setPrice(2_000e8);
        markFeed.setPrice(2_000e8);

        OracleAdapter indexOracle = new OracleAdapter(address(indexFeed), 365 days, 0, address(this));
        OracleAdapter markOracle = new OracleAdapter(address(markFeed), 365 days, 0, address(this));
        vault = new CollateralVault(address(usdc), address(this));
        market = new PerpMarket(
            address(vault),
            address(indexOracle),
            address(markOracle),
            PerpMarket.MarketConfig({
                maxLeverage: 10e18,
                maintenanceMarginBps: 500,
                liquidationRewardBps: 500,
                tradingFeeBps: 10,
                insuranceSplitBps: 5_000,
                fundingPeriod: 1 hours,
                maxPremium: 0.05e18,
                minNotional: 10e18,
                maxOpenInterest: 1_000e18
            }),
            address(this)
        );
        vault.setMarket(address(market));

        usdc.mint(address(this), 5_000_000e6);
        usdc.approve(address(vault), type(uint256).max);
        vault.donateInsurance(5_000_000e6);

        handler = new PerpHandler(usdc, indexFeed, markFeed, vault, market);

        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.withdraw.selector;
        selectors[2] = handler.donate.selector;
        selectors[3] = handler.openLong.selector;
        selectors[4] = handler.openShort.selector;
        selectors[5] = handler.closeSome.selector;
        selectors[6] = handler.addMargin.selector;
        selectors[7] = handler.removeMargin.selector;
        selectors[8] = handler.liquidate.selector;
        selectors[9] = handler.settle.selector;
        selectors[10] = handler.warpTime.selector;
        selectors[11] = handler.moveIndex.selector;
        selectors[12] = handler.moveMark.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice Token balance covers the ledger, and the ledger partitions exactly.
    function invariant_vaultSolvency() public view {
        assertEq(usdc.balanceOf(address(vault)) * vault.scaleFactor(), vault.totalAccounted());
        assertEq(
            vault.totalAccounted(), vault.sumFree() + vault.totalLocked() + vault.insuranceFund() + vault.protocolFees()
        );
    }

    /// @notice Locked collateral matches position margin, and open interest matches net size.
    function invariant_positionsMatchVault() public view {
        uint256 n = handler.actorCount();
        int256 net;
        uint256 oi;
        for (uint256 i; i < n; ++i) {
            address actor = handler.actorAt(i);
            (int256 size, uint256 margin,,) = market.positions(actor);
            assertEq(vault.lockedBalance(actor), margin);
            if (size == 0) {
                assertEq(margin, 0);
            } else {
                oi += size > 0 ? uint256(size) : uint256(-size);
            }
            net += size;
        }
        assertEq(net, market.netSize());
        assertEq(oi, market.totalOpenInterest());
    }

    /// @notice No close or liquidation distributed more than margin plus positive PnL.
    function invariant_closePayoutBounded() public view {
        (uint256 payout, uint256 marginBefore, int256 pnl, bool active) = market.lastSettlement();
        if (active) {
            uint256 cap = marginBefore;
            if (pnl > 0) cap += uint256(pnl);
            assertLe(payout, cap);
        }
        assertEq(handler.violations(), 0);
        assertEq(handler.unexpectedReverts(), 0);
    }
}
