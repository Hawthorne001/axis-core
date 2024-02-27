// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

// Modules
import {Module, Veecode, toKeycode, wrapVeecode} from "src/modules/Modules.sol";

// Auctions
import {AuctionModule} from "src/modules/Auction.sol";

contract MockAuctionModule is AuctionModule {
    constructor(address _owner) AuctionModule(_owner) {
        minAuctionDuration = 1 days;
    }

    function VEECODE() public pure virtual override returns (Veecode) {
        return wrapVeecode(toKeycode("MOCK"), 1);
    }

    function TYPE() public pure virtual override returns (Type) {
        return Type.Auction;
    }

    function _auction(uint96, Lot memory, bytes memory) internal virtual override returns (bool) {}

    function _cancelAuction(uint96 id_) internal override {
        //
    }

    function _purchase(
        uint96 id_,
        uint96 amount_,
        bytes calldata auctionData_
    ) internal override returns (uint256 payout, bytes memory auctionOutput) {}

    function _bid(
        uint96 id_,
        address bidder_,
        address referrer_,
        uint96 amount_,
        bytes calldata auctionData_
    ) internal override returns (uint64) {}

    function _settle(uint96 lotId_) internal override returns (Settlement memory, bytes memory) {}

    function _refundBid(
        uint96 lotId_,
        uint64 bidId_,
        address bidder_
    ) internal virtual override returns (uint256) {}

    function _claimBid(
        uint96 lotId_,
        uint64 bidId_
    ) internal virtual override returns (address, uint256, uint256, bytes memory) {}

    function _revertIfBidInvalid(uint96 lotId_, uint64 bidId_) internal view virtual override {}

    function _revertIfNotBidOwner(
        uint96 lotId_,
        uint64 bidId_,
        address caller_
    ) internal view virtual override {}

    function _revertIfBidClaimed(uint96 lotId_, uint64 bidId_) internal view virtual override {}

    function _revertIfLotSettled(uint96 lotId_) internal view virtual override {}

    function _revertIfLotNotSettled(uint96 lotId_) internal view virtual override {}
}

contract MockAuctionModuleV2 is MockAuctionModule {
    constructor(address _owner) MockAuctionModule(_owner) {}

    function VEECODE() public pure override returns (Veecode) {
        return wrapVeecode(toKeycode("MOCK"), 2);
    }
}
