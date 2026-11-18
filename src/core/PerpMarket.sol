// SPDX-License-Identifier: LicenseRef-SM-Source-Available-1.0
pragma solidity 0.8.28;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {CollateralVault} from "../vault/CollateralVault.sol";
import {PerpMath} from "../libraries/PerpMath.sol";
import {Ownable2Step} from "../access/Ownable2Step.sol";
import {ReentrancyGuard} from "../security/ReentrancyGuard.sol";
import {Pausable} from "../security/Pausable.sol";

/// @title Isolated-margin perpetual futures market.
/// @notice One base asset, quoted in the vault's 1e18 collateral units.
///
/// The insurance fund is the counterparty. Trader losses and a share of fees
/// accrue to it. Trader profits and funding receipts are paid from it and are
/// capped by its balance, so the vault never credits unbacked collateral.
///
/// Funding is premium-based. A keeper should call {accrueFunding} regularly:
/// the premium at accrual time is applied to the whole elapsed interval. It is
/// not a TWAP.
///
/// PnL of a position with signed size `s` and signed open notional `N`:
///
///     premium  = clamp((Pmark - Pindex) / Pindex, -pMax, pMax)
///     dF       = premium * Pindex * dt / fundingPeriod
///     payment  = s * (Fnow - Flast)          // positive => trader pays
///     pnl      = s * Pmark - N
///     equity   = margin - payment + pnl
///
/// A position is liquidatable when `equity < |s| * Pmark * maintenanceMargin`.
/// Closing never distributes more than post-funding margin plus positive PnL.
contract PerpMarket is Ownable2Step, ReentrancyGuard, Pausable {
    struct Position {
        int256 size; // base, 1e18. Positive long, negative short.
        uint256 margin; // locked quote, 1e18
        int256 openNotional; // signed quote, 1e18
        int256 fundingIndex; // cumulative index at last touch
    }

    struct MarketConfig {
        uint256 maxLeverage; // 1e18 = 1x. Initial margin ratio is 1 / maxLeverage.
        uint256 maintenanceMarginBps; // of notional. Must be below the initial margin ratio.
        uint256 liquidationRewardBps; // of remaining equity, paid to the liquidator.
        uint256 tradingFeeBps; // charged on open and close notional.
        uint256 insuranceSplitBps; // share of trading fees credited to insurance.
        uint256 fundingPeriod; // seconds over which the current premium is fully paid.
        uint256 maxPremium; // absolute premium clamp, 1e18 = 100%.
        uint256 minNotional; // minimum position notional, 1e18 quote.
        uint256 maxOpenInterest; // maximum sum of absolute position sizes, base 1e18.
    }

    /// @notice Receipt of the latest close or liquidation, for indexers and invariant checks.
    struct Settlement {
        uint256 payout; // collateral distributed to the trader and liquidator
        uint256 marginBefore; // margin slice after funding and before PnL
        int256 pnl; // theoretical mark PnL of the closed size (uncapped)
        bool active;
    }

    CollateralVault public immutable vault;
    IPriceOracle public indexOracle;
    IPriceOracle public markOracle;

    MarketConfig internal config;

    mapping(address => Position) public positions;

    int256 public cumulativeFundingIndex;
    uint256 public lastFundingTimestamp;
    int256 public netSize;
    uint256 public totalOpenInterest;
    uint256 public totalBadDebt;
    Settlement public lastSettlement;

    event PositionOpened(address indexed user, int256 sizeDelta, uint256 margin, uint256 price, uint256 fee);
    event PositionClosed(address indexed user, uint256 sizeClosed, int256 pnl, uint256 payout, uint256 fee);
    event MarginAdded(address indexed user, uint256 amount);
    event MarginRemoved(address indexed user, uint256 amount);
    event Liquidated(
        address indexed user,
        address indexed liquidator,
        int256 pnl,
        uint256 reward,
        uint256 traderPayout,
        uint256 badDebt
    );
    event FundingAccrued(int256 cumulativeFundingIndex, int256 premium, int256 delta, uint256 dt);
    event BadDebt(address indexed user, uint256 amount);
    event FundingCapped(address indexed user, uint256 unpaid);
    event ProfitCapped(address indexed user, uint256 unpaid);
    event OraclesUpdated(address indexOracle, address markOracle);
    event ConfigUpdated(
        uint256 maxLeverage,
        uint256 maintenanceMarginBps,
        uint256 liquidationRewardBps,
        uint256 tradingFeeBps,
        uint256 insuranceSplitBps,
        uint256 fundingPeriod,
        uint256 maxPremium,
        uint256 minNotional,
        uint256 maxOpenInterest
    );

    error ZeroAmount();
    error InvalidConfig();
    error NoPosition();
    error OppositeDirection();
    error LeverageExceeded();
    error InsufficientMargin();
    error InvalidCloseSize();
    error NotLiquidatable();
    error SizeTooLarge();
    error BelowMinNotional();
    error OpenInterestCap();
    error MarginDesync();

    constructor(address vault_, address indexOracle_, address markOracle_, MarketConfig memory cfg, address owner_)
        Ownable2Step(owner_)
    {
        if (vault_ == address(0) || indexOracle_ == address(0)) revert ZeroAddress();
        vault = CollateralVault(vault_);
        indexOracle = IPriceOracle(indexOracle_);
        markOracle = IPriceOracle(markOracle_);
        _validateConfig(cfg);
        config = cfg;
        lastFundingTimestamp = block.timestamp;
    }

    // ---------------------------------------------------------------------
    // Trading
    // ---------------------------------------------------------------------

    /// @notice Open or increase an isolated position.
    /// @param sizeDelta Signed base size. Positive opens/increases a long. Negative, a short.
    /// @param margin Additional margin to lock, in 1e18 vault units. Must cover initial margin.
    /// @dev Cannot flip direction in one call. Close first. Reverts while paused.
    function openPosition(int256 sizeDelta, uint256 margin) external nonReentrant whenNotPaused {
        if (sizeDelta == 0 || margin == 0) revert ZeroAmount();
        uint256 absDelta = PerpMath.abs(sizeDelta);
        if (absDelta > type(uint96).max) revert SizeTooLarge();

        uint256 mark = _accrueAndMark();
        uint256 addNotional = PerpMath.notional(absDelta, mark);
        if (addNotional < config.minNotional) revert BelowMinNotional();

        Position storage p = positions[msg.sender];
        if (p.size != 0) {
            if ((p.size > 0) != (sizeDelta > 0)) revert OppositeDirection();
            _settleFunding(msg.sender, p);
        }

        int256 newSize = p.size + sizeDelta;
        uint256 absNew = PerpMath.abs(newSize);
        if (absNew > type(uint96).max) revert SizeTooLarge();
        if (totalOpenInterest + absDelta > config.maxOpenInterest) revert OpenInterestCap();

        uint256 newNotional = PerpMath.notional(absNew, mark);
        uint256 newMargin = p.margin + margin;
        if (newMargin < _initialMargin(newNotional)) revert LeverageExceeded();

        uint256 fee = PerpMath.mulBpsUp(addNotional, config.tradingFeeBps);
        if (fee != 0) vault.takeFee(msg.sender, fee, config.insuranceSplitBps);
        vault.lock(msg.sender, margin);

        if (p.size == 0) p.fundingIndex = cumulativeFundingIndex;
        p.openNotional += sizeDelta * int256(mark) / int256(PerpMath.WAD);
        p.size = newSize;
        p.margin = newMargin;
        netSize += sizeDelta;
        totalOpenInterest += absDelta;

        _requireSync(msg.sender);
        emit PositionOpened(msg.sender, sizeDelta, margin, mark, fee);
    }

    /// @notice Close `sizeToClose` base units of the caller's position.
    /// @return payout Collateral credited to the caller after PnL and the close fee.
    function closePosition(uint256 sizeToClose) external nonReentrant returns (uint256 payout) {
        if (sizeToClose == 0) revert ZeroAmount();
        payout = _close(msg.sender, sizeToClose);
    }

    /// @notice Add margin to an open position.
    function addMargin(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        Position storage p = positions[msg.sender];
        if (p.size == 0) revert NoPosition();
        _accrueAndMark();
        _settleFunding(msg.sender, p);
        vault.lock(msg.sender, amount);
        p.margin += amount;
        _requireSync(msg.sender);
        emit MarginAdded(msg.sender, amount);
    }

    /// @notice Remove margin that is not required by initial margin.
    /// @dev Positive unrealized PnL is not treated as margin. Realize it by closing.
    function removeMargin(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Position storage p = positions[msg.sender];
        if (p.size == 0) revert NoPosition();
        uint256 mark = _accrueAndMark();
        _settleFunding(msg.sender, p);
        if (amount > p.margin) revert InsufficientMargin();

        uint256 newMargin = p.margin - amount;
        int256 pnl = _pnlAt(p, mark);
        int256 conservative = int256(newMargin) + (pnl < 0 ? pnl : int256(0));
        uint256 notion = PerpMath.notional(PerpMath.abs(p.size), mark);
        if (newMargin < _initialMargin(notion)) revert LeverageExceeded();
        if (conservative < int256(_maintenance(notion))) revert InsufficientMargin();

        p.margin = newMargin;
        vault.release(msg.sender, msg.sender, amount);
        _requireSync(msg.sender);
        emit MarginRemoved(msg.sender, amount);
    }

    /// @notice Liquidate `user` when equity is below maintenance margin.
    /// @dev Remaining equity pays the liquidator `liquidationRewardBps` and returns the rest
    ///      to the trader. If equity is zero, the insurance fund pays a tip capped by the
    ///      seized margin and by the close-fee schedule, so self-liquidation cannot drain it.
    function liquidate(address user) external nonReentrant {
        if (user == address(0)) revert ZeroAddress();
        Position storage p = positions[user];
        if (p.size == 0) revert NoPosition();

        uint256 mark = _accrueAndMark();
        _settleFunding(user, p);
        if (p.size == 0) revert NoPosition();

        int256 pnl = _pnlAt(p, mark);
        uint256 notion = PerpMath.notional(PerpMath.abs(p.size), mark);
        if (!_belowMaintenance(p.margin, pnl, notion)) revert NotLiquidatable();

        uint256 marginBefore = p.margin;
        int256 sizeBefore = p.size;
        uint256 absSize = PerpMath.abs(sizeBefore);

        p.size = 0;
        p.margin = 0;
        p.openNotional = 0;
        p.fundingIndex = 0;
        netSize -= sizeBefore;
        totalOpenInterest -= absSize;

        (uint256 equityOut, uint256 badDebt) = _realizePnl(user, marginBefore, pnl);

        uint256 reward;
        uint256 traderPayout = 0;
        if (equityOut == 0) {
            uint256 tip = PerpMath.mulBpsUp(notion, config.tradingFeeBps);
            if (tip > marginBefore) tip = marginBefore;
            reward = vault.payInsuranceToFree(msg.sender, tip);
        } else {
            reward = equityOut * config.liquidationRewardBps / PerpMath.BPS;
            traderPayout = equityOut - reward;
            if (traderPayout != 0) vault.release(user, user, traderPayout);
            if (reward != 0) vault.release(user, msg.sender, reward);
        }

        _record(traderPayout + reward, marginBefore, pnl);
        _requireSync(user);
        emit Liquidated(user, msg.sender, pnl, reward, traderPayout, badDebt);
    }

    /// @notice Accrue the premium funding index and refresh oracle anchors.
    function accrueFunding() external nonReentrant {
        _accrueAndMark();
    }

    /// @notice Settle funding for `user` without changing size.
    function settleFunding(address user) external nonReentrant {
        Position storage p = positions[user];
        if (p.size == 0) revert NoPosition();
        _accrueAndMark();
        _settleFunding(user, p);
        _requireSync(user);
    }

    /// @notice Refresh oracle deviation anchors and accrue funding.
    function syncOracles() external nonReentrant {
        _accrueAndMark();
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Theoretical equity. Insurance caps are applied only when the position is touched.
    /// @return equity Margin after theoretical funding, plus theoretical PnL.
    /// @return pnl Mark PnL before funding.
    /// @return fundingPayment Positive when the trader owes funding.
    /// @return markPrice Mark price used.
    /// @return liquidatable True when theoretical equity is strictly below maintenance.
    function positionEquity(address user)
        external
        view
        returns (int256 equity, int256 pnl, int256 fundingPayment, uint256 markPrice, bool liquidatable)
    {
        Position memory p = positions[user];
        if (p.size == 0) return (0, 0, 0, 0, false);

        uint256 indexPrice;
        (indexPrice, markPrice) = _peekPrices();
        int256 indexNow = cumulativeFundingIndex;
        if (block.timestamp > lastFundingTimestamp) {
            int256 premium = _premium(indexPrice, markPrice);
            indexNow += _fundingDelta(premium, indexPrice, block.timestamp - lastFundingTimestamp);
        }
        fundingPayment = p.size * (indexNow - p.fundingIndex) / int256(PerpMath.WAD);
        pnl = p.size * int256(markPrice) / int256(PerpMath.WAD) - p.openNotional;
        equity = int256(p.margin) - fundingPayment + pnl;
        uint256 notion = PerpMath.notional(PerpMath.abs(p.size), markPrice);
        liquidatable = equity < int256(_maintenance(notion));
    }

    /// @notice Current index and mark, or mark = index when no mark oracle is set.
    function previewPrices() external view returns (uint256 indexPrice, uint256 markPrice) {
        return _peekPrices();
    }

    /// @notice Market risk parameters.
    function getConfig() external view returns (MarketConfig memory) {
        return config;
    }

    /// @notice Convert a raw token amount into the vault's 1e18 internal units.
    function tokenToInternal(uint256 tokenAmount) external view returns (uint256) {
        return tokenAmount * vault.scaleFactor();
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    function setConfig(MarketConfig calldata cfg) external onlyOwner {
        _validateConfig(cfg);
        config = cfg;
        emit ConfigUpdated(
            cfg.maxLeverage,
            cfg.maintenanceMarginBps,
            cfg.liquidationRewardBps,
            cfg.tradingFeeBps,
            cfg.insuranceSplitBps,
            cfg.fundingPeriod,
            cfg.maxPremium,
            cfg.minNotional,
            cfg.maxOpenInterest
        );
    }

    /// @param markOracle_ Pass the zero address to use the index price as the mark (premium stays zero
    ///        until a mark oracle is set, aside from the index itself).
    function setOracles(address indexOracle_, address markOracle_) external onlyOwner {
        if (indexOracle_ == address(0)) revert ZeroAddress();
        indexOracle = IPriceOracle(indexOracle_);
        markOracle = IPriceOracle(markOracle_);
        emit OraclesUpdated(indexOracle_, markOracle_);
    }

    /// @notice Block new risk. Closes, withdrawals, and liquidations stay available.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _close(address user, uint256 sizeToClose) internal returns (uint256 payout) {
        Position storage p = positions[user];
        if (p.size == 0) revert NoPosition();

        uint256 mark = _accrueAndMark();
        _settleFunding(user, p);

        uint256 absSize = PerpMath.abs(p.size);
        if (sizeToClose > absSize) revert InvalidCloseSize();

        int256 pnlFull = _pnlAt(p, mark);
        int256 pnl = pnlFull * int256(sizeToClose) / int256(absSize);
        uint256 marginPart = p.margin * sizeToClose / absSize;
        int256 signedClose = p.size > 0 ? int256(sizeToClose) : -int256(sizeToClose);

        p.size -= signedClose;
        p.openNotional -= p.openNotional * int256(sizeToClose) / int256(absSize);
        p.margin -= marginPart;
        netSize -= signedClose;
        totalOpenInterest -= sizeToClose;

        (uint256 equityOut,) = _realizePnl(user, marginPart, pnl);

        if (p.size == 0) {
            p.openNotional = 0;
            p.fundingIndex = 0;
        } else {
            uint256 remNotional = PerpMath.notional(PerpMath.abs(p.size), mark);
            if (remNotional < config.minNotional) revert BelowMinNotional();
            if (p.margin < _initialMargin(remNotional)) revert LeverageExceeded();
        }

        if (equityOut != 0) vault.release(user, user, equityOut);

        uint256 fee = PerpMath.mulBpsUp(PerpMath.notional(sizeToClose, mark), config.tradingFeeBps);
        uint256 feeTaken = 0;
        if (fee != 0 && equityOut != 0) {
            feeTaken = fee <= equityOut ? fee : equityOut;
            uint256 freeBal = vault.freeBalance(user);
            if (feeTaken > freeBal) feeTaken = freeBal;
            if (feeTaken != 0) vault.takeFee(user, feeTaken, config.insuranceSplitBps);
        }

        payout = equityOut - feeTaken;
        _record(payout, marginPart, pnl);
        _requireSync(user);
        emit PositionClosed(user, sizeToClose, pnl, payout, feeTaken);
    }

    /// @dev Apply `pnl` to a still-locked `marginPart`. Does not release collateral.
    function _realizePnl(address user, uint256 marginPart, int256 pnl)
        internal
        returns (uint256 equityOut, uint256 badDebt)
    {
        if (pnl > 0) {
            uint256 wanted = uint256(pnl);
            uint256 paid = vault.insuranceToLocked(user, wanted);
            if (paid < wanted) emit ProfitCapped(user, wanted - paid);
            equityOut = marginPart + paid;
        } else if (pnl < 0) {
            uint256 loss = uint256(-pnl);
            uint256 taken = loss > marginPart ? marginPart : loss;
            if (taken != 0) vault.lockedToInsurance(user, taken);
            if (loss > taken) {
                badDebt = loss - taken;
                totalBadDebt += badDebt;
                emit BadDebt(user, badDebt);
            }
            equityOut = marginPart - taken;
        } else {
            equityOut = marginPart;
        }
    }

    function _settleFunding(address user, Position storage p) internal {
        if (p.size == 0) return;
        int256 payment = p.size * (cumulativeFundingIndex - p.fundingIndex) / int256(PerpMath.WAD);
        p.fundingIndex = cumulativeFundingIndex;
        if (payment > 0) {
            uint256 pay = uint256(payment);
            if (pay >= p.margin) {
                uint256 covered = p.margin;
                if (covered != 0) {
                    vault.lockedToInsurance(user, covered);
                    p.margin = 0;
                }
                uint256 unpaid = pay - covered;
                if (unpaid != 0) {
                    totalBadDebt += unpaid;
                    emit BadDebt(user, unpaid);
                }
            } else {
                p.margin -= pay;
                vault.lockedToInsurance(user, pay);
            }
        } else if (payment < 0) {
            uint256 recv = uint256(-payment);
            uint256 paid = vault.insuranceToLocked(user, recv);
            p.margin += paid;
            if (paid < recv) emit FundingCapped(user, recv - paid);
        }
    }

    function _accrueAndMark() internal returns (uint256 markPrice) {
        uint256 indexPrice;
        (indexPrice, markPrice) = _readPrices();
        uint256 ts = block.timestamp;
        if (ts <= lastFundingTimestamp) return markPrice;

        uint256 dt = ts - lastFundingTimestamp;
        int256 premium = _premium(indexPrice, markPrice);
        int256 delta = _fundingDelta(premium, indexPrice, dt);
        cumulativeFundingIndex += delta;
        lastFundingTimestamp = ts;
        emit FundingAccrued(cumulativeFundingIndex, premium, delta, dt);
    }

    function _readPrices() internal returns (uint256 indexPrice, uint256 markPrice) {
        indexPrice = indexOracle.getPrice();
        if (address(markOracle) == address(0)) {
            markPrice = indexPrice;
        } else {
            markPrice = markOracle.getPrice();
        }
    }

    function _peekPrices() internal view returns (uint256 indexPrice, uint256 markPrice) {
        (indexPrice,) = indexOracle.peek();
        if (address(markOracle) == address(0)) {
            markPrice = indexPrice;
        } else {
            (markPrice,) = markOracle.peek();
        }
    }

    function _premium(uint256 indexPrice, uint256 markPrice) internal view returns (int256 premium) {
        premium = (int256(markPrice) - int256(indexPrice)) * int256(PerpMath.WAD) / int256(indexPrice);
        int256 cap = int256(config.maxPremium);
        if (premium > cap) return cap;
        if (premium < -cap) return -cap;
    }

    function _fundingDelta(int256 premium, uint256 indexPrice, uint256 dt) internal view returns (int256) {
        // Divide once, at the end: premium * index * dt / (WAD * fundingPeriod).
        int256 product = premium * int256(indexPrice) * int256(dt);
        return product / (int256(PerpMath.WAD) * int256(config.fundingPeriod));
    }

    function _pnlAt(Position storage p, uint256 markPrice) internal view returns (int256) {
        return p.size * int256(markPrice) / int256(PerpMath.WAD) - p.openNotional;
    }

    function _initialMargin(uint256 notion) internal view returns (uint256) {
        return PerpMath.mulDivUp(notion, PerpMath.WAD, config.maxLeverage);
    }

    function _maintenance(uint256 notion) internal view returns (uint256) {
        return PerpMath.mulBpsUp(notion, config.maintenanceMarginBps);
    }

    /// @dev Positive PnL only counts to the extent the insurance fund can pay it.
    function _belowMaintenance(uint256 margin, int256 pnl, uint256 notion) internal view returns (bool) {
        int256 counted = pnl;
        if (pnl > 0) {
            uint256 ins = vault.insuranceFund();
            if (uint256(pnl) > ins) counted = int256(ins);
        }
        return int256(margin) + counted < int256(_maintenance(notion));
    }

    function _record(uint256 payout, uint256 marginBefore, int256 pnl) internal {
        lastSettlement = Settlement({payout: payout, marginBefore: marginBefore, pnl: pnl, active: true});
    }

    function _requireSync(address user) internal view {
        if (vault.lockedBalance(user) != positions[user].margin) revert MarginDesync();
    }

    function _validateConfig(MarketConfig memory cfg) internal pure {
        if (cfg.maxLeverage < PerpMath.WAD || cfg.maxLeverage > 100 * PerpMath.WAD) revert InvalidConfig();
        uint256 initialBps = PerpMath.BPS * PerpMath.WAD / cfg.maxLeverage;
        if (cfg.maintenanceMarginBps == 0 || cfg.maintenanceMarginBps >= initialBps) revert InvalidConfig();
        if (cfg.liquidationRewardBps > 2_000) revert InvalidConfig();
        if (cfg.tradingFeeBps > 100) revert InvalidConfig();
        if (cfg.insuranceSplitBps > PerpMath.BPS) revert InvalidConfig();
        if (cfg.fundingPeriod < 60 || cfg.fundingPeriod > 30 days) revert InvalidConfig();
        if (cfg.maxPremium == 0 || cfg.maxPremium > PerpMath.WAD / 2) revert InvalidConfig();
        if (cfg.minNotional == 0 || cfg.maxOpenInterest == 0) revert InvalidConfig();
    }
}
