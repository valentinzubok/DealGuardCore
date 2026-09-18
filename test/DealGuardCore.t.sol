// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {DealGuardCore} from "../src/DealGuardCore.sol";

contract Reenterer {
    DealGuardCore public core;
    uint256 public targetId;

    constructor(DealGuardCore core_) {
        core = core_;
    }

    function open(address seller, uint256 amount) external payable returns (uint256) {
        targetId = core.submitDeal{value: amount}(address(this), seller, amount);
        return targetId;
    }

    receive() external payable {
        // Try to re-enter closeDeal during the refund; must fail.
        try core.closeDeal(targetId, false) {} catch {}
    }
}

contract RejectingPayee {
    receive() external payable {
        revert("no");
    }
}

contract DealGuardCoreTest is Test {
    DealGuardCore core;
    address owner = makeAddr("owner");
    address buyer = makeAddr("buyer");
    address seller = makeAddr("seller");
    bytes32 constant SNAP = keccak256("git-head+contract-sha256");

    event SnapshotStored(bytes32 indexed previousHash, bytes32 indexed newHash);
    event DealClosed(uint256 indexed id, bool conditionMet);

    function setUp() public {
        core = new DealGuardCore(owner, SNAP);
        vm.deal(buyer, 10 ether);
    }

    function _open(uint256 amount) internal returns (uint256) {
        vm.prank(buyer);
        return core.submitDeal{value: amount}(buyer, seller, amount);
    }

    function test_ConstructorPinsSnapshot() public view {
        assertEq(core.evidenceHash(), SNAP);
        assertEq(core.owner(), owner);
    }

    function test_StoreSnapshotOnlyOwner() public {
        bytes32 next = keccak256("v2");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, buyer));
        vm.prank(buyer);
        core.storeSnapshot(next);

        vm.expectEmit(true, true, false, false);
        emit SnapshotStored(SNAP, next);
        vm.prank(owner);
        core.storeSnapshot(next);
        assertEq(core.evidenceHash(), next);
    }

    function test_StoreSnapshotRejectsZero() public {
        vm.prank(owner);
        vm.expectRevert(DealGuardCore.ZeroHash.selector);
        core.storeSnapshot(bytes32(0));
    }

    function test_SubmitDealEscrowsAndPinsSnapshot() public {
        uint256 id = _open(1 ether);
        assertEq(id, 1);
        assertEq(address(core).balance, 1 ether);
        DealGuardCore.Deal memory d = core.getDeal(id);
        assertEq(d.buyer, buyer);
        assertEq(d.seller, seller);
        assertEq(d.amount, 1 ether);
        assertEq(d.evidenceHash, SNAP);
        assertFalse(d.closed);

        // Later snapshot changes do not rewrite an open deal.
        vm.prank(owner);
        core.storeSnapshot(keccak256("v2"));
        assertEq(core.getDeal(id).evidenceHash, SNAP);
    }

    function test_SubmitDealValidation() public {
        vm.startPrank(buyer);
        vm.expectRevert(abi.encodeWithSelector(DealGuardCore.WrongValue.selector, 1 ether, 0.5 ether));
        core.submitDeal{value: 0.5 ether}(buyer, seller, 1 ether);
        vm.expectRevert(DealGuardCore.SameParty.selector);
        core.submitDeal{value: 1 ether}(buyer, buyer, 1 ether);
        vm.expectRevert(DealGuardCore.ZeroAmount.selector);
        core.submitDeal(buyer, seller, 0);
        vm.expectRevert(DealGuardCore.ZeroAddress.selector);
        core.submitDeal{value: 1 ether}(buyer, address(0), 1 ether);
        vm.stopPrank();

        vm.deal(seller, 1 ether);
        vm.prank(seller);
        vm.expectRevert(DealGuardCore.NotBuyer.selector);
        core.submitDeal{value: 1 ether}(buyer, seller, 1 ether);
    }

    function test_SubmitDealNeedsSnapshot() public {
        DealGuardCore bare = new DealGuardCore(owner, bytes32(0));
        vm.prank(buyer);
        vm.expectRevert(DealGuardCore.NoSnapshot.selector);
        bare.submitDeal{value: 1 ether}(buyer, seller, 1 ether);
    }

    function test_CloseDealPaysSellerWhenConditionMet() public {
        uint256 id = _open(1 ether);
        vm.expectEmit(true, false, false, true);
        emit DealClosed(id, true);
        vm.prank(owner);
        core.closeDeal(id, true);
        assertEq(seller.balance, 1 ether);
        assertEq(address(core).balance, 0);
        assertTrue(core.getDeal(id).conditionMet);
    }

    function test_CloseDealRefundsBuyerWhenConditionNotMet() public {
        uint256 id = _open(2 ether);
        vm.prank(owner);
        core.closeDeal(id, false);
        assertEq(buyer.balance, 10 ether);
        assertEq(seller.balance, 0);
    }

    function test_CloseDealGuards() public {
        uint256 id = _open(1 ether);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, buyer));
        vm.prank(buyer);
        core.closeDeal(id, true);

        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(DealGuardCore.UnknownDeal.selector, 99));
        core.closeDeal(99, true);
        core.closeDeal(id, true);
        vm.expectRevert(abi.encodeWithSelector(DealGuardCore.AlreadyClosed.selector, id));
        core.closeDeal(id, true);
        vm.stopPrank();
    }

    function test_ReentrancyBlockedDuringPayout() public {
        Reenterer attacker = new Reenterer(core);
        vm.deal(address(attacker), 1 ether);
        // The refund lands in receive(), which tries closeDeal again: blocked by onlyOwner + nonReentrant.
        uint256 id = attacker.open{value: 0}(seller, 1 ether);
        vm.prank(owner);
        core.closeDeal(id, false);
        assertEq(address(attacker).balance, 1 ether); // refunded exactly once
        assertEq(address(core).balance, 0);
    }

    function test_FailedPayoutRevertsWholeClose() public {
        RejectingPayee bad = new RejectingPayee();
        uint256 id = _open(1 ether);
        // A seller that rejects ETH makes the payout fail; the whole close must roll back.
        vm.prank(buyer);
        uint256 id2 = core.submitDeal{value: 1 ether}(buyer, address(bad), 1 ether);
        vm.prank(owner);
        vm.expectRevert(DealGuardCore.TransferFailed.selector);
        core.closeDeal(id2, true);
        assertFalse(core.getDeal(id2).closed);
        assertFalse(core.getDeal(id).closed);
    }

    function testFuzz_SettlementConservesFunds(uint96 amount, bool met) public {
        vm.assume(amount > 0);
        vm.deal(buyer, amount);
        vm.prank(buyer);
        uint256 id = core.submitDeal{value: amount}(buyer, seller, amount);
        vm.prank(owner);
        core.closeDeal(id, met);
        assertEq(buyer.balance + seller.balance, amount);
        assertEq(address(core).balance, 0);
    }
}
