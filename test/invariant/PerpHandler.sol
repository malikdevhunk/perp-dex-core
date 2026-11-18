// SPDX-License-Identifier: LicenseRef-SM-Source-Available-1.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockAggregator} from "../../src/mocks/MockAggregator.sol";
import {CollateralVault} from "../../src/vault/CollateralVault.sol";
import {PerpMarket} from "../../src/core/PerpMarket.sol";

/// @notice Bounded actor for the invariant suite.
///         Expected business reverts are ignored. Anything else, including a
///         payout above margin plus positive PnL, increments a counter the
///         invariant test asserts is zero.
contract PerpHandler is Test {
    MockERC20 public immutable usdc;
    MockAggregator public immutable indexFeed;
    MockAggregator public immutable markFeed;
    CollateralVault public immutable vault;
    PerpMarket public immutable market;

    address[] internal _actors;
    uint256 public violations;
    uint256 public unexpectedReverts;
    bytes4 public lastUnexpected;
    uint8 public lastAction;

    constructor(
        MockERC20 usdc_,
        MockAggregator indexFeed_,
        MockAggregator markFeed_,
        CollateralVault vault_,
        PerpMarket market_
    ) {
        usdc = usdc_;
        indexFeed = indexFeed_;
        markFeed = markFeed_;
        vault = vault_;
        market = market_;
        _actors.push(makeAddr("handler-alice"));
        _actors.push(makeAddr("handler-bob"));
        _actors.push(makeAddr("handler-carol"));
    }

    function actorCount() external view returns (uint256) {
        return _actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return _actors[i];
    }

    function deposit(uint256 actorSeed, uint256 amount) external {
        lastAction = 1;
        address actor = _actor(actorSeed);
        uint256 tokens = bound(amount, 1e6, 50_000e6);
        usdc.mint(actor, tokens);
        vm.startPrank(actor);
        usdc.approve(address(vault), type(uint256).max);
        try vault.deposit(tokens) {}
        catch (bytes memory err) {
            _unexpected(err);
        }
        vm.stopPrank();
    }

    function withdraw(uint256 actorSeed, uint256 amount) external {
        lastAction = 2;
        address actor = _actor(actorSeed);
        uint256 maxTokens = vault.freeBalance(actor) / 1e12;
        if (maxTokens == 0) return;
        uint256 tokens = bound(amount, 1, maxTokens);
        vm.prank(actor);
        try vault.withdraw(tokens) {}
        catch (bytes memory err) {
            _unexpected(err);
        }
    }

    function donate(uint256 amount) external {
        lastAction = 3;
        uint256 tokens = bound(amount, 1e6, 20_000e6);
        usdc.mint(address(this), tokens);
        usdc.approve(address(vault), type(uint256).max);
        try vault.donateInsurance(tokens) {}
        catch (bytes memory err) {
            _unexpected(err);
        }
    }

    function openLong(uint256 actorSeed, uint256 sizeSeed, uint256 marginSeed) external {
        _open(actorSeed, sizeSeed, marginSeed, true);
    }

    function openShort(uint256 actorSeed, uint256 sizeSeed, uint256 marginSeed) external {
        _open(actorSeed, sizeSeed, marginSeed, false);
    }

    function closeSome(uint256 actorSeed, uint256 frac) external {
        lastAction = 6;
        address actor = _actor(actorSeed);
        (int256 size,,,) = market.positions(actor);
        if (size == 0) return;
        uint256 absSize = size > 0 ? uint256(size) : uint256(-size);
        uint256 bps = bound(frac, 1, 10_000);
        uint256 sizeToClose = absSize * bps / 10_000;
        if (sizeToClose == 0 || bps >= 6_000) sizeToClose = absSize;

        uint256 before = vault.freeBalance(actor);
        vm.prank(actor);
        try market.closePosition(sizeToClose) {
            _checkPayout(actor, before, address(0), 0);
        } catch (bytes memory err) {
            if (!_expected(err)) _unexpected(err);
        }
    }

    function addMargin(uint256 actorSeed, uint256 amount) external {
        lastAction = 7;
        address actor = _actor(actorSeed);
        (int256 size,,,) = market.positions(actor);
        if (size == 0) return;
        uint256 tokens = bound(amount, 1e6, 5_000e6);
        usdc.mint(actor, tokens);
        vm.startPrank(actor);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(tokens);
        try market.addMargin(tokens * 1e12) {}
        catch (bytes memory err) {
            _unexpected(err);
        }
        vm.stopPrank();
    }

    function removeMargin(uint256 actorSeed, uint256 amount) external {
        lastAction = 8;
        address actor = _actor(actorSeed);
        (, uint256 margin,,) = market.positions(actor);
        if (margin < 2) return;
        uint256 removeAmount = bound(amount, 1, margin / 2);
        vm.prank(actor);
        try market.removeMargin(removeAmount) {}
        catch (bytes memory err) {
            if (!_expected(err)) _unexpected(err);
        }
    }

    function liquidate(uint256 userSeed, uint256 liqSeed) external {
        lastAction = 9;
        address user = _actor(userSeed);
        address liq = _actor(liqSeed);
        (int256 size,,,) = market.positions(user);
        if (size == 0) return;

        uint256 userBefore = vault.freeBalance(user);
        uint256 liqBefore = vault.freeBalance(liq);
        vm.prank(liq);
        try market.liquidate(user) {
            _checkPayout(user, userBefore, liq, liqBefore);
        } catch (bytes memory err) {
            if (!_expected(err)) _unexpected(err);
        }
    }

    function settle(uint256 actorSeed) external {
        lastAction = 10;
        address actor = _actor(actorSeed);
        (int256 size,,,) = market.positions(actor);
        if (size == 0) return;
        vm.prank(actor);
        try market.settleFunding(actor) {}
        catch (bytes memory err) {
            _unexpected(err);
        }
    }

    function warpTime(uint256 secs) external {
        lastAction = 11;
        uint256 dt = bound(secs, 30, 2 hours);
        vm.warp(block.timestamp + dt);
        indexFeed.poke();
        markFeed.poke();
    }

    function moveIndex(uint256 raw) external {
        lastAction = 12;
        uint256 current = uint256(indexFeed.answer());
        uint256 next = bound(raw, current * 95 / 100, current * 105 / 100);
        if (next < 800e8) next = 800e8;
        if (next > 6_000e8) next = 6_000e8;
        indexFeed.setPrice(int256(next));
        uint256 markPx = uint256(markFeed.answer());
        if (markPx < next * 92 / 100 || markPx > next * 108 / 100) {
            markFeed.setPrice(int256(next));
        }
    }

    function moveMark(uint256 raw) external {
        lastAction = 13;
        uint256 indexPx = uint256(indexFeed.answer());
        uint256 lo = indexPx * 92 / 100;
        uint256 hi = indexPx * 108 / 100;
        if (lo == 0) lo = 1;
        markFeed.setPrice(int256(bound(raw, lo, hi)));
    }

    function _open(uint256 actorSeed, uint256 sizeSeed, uint256 marginSeed, bool isLong) internal {
        lastAction = isLong ? 4 : 5;
        address actor = _actor(actorSeed);
        (int256 existing,,,) = market.positions(actor);
        if (existing != 0) return;

        uint256 price = uint256(markFeed.answer()) * 1e10;
        uint256 size = bound(sizeSeed, 0.05e18, 2e18);
        uint256 notion = size * price / 1e18;
        PerpMarket.MarketConfig memory cfg = market.getConfig();
        if (notion < cfg.minNotional) return;
        if (market.totalOpenInterest() + size > cfg.maxOpenInterest) return;

        uint256 minMargin = (notion * 1e18 + cfg.maxLeverage - 1) / cfg.maxLeverage;
        uint256 margin = minMargin + bound(marginSeed, 1e18, minMargin + 1e18);
        uint256 fee = (notion * cfg.tradingFeeBps + 9_999) / 10_000;
        uint256 tokens = (margin + fee) / 1e12 + 3;

        usdc.mint(actor, tokens);
        vm.startPrank(actor);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(tokens);
        int256 sizeDelta = isLong ? int256(size) : -int256(size);
        try market.openPosition(sizeDelta, margin) {}
        catch (bytes memory err) {
            _unexpected(err);
        }
        vm.stopPrank();
    }

    function _checkPayout(address user, uint256 userBefore, address liq, uint256 liqBefore) internal {
        (uint256 payout, uint256 marginBefore, int256 pnl, bool active) = market.lastSettlement();
        if (!active) {
            violations++;
            return;
        }
        uint256 cap = marginBefore;
        if (pnl > 0) cap += uint256(pnl);

        uint256 userAfter = vault.freeBalance(user);
        uint256 received;
        if (liq == address(0) || liq == user) {
            if (userAfter < userBefore) {
                violations++;
                return;
            }
            received = userAfter - userBefore;
        } else {
            uint256 liqAfter = vault.freeBalance(liq);
            if (userAfter < userBefore || liqAfter < liqBefore) {
                violations++;
                return;
            }
            received = (userAfter - userBefore) + (liqAfter - liqBefore);
        }
        if (received != payout || payout > cap) violations++;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return _actors[seed % _actors.length];
    }

    function _unexpected(bytes memory err) internal {
        unexpectedReverts++;
        if (err.length >= 4) {
            bytes4 sel;
            assembly {
                sel := mload(add(err, 32))
            }
            lastUnexpected = sel;
        }
    }

    function _expected(bytes memory err) internal pure returns (bool) {
        if (err.length < 4) return false;
        bytes4 sel;
        assembly {
            sel := mload(add(err, 32))
        }
        return sel == PerpMarket.LeverageExceeded.selector || sel == PerpMarket.NotLiquidatable.selector
            || sel == PerpMarket.NoPosition.selector || sel == PerpMarket.OppositeDirection.selector
            || sel == PerpMarket.OpenInterestCap.selector || sel == PerpMarket.BelowMinNotional.selector
            || sel == PerpMarket.InsufficientMargin.selector || sel == PerpMarket.InvalidCloseSize.selector
            || sel == PerpMarket.ZeroAmount.selector || sel == CollateralVault.InsufficientBalance.selector
            || sel == CollateralVault.ZeroAmount.selector;
    }
}
