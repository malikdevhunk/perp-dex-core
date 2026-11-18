// SPDX-License-Identifier: LicenseRef-SM-Source-Available-1.0
pragma solidity 0.8.28;

import {IERC20Minimal} from "../interfaces/IERC20Minimal.sol";
import {Ownable2Step} from "../access/Ownable2Step.sol";
import {ReentrancyGuard} from "../security/ReentrancyGuard.sol";

/// @title Collateral vault for isolated-margin perps.
/// @notice Holds an ERC-20 (USDC-style, decimals <= 18) and normalizes balances to 1e18.
///         Free collateral, locked margin, the insurance fund, and protocol fees are
///         one ledger. The linked market is the only caller that can move margin.
/// @dev `token.balanceOf(this) * scaleFactor >= totalAccounted` is the solvency identity.
///      Direct token donations increase the token balance without being credited.
contract CollateralVault is Ownable2Step, ReentrancyGuard {
    IERC20Minimal public immutable collateral;
    uint8 public immutable collateralDecimals;
    /// @notice 10^(18 - token decimals). Internal amounts are token amounts times this.
    uint256 public immutable scaleFactor;

    address public market;

    mapping(address => uint256) public freeBalance;
    mapping(address => uint256) public lockedBalance;

    uint256 public sumFree;
    uint256 public totalLocked;
    uint256 public insuranceFund;
    uint256 public protocolFees;
    uint256 public totalAccounted;

    event MarketSet(address indexed market);
    event Deposited(address indexed user, uint256 tokenAmount, uint256 internalAmount);
    event Withdrawn(address indexed user, uint256 tokenAmount, uint256 internalAmount);
    event InsuranceDonated(address indexed from, uint256 internalAmount);
    event ProtocolFeesWithdrawn(address indexed to, uint256 tokenAmount);
    event MarginLocked(address indexed user, uint256 amount);
    event MarginReleased(address indexed from, address indexed to, uint256 amount);
    event InsuranceCredited(uint256 amount);
    event InsuranceDebited(uint256 amount);
    event FeeTaken(address indexed user, uint256 toInsurance, uint256 toProtocol);

    error NotMarket();
    error MarketAlreadySet();
    error ZeroAmount();
    error InsufficientBalance();
    error DecimalsTooHigh();
    error TransferFailed();

    modifier onlyMarket() {
        if (msg.sender != market) revert NotMarket();
        _;
    }

    constructor(address collateral_, address owner_) Ownable2Step(owner_) {
        if (collateral_ == address(0)) revert ZeroAddress();
        collateral = IERC20Minimal(collateral_);
        uint8 decimals_ = collateral.decimals();
        if (decimals_ > 18) revert DecimalsTooHigh();
        collateralDecimals = decimals_;
        scaleFactor = 10 ** (18 - decimals_);
    }

    /// @notice Bind the market. One-shot.
    function setMarket(address market_) external onlyOwner {
        if (market != address(0)) revert MarketAlreadySet();
        if (market_ == address(0)) revert ZeroAddress();
        market = market_;
        emit MarketSet(market_);
    }

    /// @notice Pull `tokenAmount` of collateral from the caller and credit their free balance.
    function deposit(uint256 tokenAmount) external nonReentrant {
        _deposit(msg.sender, tokenAmount);
    }

    /// @notice Pull collateral from the caller and credit `user`.
    function depositFor(address user, uint256 tokenAmount) external nonReentrant {
        if (user == address(0)) revert ZeroAddress();
        _deposit(user, tokenAmount);
    }

    /// @notice Withdraw free collateral. Locked margin cannot be withdrawn here.
    function withdraw(uint256 tokenAmount) external nonReentrant {
        if (tokenAmount == 0) revert ZeroAmount();
        uint256 internalAmount = tokenAmount * scaleFactor;
        uint256 balance = freeBalance[msg.sender];
        if (balance < internalAmount) revert InsufficientBalance();
        freeBalance[msg.sender] = balance - internalAmount;
        sumFree -= internalAmount;
        totalAccounted -= internalAmount;
        emit Withdrawn(msg.sender, tokenAmount, internalAmount);
        _push(msg.sender, tokenAmount);
    }

    /// @notice Add tokens directly to the insurance fund (the PnL counterparty).
    function donateInsurance(uint256 tokenAmount) external nonReentrant {
        if (tokenAmount == 0) revert ZeroAmount();
        uint256 internalAmount = tokenAmount * scaleFactor;
        _pull(msg.sender, tokenAmount);
        insuranceFund += internalAmount;
        totalAccounted += internalAmount;
        emit InsuranceDonated(msg.sender, internalAmount);
    }

    /// @notice Owner withdrawal of protocol trading fees.
    function withdrawProtocolFees(address to, uint256 tokenAmount) external nonReentrant onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (tokenAmount == 0) revert ZeroAmount();
        uint256 internalAmount = tokenAmount * scaleFactor;
        if (protocolFees < internalAmount) revert InsufficientBalance();
        protocolFees -= internalAmount;
        totalAccounted -= internalAmount;
        emit ProtocolFeesWithdrawn(to, tokenAmount);
        _push(to, tokenAmount);
    }

    /// @notice Move free collateral into locked margin.
    function lock(address user, uint256 amount) external onlyMarket {
        if (amount == 0) revert ZeroAmount();
        uint256 balance = freeBalance[user];
        if (balance < amount) revert InsufficientBalance();
        freeBalance[user] = balance - amount;
        sumFree -= amount;
        lockedBalance[user] += amount;
        totalLocked += amount;
        emit MarginLocked(user, amount);
    }

    /// @notice Move locked margin from `from` to the free balance of `to`.
    function release(address from, address to, uint256 amount) external onlyMarket {
        if (amount == 0) return;
        uint256 locked = lockedBalance[from];
        if (locked < amount) revert InsufficientBalance();
        lockedBalance[from] = locked - amount;
        totalLocked -= amount;
        freeBalance[to] += amount;
        sumFree += amount;
        emit MarginReleased(from, to, amount);
    }

    /// @notice Pay realized losses from locked margin into the insurance fund.
    function lockedToInsurance(address user, uint256 amount) external onlyMarket {
        if (amount == 0) return;
        uint256 locked = lockedBalance[user];
        if (locked < amount) revert InsufficientBalance();
        lockedBalance[user] = locked - amount;
        totalLocked -= amount;
        insuranceFund += amount;
        emit InsuranceCredited(amount);
    }

    /// @notice Pay realized profits from the insurance fund into locked margin.
    /// @return paid Amount credited. Capped by the insurance balance.
    function insuranceToLocked(address user, uint256 amount) external onlyMarket returns (uint256 paid) {
        if (amount == 0) return 0;
        paid = amount > insuranceFund ? insuranceFund : amount;
        insuranceFund -= paid;
        lockedBalance[user] += paid;
        totalLocked += paid;
        emit InsuranceDebited(paid);
    }

    /// @notice Pay a liquidator tip from the insurance fund into a free balance.
    /// @return paid Amount credited. Capped by the insurance balance.
    function payInsuranceToFree(address to, uint256 amount) external onlyMarket returns (uint256 paid) {
        if (amount == 0) return 0;
        paid = amount > insuranceFund ? insuranceFund : amount;
        insuranceFund -= paid;
        freeBalance[to] += paid;
        sumFree += paid;
        emit InsuranceDebited(paid);
    }

    /// @notice Take a trading fee from free collateral and split it.
    /// @param insuranceSplitBps Share of the fee (in bps) credited to the insurance fund. The rest is protocol fees.
    function takeFee(address user, uint256 amount, uint256 insuranceSplitBps) external onlyMarket {
        if (amount == 0) return;
        uint256 balance = freeBalance[user];
        if (balance < amount) revert InsufficientBalance();
        freeBalance[user] = balance - amount;
        sumFree -= amount;
        uint256 toInsurance = amount * insuranceSplitBps / 10_000;
        uint256 toProtocol = amount - toInsurance;
        insuranceFund += toInsurance;
        protocolFees += toProtocol;
        emit FeeTaken(user, toInsurance, toProtocol);
    }

    function _deposit(address user, uint256 tokenAmount) internal {
        if (tokenAmount == 0) revert ZeroAmount();
        uint256 internalAmount = tokenAmount * scaleFactor;
        _pull(msg.sender, tokenAmount);
        freeBalance[user] += internalAmount;
        sumFree += internalAmount;
        totalAccounted += internalAmount;
        emit Deposited(user, tokenAmount, internalAmount);
    }

    /// @dev Reject fee-on-transfer tokens. The vault credits the requested amount exactly.
    function _pull(address from, uint256 tokenAmount) internal {
        uint256 beforeBalance = collateral.balanceOf(address(this));
        bool ok = collateral.transferFrom(from, address(this), tokenAmount);
        if (!ok) revert TransferFailed();
        if (collateral.balanceOf(address(this)) - beforeBalance != tokenAmount) revert TransferFailed();
    }

    function _push(address to, uint256 tokenAmount) internal {
        bool ok = collateral.transfer(to, tokenAmount);
        if (!ok) revert TransferFailed();
    }
}
