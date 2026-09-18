// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title DealGuardCore
/// @notice EVM settlement layer for DealGuard. It pins a code/evidence snapshot hash, escrows the
///         native coin for buyer↔seller deals, and settles each deal from a `conditionMet` verdict
///         (produced off-chain by DealGuard's GenLayer LLM adjudication and relayed by the owner).
/// @dev    Every deal records the snapshot that was active when it opened, so a later snapshot change
///         never rewrites the rules a past deal was judged under.
contract DealGuardCore is Ownable, ReentrancyGuard {
    struct Deal {
        address buyer;
        address seller;
        uint256 amount;
        bytes32 evidenceHash; // snapshot pinned at submitDeal time
        uint64 openedAt;
        bool closed;
        bool conditionMet;
    }

    /// @notice Current code / evidence snapshot (e.g. sha256 of git HEAD + contract source).
    bytes32 public evidenceHash;

    /// @notice Number of deals ever submitted. Deal ids are 1..dealCount.
    uint256 public dealCount;

    mapping(uint256 id => Deal) private _deals;

    event SnapshotStored(bytes32 indexed previousHash, bytes32 indexed newHash);
    event DealSubmitted(
        uint256 indexed id, address indexed buyer, address indexed seller, uint256 amount, bytes32 evidenceHash
    );
    event DealClosed(uint256 indexed id, bool conditionMet);

    error ZeroHash();
    error ZeroAddress();
    error SameParty();
    error ZeroAmount();
    error NotBuyer();
    error WrongValue(uint256 expected, uint256 sent);
    error NoSnapshot();
    error UnknownDeal(uint256 id);
    error AlreadyClosed(uint256 id);
    error TransferFailed();

    constructor(address initialOwner, bytes32 initialEvidenceHash) Ownable(initialOwner) {
        if (initialEvidenceHash != bytes32(0)) {
            evidenceHash = initialEvidenceHash;
            emit SnapshotStored(bytes32(0), initialEvidenceHash);
        }
    }

    /// @notice Replace the pinned snapshot. Only the owner may change it.
    function storeSnapshot(bytes32 hash) external onlyOwner {
        if (hash == bytes32(0)) revert ZeroHash();
        bytes32 previous = evidenceHash;
        evidenceHash = hash;
        emit SnapshotStored(previous, hash);
    }

    /// @notice Open a deal and escrow `amount` wei. The buyer calls it and sends exactly `amount`.
    /// @return id The new deal id.
    function submitDeal(address buyer, address seller, uint256 amount)
        external
        payable
        nonReentrant
        returns (uint256 id)
    {
        if (buyer == address(0) || seller == address(0)) revert ZeroAddress();
        if (buyer == seller) revert SameParty();
        if (amount == 0) revert ZeroAmount();
        if (msg.sender != buyer) revert NotBuyer();
        if (msg.value != amount) revert WrongValue(amount, msg.value);
        bytes32 snapshot = evidenceHash;
        if (snapshot == bytes32(0)) revert NoSnapshot();

        id = ++dealCount;
        _deals[id] = Deal({
            buyer: buyer,
            seller: seller,
            amount: amount,
            evidenceHash: snapshot,
            openedAt: uint64(block.timestamp),
            closed: false,
            conditionMet: false
        });
        emit DealSubmitted(id, buyer, seller, amount, snapshot);
    }

    /// @notice Settle a deal: pay the seller if `conditionMet`, otherwise refund the buyer.
    /// @dev    Owner-only: the owner relays the verdict reached by GenLayer consensus.
    ///         Checks-effects-interactions plus nonReentrant guard the payout.
    function closeDeal(uint256 id, bool conditionMet) external onlyOwner nonReentrant {
        Deal storage deal = _deals[id];
        if (deal.buyer == address(0)) revert UnknownDeal(id);
        if (deal.closed) revert AlreadyClosed(id);

        deal.closed = true;
        deal.conditionMet = conditionMet;
        emit DealClosed(id, conditionMet);

        address payee = conditionMet ? deal.seller : deal.buyer;
        (bool ok,) = payee.call{value: deal.amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Full deal metadata.
    function getDeal(uint256 id) external view returns (Deal memory) {
        if (_deals[id].buyer == address(0)) revert UnknownDeal(id);
        return _deals[id];
    }
}
