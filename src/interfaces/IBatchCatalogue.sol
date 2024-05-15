// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

import {ICatalogue} from "src/interfaces/ICatalogue.sol";
import {IBatchAuction} from "src/interfaces/modules/IBatchAuction.sol";

interface IBatchCatalogue is ICatalogue {
    /// @notice Get the number of bids for a lot
    ///
    /// @param  lotId_  The lot ID
    /// @return         The number of bids
    function getNumBids(uint96 lotId_) external view returns (uint256);

    /// @notice Get the bid IDs from the given index
    ///
    /// @param  lotId_  The lot ID
    /// @param  start_  The index to start retrieving bid IDs from
    /// @param  count_  The number of bids to retrieve
    /// @return         The bid IDs
    function getBidIds(
        uint96 lotId_,
        uint256 start_,
        uint256 count_
    ) external view returns (uint64[] memory);

    /// @notice Get the bid ID at the given index
    ///
    /// @param  lotId_  The lot ID
    /// @param  index_  The index
    /// @return         The bid ID
    function getBidIdAtIndex(uint96 lotId_, uint256 index_) external view returns (uint64);

    /// @notice Get the claim data for a bid
    /// @notice This provides information on the outcome of a bid, independent of the claim status
    ///
    /// @param  lotId_  The lot ID
    /// @param  bidId_  The bid ID
    /// @return         The bid claim data
    function getBidClaim(
        uint96 lotId_,
        uint64 bidId_
    ) external view returns (IBatchAuction.BidClaim memory);
}
