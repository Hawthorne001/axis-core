// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

import {IAuction} from "src/interfaces/IAuction.sol";

/// @title  IBatchAuction
/// @notice Interface for batch auctions
/// @dev    The implementing contract should define the following additional areas:
///         - Any un-implemented functions
///         - State variables for storage and configuration
interface IBatchAuction is IAuction {
    // ========== ERRORS ========== //

    error Auction_InvalidBidId(uint96 lotId, uint96 bidId);
    error Auction_NotBidder();

    // ========== DATA STRUCTURES ========== //

    /// @dev Only used in memory so doesn't need to be packed
    struct BidClaim {
        address bidder;
        address referrer;
        uint256 paid;
        uint256 payout;
        uint256 refund;
    }

    // ========== BATCH AUCTIONS ========== //

    /// @notice     Bid on an auction lot
    /// @dev        The implementing function should handle the following:
    ///             - Validate the bid parameters
    ///             - Store the bid data
    ///
    /// @param      lotId_          The lot id
    /// @param      bidder_         The bidder of the purchased tokens
    /// @param      referrer_       The referrer of the bid
    /// @param      amount_         The amount of quote tokens to bid
    /// @param      auctionData_    The auction-specific data
    function bid(
        uint96 lotId_,
        address bidder_,
        address referrer_,
        uint256 amount_,
        bytes calldata auctionData_
    ) external returns (uint64 bidId);

    /// @notice     Refund a bid
    /// @dev        The implementing function should handle the following:
    ///             - Validate the bid parameters
    ///             - Authorize `caller_`
    ///             - Update the bid data
    ///
    /// @param      lotId_      The lot id
    /// @param      bidId_      The bid id
    /// @param      index_      The index of the bid ID in the auction's bid list
    /// @param      caller_     The caller
    /// @return     refund   The amount of quote tokens to refund
    function refundBid(
        uint96 lotId_,
        uint64 bidId_,
        uint256 index_,
        address caller_
    ) external returns (uint256 refund);

    /// @notice     Claim multiple bids
    /// @dev        The implementing function should handle the following:
    ///             - Validate the bid parameters
    ///             - Update the bid data
    ///
    /// @param      lotId_          The lot id
    /// @param      bidIds_         The bid ids
    /// @return     bidClaims       The bid claim data
    /// @return     auctionOutput   The auction-specific output
    function claimBids(
        uint96 lotId_,
        uint64[] calldata bidIds_
    ) external returns (BidClaim[] memory bidClaims, bytes memory auctionOutput);

    /// @notice     Settle a batch auction lot with on-chain storage and settlement
    /// @dev        The implementing function should handle the following:
    ///             - Validate the lot parameters
    ///             - Determine the winning bids
    ///             - Update the lot data
    ///
    /// @param      lotId_          The lot id
    /// @return     totalIn         Total amount of quote tokens from bids that were filled
    /// @return     totalOut        Total amount of base tokens paid out to winning bids
    /// @return     auctionOutput   Custom data returned by the auction module
    function settle(uint96 lotId_)
        external
        returns (uint256 totalIn, uint256 totalOut, bytes memory auctionOutput);

    /// @notice     Claim the seller proceeds from a settled auction lot
    /// @dev        The implementing function should handle the following:
    ///             - Validate the lot parameters
    ///             - Update the lot data
    ///
    /// @param      lotId_          The lot id
    /// @return     purchased       The amount of quote tokens purchased
    /// @return     sold            The amount of base tokens sold
    /// @return     capacity        The original capacity of the lot
    function claimProceeds(uint96 lotId_)
        external
        returns (uint256 purchased, uint256 sold, uint256 capacity);
}
