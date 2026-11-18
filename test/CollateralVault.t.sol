// SPDX-License-Identifier: LicenseRef-SM-Source-Available-1.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {CollateralVault} from "../src/vault/CollateralVault.sol";
import {ReentrancyGuard} from "../src/security/ReentrancyGuard.sol";

contract FeeOnTransferToken {
    string public name = "Fee";
    string public symbol = "FEE";
    uint8 public decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount - 1;
    }
}

contract ReenteringToken is MockERC20 {
    CollateralVault public vault;
    bool public attack;

    constructor() MockERC20("Bad", "BAD", 6) {}

    function arm(address vault_) external {
        vault = CollateralVault(vault_);
        attack = true;
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        super._transfer(from, to, amount);
        if (attack) {
            attack = false;
            vault.withdraw(1);
        }
    }
}

contract CollateralVaultTest is Test {
    function test_eighteenDecimalCollateralHasUnitScale() public {
        MockERC20 token = new MockERC20("Wad USD", "WUSD", 18);
        CollateralVault vault = new CollateralVault(address(token), address(this));
        assertEq(vault.scaleFactor(), 1);
        token.mint(address(this), 5e18);
        token.approve(address(vault), 5e18);
        vault.deposit(5e18);
        assertEq(vault.freeBalance(address(this)), 5e18);
        vault.withdraw(2e18);
        assertEq(vault.freeBalance(address(this)), 3e18);
        assertEq(token.balanceOf(address(vault)) * vault.scaleFactor(), vault.totalAccounted());
    }

    function test_rejectsFeeOnTransfer() public {
        FeeOnTransferToken token = new FeeOnTransferToken();
        CollateralVault vault = new CollateralVault(address(token), address(this));
        token.mint(address(this), 100e6);
        token.approve(address(vault), 100e6);
        vm.expectRevert(CollateralVault.TransferFailed.selector);
        vault.deposit(100e6);
        assertEq(vault.totalAccounted(), 0);
    }

    function test_withdrawReentrancyIsRejected() public {
        ReenteringToken token = new ReenteringToken();
        CollateralVault vault = new CollateralVault(address(token), address(this));
        token.mint(address(this), 10e6);
        token.approve(address(vault), type(uint256).max);
        vault.deposit(10e6);

        token.arm(address(vault));
        vm.expectRevert(ReentrancyGuard.Reentrancy.selector);
        vault.withdraw(1e6);
        // The outer withdrawal reverted, so the deposit is still there.
        assertEq(vault.freeBalance(address(this)), 10e18);
    }

    function test_protocolFeesAreOwnerOnly() public {
        MockERC20 token = new MockERC20("USD Coin", "USDC", 6);
        CollateralVault vault = new CollateralVault(address(token), address(this));
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        vault.withdrawProtocolFees(makeAddr("stranger"), 1);
    }
}
