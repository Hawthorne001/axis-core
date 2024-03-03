// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

// Auctions
import {Auction} from "src/modules/Auction.sol";
import {Auctioneer} from "src/bases/Auctioneer.sol";

import {AuctionHouseTest} from "test/AuctionHouse/AuctionHouseTest.sol";

contract CancelAuctionTest is AuctionHouseTest {
    uint96 internal constant _PURCHASE_AMOUNT = 2e18;
    uint96 internal constant _PURCHASE_AMOUNT_OUT = 1e18;
    uint32 internal constant _PAYOUT_MULTIPLIER = 50_000; // 50%

    bytes internal _purchaseAuctionData = abi.encode("");

    modifier givenPayoutMultiplier(uint256 multiplier_) {
        _atomicAuctionModule.setPayoutMultiplier(_lotId, multiplier_);
        _;
    }

    // cancel
    // [X] reverts if not the seller
    // [X] reverts if lot is not active
    // [X] reverts if lot id is invalid
    // [X] reverts if the lot is already cancelled
    // [X] given the auction is not prefunded
    //  [X] it sets the lot to inactive on the AuctionModule

    function testReverts_whenNotSeller()
        external
        whenAuctionTypeIsAtomic
        whenAtomicAuctionModuleIsInstalled
        givenLotIsCreated
    {
        bytes memory err = abi.encodeWithSelector(Auctioneer.NotPermitted.selector, address(this));
        vm.expectRevert(err);

        _auctionHouse.cancel(_lotId);
    }

    function testReverts_whenUnauthorized(address user_)
        external
        whenAuctionTypeIsAtomic
        whenAtomicAuctionModuleIsInstalled
        givenLotIsCreated
    {
        vm.assume(user_ != _SELLER);

        bytes memory err = abi.encodeWithSelector(Auctioneer.NotPermitted.selector, user_);
        vm.expectRevert(err);

        vm.prank(user_);
        _auctionHouse.cancel(_lotId);
    }

    function testReverts_whenLotIdInvalid() external {
        bytes memory err = abi.encodeWithSelector(Auctioneer.InvalidLotId.selector, _lotId);
        vm.expectRevert(err);

        vm.prank(_SELLER);
        _auctionHouse.cancel(_lotId);
    }

    function testReverts_whenLotIsInactive()
        external
        whenAuctionTypeIsAtomic
        whenAtomicAuctionModuleIsInstalled
        givenLotIsCreated
        givenLotIsConcluded
    {
        bytes memory err = abi.encodeWithSelector(Auction.Auction_MarketNotActive.selector, _lotId);
        vm.expectRevert(err);

        vm.prank(_SELLER);
        _auctionHouse.cancel(_lotId);
    }

    function test_givenCancelled_reverts()
        external
        whenAuctionTypeIsAtomic
        whenAtomicAuctionModuleIsInstalled
        givenLotIsCreated
        givenLotIsCancelled
    {
        // Expect revert
        bytes memory err = abi.encodeWithSelector(Auction.Auction_MarketNotActive.selector, _lotId);
        vm.expectRevert(err);

        // Call the function
        vm.prank(_SELLER);
        _auctionHouse.cancel(_lotId);
    }

    function test_success()
        external
        whenAuctionTypeIsAtomic
        whenAtomicAuctionModuleIsInstalled
        givenLotIsCreated
        givenLotHasStarted
    {
        assertTrue(_atomicAuctionModule.isLive(_lotId), "before cancellation: isLive mismatch");

        vm.prank(_SELLER);
        _auctionHouse.cancel(_lotId);

        // Get lot data from the module
        (, uint48 lotConclusion,,,, uint256 lotCapacity,,) = _atomicAuctionModule.lotData(_lotId);
        assertEq(lotConclusion, uint48(block.timestamp));
        assertEq(lotCapacity, 0);

        assertFalse(_atomicAuctionModule.isLive(_lotId), "after cancellation: isLive mismatch");
    }

    // [X] given the auction is prefunded
    //  [X] it refunds the prefunded amount in payout tokens to the seller
    //  [X] given a purchase has been made
    //   [X] it refunds the remaining prefunded amount in payout tokens to the seller

    modifier givenLotIsPrefunded() {
        _atomicAuctionModule.setRequiredPrefunding(true);

        // Mint payout tokens to the seller
        _baseToken.mint(_SELLER, _LOT_CAPACITY);

        // Approve transfer to the auction house
        vm.prank(_SELLER);
        _baseToken.approve(address(_auctionHouse), _LOT_CAPACITY);
        _;
    }

    function test_prefunded()
        external
        givenLotIsPrefunded
        whenAuctionTypeIsAtomic
        whenAtomicAuctionModuleIsInstalled
        givenLotIsCreated
        givenLotHasStarted
    {
        // Check the seller's balance
        uint256 sellerBalance = _baseToken.balanceOf(_SELLER);

        // Cancel the lot
        vm.prank(_SELLER);
        _auctionHouse.cancel(_lotId);

        // Check the seller's balance
        assertEq(
            _baseToken.balanceOf(_SELLER),
            sellerBalance + _LOT_CAPACITY,
            "base token: seller balance mismatch"
        );
    }

    function test_prefunded_givenPurchase()
        external
        givenLotIsPrefunded
        whenAuctionTypeIsAtomic
        whenAtomicAuctionModuleIsInstalled
        givenLotIsCreated
        givenLotHasStarted
        givenUserHasQuoteTokenBalance(_PURCHASE_AMOUNT)
        givenUserHasQuoteTokenAllowance(_PURCHASE_AMOUNT)
        givenPayoutMultiplier(_PAYOUT_MULTIPLIER)
        givenPurchase(_PURCHASE_AMOUNT, _PURCHASE_AMOUNT_OUT, _purchaseAuctionData)
    {
        // Check the seller's balance
        uint256 sellerBalance = _baseToken.balanceOf(_SELLER);

        // Cancel the lot
        vm.prank(_SELLER);
        _auctionHouse.cancel(_lotId);

        // Check the seller's balance
        assertEq(
            _baseToken.balanceOf(_SELLER),
            sellerBalance + _LOT_CAPACITY - _PURCHASE_AMOUNT_OUT,
            "base token: seller balance mismatch"
        );
    }

    // [X] given the auction is prefunded
    //  [X] given a curator is set
    //   [X] given a curator has not yet approved
    //    [X] nothing happens
    //   [X] given there have been purchases
    //    [X] it refunds the remaining prefunded amount in payout tokens to the seller
    //   [X] it refunds the prefunded amount in payout tokens to the seller

    modifier givenSellerHasCuratorFeeBalance() {
        uint256 lotCapacity = _catalogue.remainingCapacity(_lotId);

        _curatorMaxPotentialFee = uint96(lotCapacity) * _CURATOR_FEE_PERCENT / 1e5;

        // Mint
        _baseToken.mint(_SELLER, _curatorMaxPotentialFee);

        // Approve spending
        vm.prank(_SELLER);
        _baseToken.approve(address(_auctionHouse), _curatorMaxPotentialFee);
        _;
    }

    function test_prefunded_givenCuratorIsSet()
        external
        givenLotIsPrefunded
        givenCuratorIsSet
        whenAuctionTypeIsAtomic
        whenAtomicAuctionModuleIsInstalled
        givenLotIsCreated
        givenLotHasStarted
        givenSellerHasCuratorFeeBalance
        givenCuratorMaxFeeIsSet
    {
        // Balance before
        uint256 sellerBalanceBefore = _baseToken.balanceOf(_SELLER);
        assertEq(
            sellerBalanceBefore,
            _curatorMaxPotentialFee,
            "base token: balance mismatch for seller before"
        ); // Curator fee not moved

        // Cancel the lot
        vm.prank(_SELLER);
        _auctionHouse.cancel(_lotId);

        // Check the base token balances
        assertEq(
            _baseToken.balanceOf(_SELLER),
            _curatorMaxPotentialFee + _LOT_CAPACITY,
            "base token: balance mismatch for seller"
        );
        assertEq(
            _baseToken.balanceOf(address(_auctionHouse)),
            0,
            "base token: balance mismatch for auction house"
        );

        // Check prefunding amount
        (,,,,,,,,, uint256 lotPrefunding) = _auctionHouse.lotRouting(_lotId);
        assertEq(lotPrefunding, 0, "mismatch on prefunding");
    }

    function test_prefunded_givenCuratorHasApproved()
        external
        givenLotIsPrefunded
        givenCuratorIsSet
        whenAuctionTypeIsAtomic
        whenAtomicAuctionModuleIsInstalled
        givenLotIsCreated
        givenLotHasStarted
        givenCuratorMaxFeeIsSet
        givenCuratorFeeIsSet
        givenSellerHasCuratorFeeBalance
        givenCuratorHasApproved
    {
        // Balance before
        uint256 sellerBalanceBefore = _baseToken.balanceOf(_SELLER);
        assertEq(sellerBalanceBefore, 0, "base token: balance mismatch for seller before");

        // Cancel the lot
        vm.prank(_SELLER);
        _auctionHouse.cancel(_lotId);

        // Check the seller's balance
        assertEq(
            _baseToken.balanceOf(_SELLER),
            _LOT_CAPACITY + _curatorMaxPotentialFee,
            "base token: seller balance mismatch"
        ); // Capacity and max curator fee is returned
        assertEq(
            _baseToken.balanceOf(address(_auctionHouse)),
            0,
            "base token: balance mismatch for auction house"
        );

        // Check prefunding amount
        (,,,,,,,,, uint256 lotPrefunding) = _auctionHouse.lotRouting(_lotId);
        assertEq(lotPrefunding, 0, "mismatch on prefunding");
    }

    function test_prefunded_givenPurchase_givenCuratorHasApproved()
        external
        givenLotIsPrefunded
        givenCuratorIsSet
        whenAuctionTypeIsAtomic
        whenAtomicAuctionModuleIsInstalled
        givenLotIsCreated
        givenLotHasStarted
        givenUserHasQuoteTokenBalance(_PURCHASE_AMOUNT)
        givenUserHasQuoteTokenAllowance(_PURCHASE_AMOUNT)
        givenPayoutMultiplier(_PAYOUT_MULTIPLIER)
        givenPurchase(_PURCHASE_AMOUNT, _PURCHASE_AMOUNT_OUT, _purchaseAuctionData)
        givenCuratorMaxFeeIsSet
        givenCuratorFeeIsSet
        givenSellerHasCuratorFeeBalance
        givenCuratorHasApproved
    {
        // Balance before
        uint256 sellerBalanceBefore = _baseToken.balanceOf(_SELLER);
        assertEq(sellerBalanceBefore, 0, "base token: balance mismatch for seller before");

        // No curator fee, since the purchase was before curator approval
        uint256 curatorFee = 0;

        // Cancel the lot
        vm.prank(_SELLER);
        _auctionHouse.cancel(_lotId);

        // Check the seller's balance
        assertEq(
            _baseToken.balanceOf(_SELLER),
            _LOT_CAPACITY - _PURCHASE_AMOUNT_OUT + _curatorMaxPotentialFee - curatorFee,
            "base token: seller balance mismatch"
        );
        assertEq(
            _baseToken.balanceOf(address(_auctionHouse)),
            0,
            "base token: balance mismatch for auction house"
        );

        // Check prefunding amount
        (,,,,,,,,, uint256 lotPrefunding) = _auctionHouse.lotRouting(_lotId);
        assertEq(lotPrefunding, 0, "mismatch on prefunding");
    }

    function test_prefunded_givenPurchase_givenCuratorHasApproved_givenPurchase()
        external
        givenLotIsPrefunded
        givenCuratorIsSet
        whenAuctionTypeIsAtomic
        whenAtomicAuctionModuleIsInstalled
        givenLotIsCreated
        givenLotHasStarted
        givenUserHasQuoteTokenBalance(_PURCHASE_AMOUNT)
        givenUserHasQuoteTokenAllowance(_PURCHASE_AMOUNT)
        givenPayoutMultiplier(_PAYOUT_MULTIPLIER)
        givenPurchase(_PURCHASE_AMOUNT, _PURCHASE_AMOUNT_OUT, _purchaseAuctionData)
        givenCuratorMaxFeeIsSet
        givenCuratorFeeIsSet
        givenSellerHasCuratorFeeBalance
        givenCuratorHasApproved
        givenUserHasQuoteTokenBalance(_PURCHASE_AMOUNT * 2)
        givenUserHasQuoteTokenAllowance(_PURCHASE_AMOUNT * 2)
        givenPurchase(_PURCHASE_AMOUNT * 2, _PURCHASE_AMOUNT_OUT * 2, _purchaseAuctionData)
    {
        // Balance before
        uint256 sellerBalanceBefore = _baseToken.balanceOf(_SELLER);
        assertEq(sellerBalanceBefore, 0, "base token: balance mismatch for seller before");

        // No curator fee, since the purchase was before curator approval
        uint256 curatorFee = _CURATOR_FEE_PERCENT * (_PURCHASE_AMOUNT_OUT * 2) / 1e5;

        // Cancel the lot
        vm.prank(_SELLER);
        _auctionHouse.cancel(_lotId);

        // Check the seller's balance
        assertEq(
            _baseToken.balanceOf(_SELLER),
            _LOT_CAPACITY - _PURCHASE_AMOUNT_OUT - (_PURCHASE_AMOUNT_OUT * 2)
                + _curatorMaxPotentialFee - curatorFee,
            "base token: seller balance mismatch"
        );
        assertEq(
            _baseToken.balanceOf(address(_auctionHouse)),
            0,
            "base token: balance mismatch for auction house"
        );

        // Check prefunding amount
        (,,,,,,,,, uint256 lotPrefunding) = _auctionHouse.lotRouting(_lotId);
        assertEq(lotPrefunding, 0, "mismatch on prefunding");
    }

    function test_prefunded_givenCuratorHasApproved_givenPurchase()
        external
        givenLotIsPrefunded
        givenCuratorIsSet
        whenAuctionTypeIsAtomic
        whenAtomicAuctionModuleIsInstalled
        givenLotIsCreated
        givenLotHasStarted
        givenSellerHasCuratorFeeBalance
        givenCuratorMaxFeeIsSet
        givenCuratorFeeIsSet
        givenCuratorHasApproved
        givenUserHasQuoteTokenBalance(_PURCHASE_AMOUNT)
        givenUserHasQuoteTokenAllowance(_PURCHASE_AMOUNT)
        givenPayoutMultiplier(_PAYOUT_MULTIPLIER)
        givenPurchase(_PURCHASE_AMOUNT, _PURCHASE_AMOUNT_OUT, _purchaseAuctionData)
    {
        // Balance before
        uint256 sellerBalanceBefore = _baseToken.balanceOf(_SELLER);
        assertEq(sellerBalanceBefore, 0, "base token: balance mismatch for seller before");

        uint256 curatorFee = _CURATOR_FEE_PERCENT * _PURCHASE_AMOUNT_OUT / 1e5;

        // Cancel the lot
        vm.prank(_SELLER);
        _auctionHouse.cancel(_lotId);

        // Check the seller's balance
        assertEq(
            _baseToken.balanceOf(_SELLER),
            _LOT_CAPACITY - _PURCHASE_AMOUNT_OUT + _curatorMaxPotentialFee - curatorFee,
            "base token: seller balance mismatch"
        );
        assertEq(
            _baseToken.balanceOf(address(_auctionHouse)),
            0,
            "base token: balance mismatch for auction house"
        );

        // Check prefunding amount
        (,,,,,,,,, uint256 lotPrefunding) = _auctionHouse.lotRouting(_lotId);
        assertEq(lotPrefunding, 0, "mismatch on prefunding");
    }
}
