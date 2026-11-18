// SPDX-License-Identifier: LicenseRef-SM-Source-Available-1.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockAggregator} from "../src/mocks/MockAggregator.sol";
import {OracleAdapter} from "../src/oracle/OracleAdapter.sol";
import {Ownable2Step} from "../src/access/Ownable2Step.sol";

contract OracleAdapterTest is Test {
    MockAggregator internal feed;
    OracleAdapter internal oracle;

    function setUp() public {
        vm.warp(1_700_000_000);
        feed = new MockAggregator(8);
        feed.setPrice(2_000e8);
        oracle = new OracleAdapter(address(feed), 1 hours, 500, address(this));
    }

    function test_scalesToWadAndAnchors() public {
        uint256 price = oracle.getPrice();
        assertEq(price, 2_000e18);
        assertEq(oracle.lastAcceptedPrice(), 2_000e18);
        (uint256 peeked,) = oracle.peek();
        assertEq(peeked, 2_000e18);
    }

    function test_deviationIsInclusiveAndRejectsALargerJump() public {
        oracle.getPrice();
        feed.setPrice(2_100e8);
        assertEq(oracle.getPrice(), 2_100e18);

        feed.setPrice(2_000e8);
        oracle.getPrice();
        feed.setPrice(2_110e8);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.PriceDeviation.selector, 2_110e18, 2_000e18));
        oracle.getPrice();
    }

    function test_stalenessBoundaries() public {
        oracle.getPrice();
        feed.setUpdatedAt(block.timestamp - 1 hours);
        (uint256 price,) = oracle.peek();
        assertEq(price, 2_000e18);

        feed.setUpdatedAt(block.timestamp - 1 hours - 1);
        vm.expectRevert(
            abi.encodeWithSelector(OracleAdapter.StalePrice.selector, block.timestamp - 1 hours - 1, block.timestamp)
        );
        oracle.peek();

        feed.setUpdatedAt(block.timestamp + 10);
        vm.expectRevert();
        oracle.peek();
    }

    function test_rejectsNonPositiveIncompleteAndOutOfRangeAnswers() public {
        feed.setPrice(0);
        vm.expectRevert(OracleAdapter.InvalidPrice.selector);
        oracle.peek();

        feed.setPrice(-5);
        vm.expectRevert(OracleAdapter.InvalidPrice.selector);
        oracle.peek();

        feed.setPrice(2_000e8);
        feed.setAnsweredInRound(0);
        vm.expectRevert();
        oracle.peek();

        feed.setAnsweredInRound(feed.roundId());
        feed.setPrice(1);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.PriceOutOfBounds.selector, 1e10));
        oracle.peek();
    }

    function test_ownerCanResetAnchorAndUpdateParams() public {
        oracle.getPrice();
        feed.setPrice(2_400e8);
        vm.expectRevert();
        oracle.getPrice();

        oracle.resetAnchor();
        assertEq(oracle.getPrice(), 2_400e18);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(Ownable2Step.NotOwner.selector);
        oracle.setParams(2 hours, 100);

        vm.expectRevert(OracleAdapter.BadParams.selector);
        oracle.setParams(0, 100);
        oracle.setParams(2 hours, 0);
        assertEq(oracle.maxDeviationBps(), 0);
    }
}
