// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {Module} from "src/modules/Modules.sol";
import {Auction} from "src/modules/Auction.sol";
import {EncryptedMarginalPriceAuctionModule} from "src/modules/auctions/EMPAM.sol";

import {EmpaModuleTest} from "test/modules/auctions/EMPA/EMPAModuleTest.sol";

contract EmpaModuleClaimBidTest is EmpaModuleTest {
    uint96 internal constant _BID_AMOUNT = 8e18;
    uint96 internal constant _BID_AMOUNT_OUT = 4e18;

    uint96 internal constant _BID_AMOUNT_UNSUCCESSFUL = 1e18;
    uint96 internal constant _BID_AMOUNT_OUT_UNSUCCESSFUL = 1e18;

    // [X] when the lot id is invalid
    //  [X] it reverts
    // [X] when the bid id is invalid
    //  [X] it reverts
    // [X] when the bidder is not the the bid owner
    //  [X] it returns the payout and updates the bid status
    // [X] given the bid has already been claimed
    //  [X] it reverts
    // [X] given the lot is not settled
    //  [X] it reverts
    // [X] when the caller is not the parent
    //  [X] it reverts
    // [X] given the bid is not successful
    //  [X] given the quote token decimals are larger
    //   [X] it returns the exact bid amount
    //  [X] given the quote token decimals are smaller
    //   [X] it returns the exact bid amount
    //  [X] it returns the refund details and updates the bid status
    // [X] given the quote token decimals are larger
    //  [X] it returns the exact payout
    // [X] given the quote token decimals are smaller
    //  [X] it returns the exact payout
    // [X] it returns the payout and updates the bid status

    function test_invalidLotId_reverts() external {
        bytes memory err = abi.encodeWithSelector(Auction.Auction_InvalidLotId.selector, _lotId);
        vm.expectRevert(err);

        // Call the function
        vm.prank(address(_auctionHouse));
        _module.claimBid(_lotId, _bidId, _BIDDER);
    }

    function test_invalidBidId_reverts() external givenLotIsCreated {
        bytes memory err =
            abi.encodeWithSelector(Auction.Auction_InvalidBidId.selector, _lotId, _bidId);
        vm.expectRevert(err);

        // Call the function
        vm.prank(address(_auctionHouse));
        _module.claimBid(_lotId, _bidId, _BIDDER);
    }

    function test_bidderIsNotOwner()
        external
        givenLotIsCreated
        givenLotHasStarted
        givenBidIsCreated(_BID_AMOUNT_UNSUCCESSFUL, _BID_AMOUNT_OUT_UNSUCCESSFUL)
        givenLotHasConcluded
        givenPrivateKeyIsSubmitted
        givenLotIsDecrypted
        givenLotIsSettled
    {
        // Call the function
        vm.prank(address(_auctionHouse));
        (Auction.BidClaim memory bidClaim,) = _module.claimBid(_lotId, _bidId, address(this));

        // Check the result
        assertEq(bidClaim.bidder, _BIDDER, "bidder");
        assertEq(bidClaim.referrer, _REFERRER, "referrer");
        assertEq(bidClaim.paid, _BID_AMOUNT_UNSUCCESSFUL, "paid");
        assertEq(bidClaim.payout, 0, "payout");

        // Check the bid status
        EncryptedMarginalPriceAuctionModule.Bid memory bid = _getBid(_lotId, _bidId);
        assertEq(
            uint8(bid.status),
            uint8(EncryptedMarginalPriceAuctionModule.BidStatus.Claimed),
            "status"
        );
    }

    function test_bidAlreadyClaimed_reverts()
        external
        givenLotIsCreated
        givenLotHasStarted
        givenBidIsCreated(_BID_AMOUNT, _BID_AMOUNT_OUT)
        givenLotHasConcluded
        givenPrivateKeyIsSubmitted
        givenLotIsDecrypted
        givenLotIsSettled
        givenBidIsClaimed(_bidId)
    {
        bytes memory err = abi.encodeWithSelector(
            EncryptedMarginalPriceAuctionModule.Bid_WrongState.selector, _lotId, _bidId
        );
        vm.expectRevert(err);

        // Call the function
        vm.prank(address(_auctionHouse));
        _module.claimBid(_lotId, _bidId, _BIDDER);
    }

    function test_lotNotSettled_reverts()
        external
        givenLotIsCreated
        givenLotHasStarted
        givenBidIsCreated(_BID_AMOUNT, _BID_AMOUNT_OUT)
        givenLotHasConcluded
        givenPrivateKeyIsSubmitted
        givenLotIsDecrypted
    {
        bytes memory err = abi.encodeWithSelector(
            EncryptedMarginalPriceAuctionModule.Auction_WrongState.selector, _lotId
        );
        vm.expectRevert(err);

        // Call the function
        vm.prank(address(_auctionHouse));
        _module.claimBid(_lotId, _bidId, _BIDDER);
    }

    function test_callerIsNotParent_reverts()
        external
        givenLotIsCreated
        givenLotHasStarted
        givenBidIsCreated(_BID_AMOUNT, _BID_AMOUNT_OUT)
        givenLotHasConcluded
        givenPrivateKeyIsSubmitted
        givenLotIsDecrypted
        givenLotIsSettled
    {
        bytes memory err = abi.encodeWithSelector(Module.Module_OnlyParent.selector, address(this));
        vm.expectRevert(err);

        // Call the function
        _module.claimBid(_lotId, _bidId, _BIDDER);
    }

    function test_unsuccessfulBid()
        external
        givenLotIsCreated
        givenLotHasStarted
        givenBidIsCreated(_BID_AMOUNT_UNSUCCESSFUL, _BID_AMOUNT_OUT_UNSUCCESSFUL)
        givenLotHasConcluded
        givenPrivateKeyIsSubmitted
        givenLotIsDecrypted
        givenLotIsSettled
    {
        // Call the function
        vm.prank(address(_auctionHouse));
        (Auction.BidClaim memory bidClaim,) = _module.claimBid(_lotId, _bidId, _BIDDER);

        // Check the result
        assertEq(bidClaim.bidder, _BIDDER);
        assertEq(bidClaim.referrer, _REFERRER);
        assertEq(bidClaim.paid, _BID_AMOUNT_UNSUCCESSFUL);
        assertEq(bidClaim.payout, 0);

        // Check the bid status
        EncryptedMarginalPriceAuctionModule.Bid memory bid = _getBid(_lotId, _bidId);
        assertEq(uint8(bid.status), uint8(EncryptedMarginalPriceAuctionModule.BidStatus.Claimed));
    }

    function test_unsuccessfulBid_fuzz(
        uint96 bidAmountIn_,
        uint96 bidAmountOut_
    ) external givenLotIsCreated givenLotHasStarted {
        uint96 minFillAmount = _MIN_FILL_PERCENT * _LOT_CAPACITY / 1e5;
        // Bound the amounts
        uint96 bidAmountIn = uint96(bound(bidAmountIn_, 1e18, 10e18));
        uint96 bidAmountOut = uint96(bound(bidAmountOut_, 1e18, minFillAmount - 1)); // Ensures that it will not be a winning bid

        // Create the bid
        _bidId = _createBid(bidAmountIn, bidAmountOut);

        // Wrap up the lot
        _concludeLot();
        _submitPrivateKey();
        _decryptLot();
        _settleLot();

        // Call the function
        vm.prank(address(_auctionHouse));
        (Auction.BidClaim memory bidClaim,) = _module.claimBid(_lotId, _bidId, _BIDDER);

        // Check the result
        assertEq(bidClaim.bidder, _BIDDER);
        assertEq(bidClaim.referrer, _REFERRER);
        assertEq(bidClaim.paid, bidAmountIn);
        assertEq(bidClaim.payout, 0);

        // Check the bid status
        EncryptedMarginalPriceAuctionModule.Bid memory bid = _getBid(_lotId, _bidId);
        assertEq(uint8(bid.status), uint8(EncryptedMarginalPriceAuctionModule.BidStatus.Claimed));
    }

    function test_unsuccessfulBid_quoteTokenDecimalsLarger()
        external
        givenQuoteTokenDecimals(17)
        givenBaseTokenDecimals(13)
        givenLotIsCreated
        givenLotHasStarted
        givenBidIsCreated(
            _scaleQuoteTokenAmount(_BID_AMOUNT_UNSUCCESSFUL),
            _scaleBaseTokenAmount(_BID_AMOUNT_OUT_UNSUCCESSFUL)
        )
        givenLotHasConcluded
        givenPrivateKeyIsSubmitted
        givenLotIsDecrypted
        givenLotIsSettled
    {
        // Call the function
        vm.prank(address(_auctionHouse));
        (Auction.BidClaim memory bidClaim,) = _module.claimBid(_lotId, _bidId, _BIDDER);

        // Check the result
        assertEq(bidClaim.bidder, _BIDDER);
        assertEq(bidClaim.referrer, _REFERRER);
        assertEq(bidClaim.paid, _scaleQuoteTokenAmount(_BID_AMOUNT_UNSUCCESSFUL));
        assertEq(bidClaim.payout, 0);

        // Check the bid status
        EncryptedMarginalPriceAuctionModule.Bid memory bid = _getBid(_lotId, _bidId);
        assertEq(uint8(bid.status), uint8(EncryptedMarginalPriceAuctionModule.BidStatus.Claimed));
    }

    function test_unsuccessfulBid_quoteTokenDecimalsSmaller()
        external
        givenQuoteTokenDecimals(13)
        givenBaseTokenDecimals(17)
        givenLotIsCreated
        givenLotHasStarted
        givenBidIsCreated(
            _scaleQuoteTokenAmount(_BID_AMOUNT_UNSUCCESSFUL),
            _scaleBaseTokenAmount(_BID_AMOUNT_OUT_UNSUCCESSFUL)
        )
        givenLotHasConcluded
        givenPrivateKeyIsSubmitted
        givenLotIsDecrypted
        givenLotIsSettled
    {
        // Call the function
        vm.prank(address(_auctionHouse));
        (Auction.BidClaim memory bidClaim,) = _module.claimBid(_lotId, _bidId, _BIDDER);

        // Check the result
        assertEq(bidClaim.bidder, _BIDDER);
        assertEq(bidClaim.referrer, _REFERRER);
        assertEq(bidClaim.paid, _scaleQuoteTokenAmount(_BID_AMOUNT_UNSUCCESSFUL));
        assertEq(bidClaim.payout, 0);

        // Check the bid status
        EncryptedMarginalPriceAuctionModule.Bid memory bid = _getBid(_lotId, _bidId);
        assertEq(uint8(bid.status), uint8(EncryptedMarginalPriceAuctionModule.BidStatus.Claimed));
    }

    function test_successfulBid()
        external
        givenLotIsCreated
        givenLotHasStarted
        givenBidIsCreated(_BID_AMOUNT, _BID_AMOUNT_OUT)
        givenLotHasConcluded
        givenPrivateKeyIsSubmitted
        givenLotIsDecrypted
        givenLotIsSettled
    {
        // Call the function
        vm.prank(address(_auctionHouse));
        (Auction.BidClaim memory bidClaim,) = _module.claimBid(_lotId, _bidId, _BIDDER);

        // Check the result
        assertEq(bidClaim.bidder, _BIDDER);
        assertEq(bidClaim.referrer, _REFERRER);
        assertEq(bidClaim.paid, _BID_AMOUNT);
        assertEq(bidClaim.payout, _BID_AMOUNT_OUT);

        // Check the bid status
        EncryptedMarginalPriceAuctionModule.Bid memory bid = _getBid(_lotId, _bidId);
        assertEq(uint8(bid.status), uint8(EncryptedMarginalPriceAuctionModule.BidStatus.Claimed));
    }

    function test_successfulBid_quoteTokenDecimalsLarger()
        external
        givenQuoteTokenDecimals(17)
        givenBaseTokenDecimals(13)
        givenLotIsCreated
        givenLotHasStarted
        givenBidIsCreated(_scaleQuoteTokenAmount(_BID_AMOUNT), _scaleBaseTokenAmount(_BID_AMOUNT_OUT))
        givenLotHasConcluded
        givenPrivateKeyIsSubmitted
        givenLotIsDecrypted
        givenLotIsSettled
    {
        // Call the function
        vm.prank(address(_auctionHouse));
        (Auction.BidClaim memory bidClaim,) = _module.claimBid(_lotId, _bidId, _BIDDER);

        // Check the result
        assertEq(bidClaim.bidder, _BIDDER);
        assertEq(bidClaim.referrer, _REFERRER);
        assertEq(bidClaim.paid, _scaleQuoteTokenAmount(_BID_AMOUNT));
        assertEq(bidClaim.payout, _scaleBaseTokenAmount(_BID_AMOUNT_OUT));

        // Check the bid status
        EncryptedMarginalPriceAuctionModule.Bid memory bid = _getBid(_lotId, _bidId);
        assertEq(uint8(bid.status), uint8(EncryptedMarginalPriceAuctionModule.BidStatus.Claimed));
    }

    function test_successfulBid_quoteTokenDecimalsSmaller()
        external
        givenQuoteTokenDecimals(13)
        givenBaseTokenDecimals(17)
        givenLotIsCreated
        givenLotHasStarted
        givenBidIsCreated(_scaleQuoteTokenAmount(_BID_AMOUNT), _scaleBaseTokenAmount(_BID_AMOUNT_OUT))
        givenLotHasConcluded
        givenPrivateKeyIsSubmitted
        givenLotIsDecrypted
        givenLotIsSettled
    {
        // Call the function
        vm.prank(address(_auctionHouse));
        (Auction.BidClaim memory bidClaim,) = _module.claimBid(_lotId, _bidId, _BIDDER);

        // Check the result
        assertEq(bidClaim.bidder, _BIDDER);
        assertEq(bidClaim.referrer, _REFERRER);
        assertEq(bidClaim.paid, _scaleQuoteTokenAmount(_BID_AMOUNT));
        assertEq(bidClaim.payout, _scaleBaseTokenAmount(_BID_AMOUNT_OUT));

        // Check the bid status
        EncryptedMarginalPriceAuctionModule.Bid memory bid = _getBid(_lotId, _bidId);
        assertEq(uint8(bid.status), uint8(EncryptedMarginalPriceAuctionModule.BidStatus.Claimed));
    }

    function test_successfulBid_amountIn_fuzz(uint96 bidAmountIn_)
        external
        givenLotIsCreated
        givenLotHasStarted
    {
        // Bound the amount in
        uint96 bidAmountIn = uint96(bound(bidAmountIn_, _BID_AMOUNT_OUT, 10e20)); // Ensures that the price is greater than _MIN_PRICE

        // Create the bid
        _bidId = _createBid(bidAmountIn, _BID_AMOUNT_OUT);

        // Wrap up the lot
        _concludeLot();
        _submitPrivateKey();
        _decryptLot();
        _settleLot();

        // Calculate the expected amounts
        uint256 marginalPrice =
            FixedPointMathLib.mulDivUp(uint256(bidAmountIn), _BASE_SCALE, _BID_AMOUNT_OUT);
        uint256 expectedAmountOut =
            FixedPointMathLib.mulDivDown(bidAmountIn, _BASE_SCALE, marginalPrice);

        // Call the function
        vm.prank(address(_auctionHouse));
        (Auction.BidClaim memory bidClaim,) = _module.claimBid(_lotId, _bidId, _BIDDER);

        // Check the result
        assertEq(bidClaim.bidder, _BIDDER);
        assertEq(bidClaim.referrer, _REFERRER);
        assertEq(bidClaim.paid, bidAmountIn, "paid");
        assertEq(bidClaim.payout, expectedAmountOut, "payout");

        // Check the bid status
        EncryptedMarginalPriceAuctionModule.Bid memory bid = _getBid(_lotId, _bidId);
        assertEq(
            uint8(bid.status),
            uint8(EncryptedMarginalPriceAuctionModule.BidStatus.Claimed),
            "status"
        );
    }

    function test_successfulBid_amountOut_fuzz(uint96 bidAmountOut_)
        external
        givenLotIsCreated
        givenLotHasStarted
    {
        uint96 minFillAmount = _MIN_FILL_PERCENT * _LOT_CAPACITY / 1e5;

        // Bound the amount out
        uint96 bidAmountOut = uint96(bound(bidAmountOut_, minFillAmount, _LOT_CAPACITY - 1)); // Ensures that the lot settles but is not overfilled
        uint96 bidAmountIn = 20e18; // Ensures that the price is greater than _MIN_PRICE

        // Create the bid
        _bidId = _createBid(bidAmountIn, bidAmountOut);

        // Wrap up the lot
        _concludeLot();
        _submitPrivateKey();
        _decryptLot();
        _settleLot();

        // Calculate the expected amounts
        uint256 marginalPrice =
            FixedPointMathLib.mulDivUp(uint256(bidAmountIn), _BASE_SCALE, bidAmountOut);
        uint256 expectedAmountOut =
            FixedPointMathLib.mulDivDown(bidAmountIn, _BASE_SCALE, marginalPrice);

        // Call the function
        vm.prank(address(_auctionHouse));
        (Auction.BidClaim memory bidClaim,) = _module.claimBid(_lotId, _bidId, _BIDDER);

        // Check the result
        assertEq(bidClaim.bidder, _BIDDER);
        assertEq(bidClaim.referrer, _REFERRER);
        assertEq(bidClaim.paid, bidAmountIn, "paid");
        assertEq(bidClaim.payout, expectedAmountOut, "payout");

        // Check the bid status
        EncryptedMarginalPriceAuctionModule.Bid memory bid = _getBid(_lotId, _bidId);
        assertEq(
            uint8(bid.status),
            uint8(EncryptedMarginalPriceAuctionModule.BidStatus.Claimed),
            "status"
        );
    }
}
