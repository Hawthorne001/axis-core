/// SPDX-License-Identifier: APGL-3.0
pragma solidity 0.8.19;

import {Auction} from "src/modules/Auction.sol";
import {AtomicAuctionModule} from "src/modules/auctions/AtomicAuctionModule.sol";
import {AuctionHouse} from "src/bases/AuctionHouse.sol";
import {AtomicAuctionHouse} from "src/AtomicAuctionHouse.sol";
import {FeeManager} from "src/bases/FeeManager.sol";
import {Veecode, keycodeFromVeecode, Keycode} from "src/modules/Modules.sol";
import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";
import {ICallback} from "src/interfaces/ICallback.sol";

// TODO batch catalogue

/// @notice Contract that provides view functions for atomic Auctions
contract AtomicCatalogue {
    // ========== STATE VARIABLES ========== //
    /// @notice Address of the AuctionHouse contract
    address public auctionHouse;

    /// @notice     Fees are in basis points (3 decimals). 1% equals 1000.
    uint48 internal constant _FEE_DECIMALS = 1e5;

    constructor(address auctionHouse_) {
        auctionHouse = auctionHouse_;
    }

    // ========== AUCTION INFORMATION ========== //

    /// @notice     Gets the routing information for a given lot ID
    /// @dev        The function reverts if:
    ///             - The lot ID is invalid
    ///
    /// @param      lotId_  ID of the auction lot
    /// @return     routing Routing information for the auction lot
    function getRouting(uint96 lotId_) public view returns (AuctionHouse.Routing memory) {
        (
            address seller,
            ERC20 baseToken,
            ERC20 quoteToken,
            Veecode auctionReference,
            uint256 funding,
            ICallback callbacks,
            Veecode derivativeReference,
            bool wrapDerivative,
            bytes memory derivativeParams
        ) = AuctionHouse(auctionHouse).lotRouting(lotId_);

        return AuctionHouse.Routing({
            auctionReference: auctionReference,
            seller: seller,
            baseToken: baseToken,
            quoteToken: quoteToken,
            callbacks: callbacks,
            derivativeReference: derivativeReference,
            derivativeParams: derivativeParams,
            wrapDerivative: wrapDerivative,
            funding: funding
        });
    }

    function payoutFor(uint96 lotId_, uint256 amount_) external view returns (uint256) {
        AtomicAuctionModule module =
            AtomicAuctionModule(address(AtomicAuctionHouse(auctionHouse).getModuleForId(lotId_)));
        AuctionHouse.Routing memory routing = getRouting(lotId_);

        // Get protocol fee from FeeManager
        // TODO depending on whether this is a purchase or a bid, we should use different fee sources
        (uint48 protocolFee, uint48 referrerFee,) =
            FeeManager(auctionHouse).fees(keycodeFromVeecode(routing.auctionReference));

        // Calculate fees
        (uint256 toProtocol, uint256 toReferrer) =
            FeeManager(auctionHouse).calculateQuoteFees(protocolFee, referrerFee, true, amount_); // we assume there is a referrer to give a conservative amount

        // Get payout from module
        return module.payoutFor(lotId_, amount_ - uint96(toProtocol) - uint96(toReferrer));
    }

    function priceFor(uint96 lotId_, uint256 payout_) external view returns (uint256) {
        AtomicAuctionModule module =
            AtomicAuctionModule(address(AtomicAuctionHouse(auctionHouse).getModuleForId(lotId_)));
        AuctionHouse.Routing memory routing = getRouting(lotId_);

        // Get price from module (in quote token units)
        uint256 price = module.priceFor(lotId_, payout_);

        // Calculate fee estimate assuming there is a referrer and add to price
        price += _calculateFeeEstimate(keycodeFromVeecode(routing.auctionReference), true, price);

        return price;
    }

    function maxPayout(uint96 lotId_) external view returns (uint256) {
        AtomicAuctionModule module =
            AtomicAuctionModule(address(AtomicAuctionHouse(auctionHouse).getModuleForId(lotId_)));

        // No fees need to be considered here since an amount is not provided

        // Get max payout from module
        return module.maxPayout(lotId_);
    }

    function maxAmountAccepted(uint96 lotId_) external view returns (uint256) {
        AtomicAuctionModule module =
            AtomicAuctionModule(address(AtomicAuctionHouse(auctionHouse).getModuleForId(lotId_)));
        AuctionHouse.Routing memory routing = getRouting(lotId_);

        // Get max amount accepted from module
        uint256 maxAmount = module.maxAmountAccepted(lotId_);

        // Calculate fee estimate assuming there is a referrer and add to max amount
        maxAmount +=
            _calculateFeeEstimate(keycodeFromVeecode(routing.auctionReference), true, maxAmount);

        return maxAmount;
    }

    /// @notice    Returns whether the auction is currently accepting bids or purchases
    /// @dev       Auctions that have been created, but not yet started will return false
    function isLive(uint96 lotId_) external view returns (bool) {
        Auction module = AuctionHouse(auctionHouse).getModuleForId(lotId_);

        // Get isLive from module
        return module.isLive(lotId_);
    }

    function hasEnded(uint96 lotId_) external view returns (bool) {
        Auction module = AuctionHouse(auctionHouse).getModuleForId(lotId_);

        // Get hasEnded from module
        return module.hasEnded(lotId_);
    }

    function remainingCapacity(uint96 lotId_) external view returns (uint256) {
        Auction module = AuctionHouse(auctionHouse).getModuleForId(lotId_);

        // Get remaining capacity from module
        return module.remainingCapacity(lotId_);
    }

    // ========== INTERNAL UTILITY FUNCTIONS ========== //

    /// @notice Estimates fees for a `priceFor` or `maxAmountAccepted` calls
    function _calculateFeeEstimate(
        Keycode auctionType_,
        bool hasReferrer_,
        uint256 price_
    ) internal view returns (uint256 feeEstimate) {
        // In this case we have to invert the fee calculation
        // We provide a conservative estimate by assuming there is a referrer and rounding up
        (uint48 fee, uint48 referrerFee,) = FeeManager(auctionHouse).fees(auctionType_);
        if (hasReferrer_) fee += referrerFee;

        uint256 numer = price_ * _FEE_DECIMALS;
        uint256 denom = _FEE_DECIMALS - fee;

        return (numer / denom) + ((numer % denom == 0) ? 0 : 1); // round up if necessary
    }
}
