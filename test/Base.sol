// SPDX-License-Identifier: LicenseRef-SM-Source-Available-1.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockAggregator} from "../src/mocks/MockAggregator.sol";
import {OracleAdapter} from "../src/oracle/OracleAdapter.sol";
import {CollateralVault} from "../src/vault/CollateralVault.sol";
import {PerpMarket} from "../src/core/PerpMarket.sol";

/// @notice Shared 10x ETH-perp fixture. Prices are Chainlink-style 8-decimal answers.
contract BaseTest is Test {
    uint256 internal constant WAD = 1e18;

    MockERC20 internal usdc;
    MockAggregator internal indexFeed;
    MockAggregator internal markFeed;
    OracleAdapter internal indexOracle;
    OracleAdapter internal markOracle;
    CollateralVault internal vault;
    PerpMarket internal market;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal liquidator = makeAddr("liquidator");

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        indexFeed = new MockAggregator(8);
        markFeed = new MockAggregator(8);
        indexFeed.setPrice(2_000e8);
        markFeed.setPrice(2_000e8);

        // Deviation guard is off in the trading tests so a scenario can jump the mark.
        // OracleAdapter.t.sol covers the guard itself.
        indexOracle = new OracleAdapter(address(indexFeed), 1 days, 0, address(this));
        markOracle = new OracleAdapter(address(markFeed), 1 days, 0, address(this));
        vault = new CollateralVault(address(usdc), address(this));
        market =
            new PerpMarket(address(vault), address(indexOracle), address(markOracle), _marketConfig(), address(this));
        vault.setMarket(address(market));

        _donate(1_000_000e6);
        _fund(alice, 100_000e6);
        _fund(bob, 100_000e6);
        _fund(liquidator, 1_000e6);

        vm.label(alice, "alice");
        vm.label(bob, "bob");
        vm.label(liquidator, "liquidator");
    }

    function _marketConfig() internal pure returns (PerpMarket.MarketConfig memory cfg) {
        cfg.maxLeverage = 10e18;
        cfg.maintenanceMarginBps = 500;
        cfg.liquidationRewardBps = 500;
        cfg.tradingFeeBps = 10;
        cfg.insuranceSplitBps = 5_000;
        cfg.fundingPeriod = 1 hours;
        cfg.maxPremium = 0.05e18;
        cfg.minNotional = 10e18;
        cfg.maxOpenInterest = 1_000_000e18;
    }

    function _donate(uint256 tokenAmount) internal {
        usdc.mint(address(this), tokenAmount);
        usdc.approve(address(vault), type(uint256).max);
        vault.donateInsurance(tokenAmount);
    }

    function _fund(address user, uint256 tokenAmount) internal {
        usdc.mint(user, tokenAmount);
        vm.startPrank(user);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(tokenAmount);
        vm.stopPrank();
    }

    function _open(address user, int256 size, uint256 margin) internal {
        vm.prank(user);
        market.openPosition(size, margin);
    }

    /// @dev Truncates to the 8-decimal feed, matching what the adapter will scale back up.
    function _setPrices(uint256 indexWad, uint256 markWad) internal {
        indexFeed.setPrice(int256(indexWad / 1e10));
        markFeed.setPrice(int256(markWad / 1e10));
    }

    function _assertSolvent() internal view {
        assertEq(usdc.balanceOf(address(vault)) * vault.scaleFactor(), vault.totalAccounted(), "token backing");
        assertEq(
            vault.totalAccounted(),
            vault.sumFree() + vault.totalLocked() + vault.insuranceFund() + vault.protocolFees(),
            "ledger"
        );
    }
}
