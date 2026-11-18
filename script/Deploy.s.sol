// SPDX-License-Identifier: LicenseRef-SM-Source-Available-1.0
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockAggregator} from "../src/mocks/MockAggregator.sol";
import {OracleAdapter} from "../src/oracle/OracleAdapter.sol";
import {CollateralVault} from "../src/vault/CollateralVault.sol";
import {PerpMarket} from "../src/core/PerpMarket.sol";

/// @title Local Anvil deployment of the perpetual engine and its mocks.
/// @notice Refuses every chain except Anvil (31337). The collateral token is a
///         public-mint mock. Do not point this script at a network that holds value.
/// @dev Broadcast with a key from the `anvil` banner:
///      forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --private-key $ANVIL_PRIVATE_KEY
contract Deploy is Script {
    error LocalOnly(uint256 chainId);

    function run() external {
        if (block.chainid != 31337) revert LocalOnly(block.chainid);

        vm.startBroadcast();

        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        MockAggregator indexFeed = new MockAggregator(8);
        MockAggregator markFeed = new MockAggregator(8);
        // $2,000 with 8-decimal Chainlink-style answers.
        indexFeed.setPrice(2_000e8);
        markFeed.setPrice(2_000e8);

        OracleAdapter indexOracle = new OracleAdapter(address(indexFeed), 1 hours, 2_000, msg.sender);
        OracleAdapter markOracle = new OracleAdapter(address(markFeed), 1 hours, 2_000, msg.sender);
        CollateralVault vault = new CollateralVault(address(usdc), msg.sender);

        PerpMarket market = new PerpMarket(
            address(vault),
            address(indexOracle),
            address(markOracle),
            PerpMarket.MarketConfig({
                maxLeverage: 20e18,
                maintenanceMarginBps: 250,
                liquidationRewardBps: 500,
                tradingFeeBps: 5,
                insuranceSplitBps: 5_000,
                fundingPeriod: 1 hours,
                maxPremium: 0.05e18,
                minNotional: 10e18,
                maxOpenInterest: 1_000_000e18
            }),
            msg.sender
        );
        vault.setMarket(address(market));

        // Seed the insurance fund so a local long/short can realize profit.
        usdc.mint(msg.sender, 2_000_000e6);
        usdc.approve(address(vault), type(uint256).max);
        vault.donateInsurance(1_000_000e6);

        vm.stopBroadcast();

        console2.log("Collateral", address(usdc));
        console2.log("Vault", address(vault));
        console2.log("Market", address(market));
        console2.log("IndexOracle", address(indexOracle));
        console2.log("MarkOracle", address(markOracle));
        console2.log("IndexFeed", address(indexFeed));
        console2.log("MarkFeed", address(markFeed));
    }
}
