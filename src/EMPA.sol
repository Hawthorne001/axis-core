/// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.19;

import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";
import {Transfer} from "src/lib/Transfer.sol";
import {MaxPriorityQueue, Queue} from "src/lib/MaxPriorityQueue.sol";

import {Auctioneer} from "src/bases/Auctioneer.sol";
import {FeeManager} from "src/bases/FeeManager.sol";

import {CondenserModule} from "src/modules/Condenser.sol";
import {DerivativeModule} from "src/modules/Derivative.sol";

import {
    Veecode, fromVeecode, Keycode, keycodeFromVeecode, WithModules, Module
} from "src/modules/Modules.sol";

import {IHooks} from "src/interfaces/IHooks.sol";
import {IAllowlist} from "src/interfaces/IAllowlist.sol";

/// @title      Router
/// @notice     An interface to define the routing of transactions to the appropriate auction module
abstract contract Router {
    // ========== DATA STRUCTURES ========== //

    /// @notice     Parameters used by the bid function
    /// @dev        This reduces the number of variables in scope for the bid function
    ///
    /// @param      lotId               Lot ID
    /// @param      referrer            Address of referrer
    /// @param      amount              Amount of quoteToken to purchase with (in native decimals)
    /// @param      auctionData         Custom data used by the auction module
    /// @param      allowlistProof      Proof of allowlist inclusion
    /// @param      permit2Data_        Permit2 approval for the quoteToken (abi-encoded Permit2Approval struct)
    struct BidParams {
        uint96 lotId;
        address referrer;
        uint256 amount;
        bytes encryptedAmountOut;
        bytes allowlistProof;
        bytes permit2Data;
    }

    // ========== BATCH AUCTIONS ========== //

    /// @notice     Bid on a lot in a batch auction
    /// @dev        The implementing function must perform the following:
    ///             1. Validate the bid
    ///             2. Store the bid
    ///             3. Transfer the amount of quote token from the bidder
    ///
    /// @param      params_         Bid parameters
    /// @return     bidId           Bid ID
    function bid(BidParams memory params_) external virtual returns (uint96 bidId);

    /// @notice     Refund a bid on a lot in a batch auction
    /// @dev        The implementing function must perform the following:
    ///             1. Validate the bid
    ///             2. Pass the request to the auction module to validate and update data
    ///             3. Send the refund to the bidder
    ///
    /// @param      lotId_          Lot ID
    /// @param      bidId_          Bid ID
    function refundBid(uint96 lotId_, uint96 bidId_) external virtual;

    /// @notice     Settle a batch auction
    /// @notice     This function is used for versions with on-chain storage and bids and local settlement
    /// @dev        The implementing function must perform the following:
    ///             1. Validate the lot
    ///             2. Pass the request to the auction module to calculate winning bids
    ///             3. Collect the payout from the auction owner (if not pre-funded)
    ///             4. Send the payout to each bidder
    ///             5. Send the payment to the auction owner
    ///             6. Allocate protocol, referrer and curator fees
    ///
    /// @param      lotId_          Lot ID
    function settle(uint96 lotId_) external virtual;

    function claim(uint96 lotId_, uint96 bidId_) external virtual;
}

/// @title      Encrypted Marginal Price Auction (EMPA)
contract EncryptedMarginalPriceAuction is WithModules, Router, FeeManager {
    using MaxPriorityQueue for Queue;

    // ========== ERRORS ========== //

    error AmountLessThanMinimum();
    error InvalidBidder(address bidder_);
    error Broken_Invariant();
    error InvalidParams();
    error InvalidLotId(uint96 id_);
    error InvalidState();
    error InvalidHook();

    /// @notice     Used when the caller is not permitted to perform that action
    error NotPermitted(address caller_);

    error Auction_BidDoesNotExist();
    error Auction_AlreadyCancelled();
    error Auction_WrongState();
    error Auction_NotLive();
    error Auction_NotConcluded();
    error Auction_InvalidDecrypt();
    error Bid_WrongState();

    error Auction_MarketNotActive(uint96 lotId);

    error Auction_MarketActive(uint96 lotId);

    error Auction_InvalidStart(uint48 start_, uint48 minimum_);

    error Auction_InvalidDuration(uint48 duration_, uint48 minimum_);

    error Auction_InvalidLotId(uint96 lotId);

    error Auction_InvalidBidId(uint96 lotId, uint96 bidId);

    error Auction_OnlyMarketOwner();
    error Auction_AmountLessThanMinimum();
    error Auction_NotEnoughCapacity();
    error Auction_InvalidParams();
    error Auction_NotAuthorized();
    error Auction_NotImplemented();

    error Auction_NotBidder();

    // ========= EVENTS ========= //

    event AuctionCreated(
        uint96 indexed lotId, Veecode indexed auctionRef, address baseToken, address quoteToken
    );
    event AuctionCancelled(uint96 indexed lotId, Veecode indexed auctionRef);
    event BidSubmitted(uint96 indexed lotId, uint96 indexed bidId, address indexed bidder, uint256 amount);
    event BidDecrypted(
        uint96 indexed lotId, uint96 indexed bidId, uint256 amountIn, uint256 amountOut
    );
    event Curated(uint96 indexed lotId, address indexed curator);
    event RefundBid(uint96 indexed lotId, uint96 indexed bidId, address indexed bidder); // replace or merge with claim?
    event Settle(uint96 indexed lotId);
    

    // ========= DATA STRUCTURES ========== //

    /// @notice     Auction routing information for a lot
    /// @dev        Variables arranged to maximize packing
    /// @param      baseToken           Token provided by seller
    /// @param      owner               ID of Lot owner
    /// @param      quoteToken          Token to accept as payment
    /// @param      curator             ID of the proposed curator
    /// @param      curated             Whether the curator has approved the auction
    /// @param      hooks               (optional) Address to call for any hooks to be executed
    /// @param      allowlist           (optional) Contract that implements an allowlist for the auction lot
    /// @param      derivativeReference (optional) Derivative module, represented by its Veecode
    /// @param      wrapDerivative      (optional) Whether to wrap the derivative in a ERC20 token instead of the native ERC6909 format
    /// @param      derivativeParams    (optional) abi-encoded data to be used to create payout derivatives on a purchase
    struct Routing {
        ERC20 baseToken;
        uint64 ownerId;
        ERC20 quoteToken;
        uint64 curatorId;
        bool curated;
        IHooks hooks;
        IAllowlist allowlist;
        Veecode derivativeReference;
        bool wrapDerivative;
        bytes derivativeParams;
    }

    /// @notice     Auction routing information provided as input parameters
    /// @dev        After validation, this information is stored in the Routing struct
    ///
    /// @param      baseToken       Token provided by seller
    /// @param      quoteToken      Token to accept as payment
    /// @param      curator         (optional) Address of the proposed curator
    /// @param      hooks           (optional) Address to call for any hooks to be executed
    /// @param      allowlist       (optional) Contract that implements an allowlist for the auction lot
    /// @param      allowlistParams (optional) abi-encoded data to be used to register the auction on the allowlist
    /// @param      derivativeType  (optional) Derivative type, represented by the Keycode for the derivative submodule
    /// @param      derivativeParams (optional) abi-encoded data to be used to create payout derivatives on a purchase. The format of this is dependent on the derivative module.
    struct RoutingParams {
        ERC20 baseToken;
        ERC20 quoteToken;
        address curator;
        IHooks hooks;
        IAllowlist allowlist;
        bytes allowlistParams;
        Keycode derivativeType;
        bytes derivativeParams;
    }

    enum AuctionStatus {
        Created,
        Decrypted,
        Settled
    }

    enum BidStatus {
        Submitted,
        Decrypted,
        Claimed,
        Refunded
    }

    /// @notice        Struct containing encrypted bid data
    ///
    /// @param         status              The status of the bid
    /// @param         bidder              The address of the bidder
    /// @param         recipient           The address of the recipient
    /// @param         referrer            The address of the referrer
    /// @param         amount              The amount of the bid
    /// @param         minAmountOut        The minimum amount out (not set until the bid is decrypted)
    struct Bid {
        BidStatus status;
        uint64 bidderId;
        uint64 referrerId;
        uint96 amount;
        uint96 minAmountOut;
    }

    /// @notice        Struct containing decrypted bid data
    ///
    /// @param         amountOut           The amount out
    /// @param         seed                The seed used to encrypt the amount out
    struct Decrypt {
        uint96 amountOut;
        bytes32 seed;
    }

    /// @notice        Struct containing auction data
    ///
    /// @param         status              The status of the auction
    /// @param         nextDecryptIndex    The index of the next bid to decrypt
    /// @param         nextBidId           The ID of the next bid to be submitted
    /// @param         minimumPrice        The minimum price that the auction can settle at (in terms of quote token)
    /// @param         minFilled           The minimum amount of capacity that must be filled to settle the auction
    /// @param         minBidSize          The minimum amount that can be bid for the lot, determined by the percentage of capacity that must be filled per bid times the min bid price
    /// @param         publicKeyModulus    The public key modulus used to encrypt bids
    /// @param         bidIds              The list of bid IDs to decrypt in order of submission, excluding cancelled bids
    struct BidData {
        uint64 nextBidId;
        uint64 nextDecryptIndex;
        uint96 marginalPrice;
        bytes publicKeyModulus;
        uint64[] bidIds;
        mapping(uint64 bidId => Bid) bids;
        mapping(uint64 bidId => bytes) encryptedBids;
        Queue decryptedBids;
    }

    /// @notice     Core data for an auction lot
    ///
    /// @param      start               The timestamp when the auction starts
    /// @param      conclusion          The timestamp when the auction ends
    /// @param      quoteTokenDecimals  The quote token decimals
    /// @param      baseTokenDecimals   The base token decimals
    /// @param      capacity            The capacity of the lot
    struct Lot {
        uint96 minimumPrice; // 12 +
        uint96 capacity; // 12 +
        uint8 quoteTokenDecimals; // 1 +
        uint8 baseTokenDecimals; // 1 +
        uint48 start; // 6 = 32 - end of slot 1
        uint48 conclusion; // 6 +
        AuctionStatus status; // 1 +
        uint96 minFilled; // 12 +
        uint96 minBidSize; // 12 = 31 - end of slot 2
    }

    /// @notice     Parameters when creating an auction lot
    ///
    /// @param      start           The timestamp when the auction starts
    /// @param      duration        The duration of the auction (in seconds)
    /// @param      minFillPercent_     The minimum percentage of the lot capacity that must be filled for the auction to settle (scale: `_ONE_HUNDRED_PERCENT`)
    /// @param      minBidPercent_      The minimum percentage of the lot capacity that must be bid for each bid (scale: `_ONE_HUNDRED_PERCENT`)
    /// @param      capacityInQuote Whether or not the capacity is in quote tokens
    /// @param      capacity        The capacity of the lot
    /// @param      minimumPrice_       The minimum price that the auction can settle at (in terms of quote token)
    /// @param      publicKeyModulus_   The public key modulus used to encrypt bids
    struct AuctionParams {
        uint48 start;
        uint48 duration;
        uint24 minFillPercent;
        uint24 minBidPercent;
        uint256 capacity;
        uint256 minimumPrice;
        bytes publicKeyModulus;
    }

    // ========= STATE ========== //

    /// @notice Constant for percentages
    /// @dev    1% = 1_000 or 1e3. 100% = 100_000 or 1e5.
    uint24 internal constant _ONE_HUNDRED_PERCENT = 100_000;
    uint24 internal constant _MIN_BID_PERCENT = 10; // 0.01%
    uint24 internal constant _PUB_KEY_EXPONENT = 65_537;

    uint64 internal _nextUserId;

    address internal immutable _PERMIT2;

    /// @notice Minimum auction duration in seconds
    uint48 public minAuctionDuration;

    /// @notice     Counter for auction lots
    uint96 public lotCounter;

    // We use this to store addresses once and reference them using a shorter identifier
    mapping(address user => uint64) public userIds;

    /// @notice     General information pertaining to auction lots
    mapping(uint96 id => Lot lot) public lotData;

    /// @notice     Lot routing information
    mapping(uint96 lotId => Routing) public lotRouting;

    /// @notice     Bid data for a lot
    mapping(uint96 lotId => BidData) public bidData;

    /// @notice     Mapping derivative references to the condenser that is used to pass data between them
    mapping(Veecode derivativeRef => Veecode condenserRef) public
        condensers;

    // ========== CONSTRUCTOR ========== //

    constructor(
        address owner_,
        address protocol_,
        address permit2_
    ) FeeManager(protocol_) WithModules(owner_) {
        _PERMIT2 = permit2_;
        _nextUserId = 1;
    }

    // ========== USER MANAGEMENT ========== //

    function _getUserId(address user) internal returns (uint64) {
        uint64 id = userIds[user];
        if (id == 0) {
            id = _nextUserId++;
            userIds[user] = id;
        }
        return id;
    }

    // ========== AUCTION MANAGEMENT ========== //

    /// @notice     Creates a new auction lot
    /// @dev        The function reverts if:
    ///             - The module for the auction type is not installed
    ///             - The auction type is sunset
    ///             - The base token or quote token decimals are not within the required range
    ///             - Validation for the auction parameters fails
    ///             - The module for the optional specified derivative type is not installed
    ///             - Validation for the optional specified derivative type fails
    ///             - Registration for the optional allowlist fails
    ///             - The optional specified hooks contract is not a contract
    ///             - The condenser module is not installed or is sunset
    ///             - re-entrancy is detected
    ///
    /// @param      routing_    Routing information for the auction lot
    /// @param      params_     Auction parameters for the auction lot
    /// @return     lotId       ID of the auction lot
    function auction(
        RoutingParams calldata routing_,
        AuctionParams calldata params_
    ) external nonReentrant returns (uint96 lotId) {
        // Validate routing parameters

        if (address(routing_.baseToken) == address(0) || address(routing_.quoteToken) == address(0))
        {
            revert InvalidParams();
        }

        // Confirm tokens are within the required decimal range
        uint8 baseTokenDecimals = routing_.baseToken.decimals();
        uint8 quoteTokenDecimals = routing_.quoteToken.decimals();

        if (
            baseTokenDecimals < 6 || baseTokenDecimals > 18 || quoteTokenDecimals < 6
                || quoteTokenDecimals > 18
        ) revert InvalidParams();

        // Increment lot count and get ID
        lotId = lotCounter++;

        // Start time must be zero or in the future
        if (params_.start > 0 && params_.start < uint48(block.timestamp)) {
            revert Auction_InvalidStart(params_.start, uint48(block.timestamp));
        }

        // Duration must be at least min duration
        if (params_.duration < minAuctionDuration) {
            revert Auction_InvalidDuration(params_.duration, minAuctionDuration);
        }

        // Create core market data
        {
            Lot storage lot = lotData[lotId];
            lot.start = params_.start == 0 ? uint48(block.timestamp) : params_.start;
            lot.conclusion = lot.start + params_.duration;
            lot.quoteTokenDecimals = quoteTokenDecimals;
            lot.baseTokenDecimals = baseTokenDecimals;
            lot.capacity = params_.capacity;
        }

        // Validate params

        // minFillPercent must be less than or equal to 100%
        if (params_.minFillPercent > _ONE_HUNDRED_PERCENT) revert Auction_InvalidParams();

        // minBidPercent must be greater than or equal to the global min and less than or equal to 100%
        if (
            params_.minBidPercent < _MIN_BID_PERCENT
                || params_.minBidPercent > _ONE_HUNDRED_PERCENT
        ) {
            revert Auction_InvalidParams();
        }

        // publicKeyModulus must be 1024 bits (128 bytes)
        if (params_.publicKeyModulus.length != 128) revert Auction_InvalidParams();

        // Store auction data
        AuctionData storage data = auctionData[lotId];
        data.minimumPrice = params_.minimumPrice;
        data.minFilled = (params_.capacity * params_.minFillPercent) / _ONE_HUNDRED_PERCENT;
        data.minBidSize = (params_.capacity * params_.minBidPercent * params_.minimumPrice ) / (_ONE_HUNDRED_PERCENT * 10**baseTokenDecimals);
        data.publicKeyModulus = params_.publicKeyModulus;


        // Get user IDs for owner and curator
        Routing storage routing = lotRouting[lotId];
        {
            uint64 ownerId = _getUserId(msg.sender);
            uint64 curatorId = routing_.curator != address(0) ? _getUserId(routing_.curator) : 0;

            // Store routing information
            routing.baseToken = routing_.baseToken;
            routing.ownerId = ownerId;
            routing.quoteToken = routing_.quoteToken;
            if (curatorId != 0) routing.curatorId = curatorId;
        }

        // Derivative
        if (fromKeycode(routing_.derivativeType) != bytes5("")) {
            // Load derivative module, this checks that it is installed.
            DerivativeModule derivativeModule =
                DerivativeModule(_getLatestModuleIfActive(routing_.derivativeType));
            Veecode derivativeRef = derivativeModule.VEECODE();

            // Check that the module for the derivative type is valid
            if (derivativeModule.TYPE() != Module.Type.Derivative) {
                revert InvalidParams();
            }

            // Call module validate function to validate implementation-specific data
            if (!derivativeModule.validate(address(routing.baseToken), routing_.derivativeParams)) {
                revert InvalidParams();
            }

            // Store derivative information
            routing.derivativeReference = derivativeRef;
            routing.derivativeParams = routing_.derivativeParams;
        }

        // Condenser
        {
            // Get condenser reference
            Veecode condenserRef = condensers[routing.derivativeReference];

            // Check that the module for the condenser type is valid
            if (fromVeecode(condenserRef) != bytes7(0)) {
                if (
                    CondenserModule(_getModuleIfInstalled(condenserRef)).TYPE()
                        != Module.Type.Condenser
                ) revert InvalidParams();

                // Check module status
                Keycode moduleKeycode = keycodeFromVeecode(condenserRef);
                if (getModuleStatus[moduleKeycode].sunset == true) {
                    revert ModuleIsSunset(moduleKeycode);
                }
            }
        }

        // If allowlist is being used, validate the allowlist data and register the auction on the allowlist
        if (address(routing_.allowlist) != address(0)) {
            // Check that it is a contract
            // It is assumed that the user will do validation of the allowlist
            if (address(routing_.allowlist).code.length == 0) revert InvalidParams();

            // Register with the allowlist
            routing_.allowlist.register(lotId, routing_.allowlistParams);

            // Store allowlist information
            routing.allowlist = routing_.allowlist;
        }

        // Prefund the auction
        // If hooks are being used, validate the hooks data and then call the pre-auction create hook
        if (address(routing_.hooks) != address(0)) {
            // Check that it is a contract
            // It is assumed that the user will do validation of the hooks
            if (address(routing_.hooks).code.length == 0) revert InvalidParams();

            // Store hooks information
            routing.hooks = routing_.hooks;
    
            uint256 balanceBefore = routing_.baseToken.balanceOf(address(this));

            // The pre-auction create hook should transfer the base token to this contract
            routing_.hooks.preAuctionCreate(lotId);

            // Check that the hook transferred the expected amount of base tokens
            if (routing_.baseToken.balanceOf(address(this)) < balanceBefore + params_.capacity) {
                revert InvalidHook();
            }
        }
        // Otherwise fallback to a standard ERC20 transfer
        else {
            Transfer.transferFrom(
                routing_.baseToken, msg.sender, address(this), params_.capacity, true
            );
        }

        emit AuctionCreated(
            lotId, address(routing_.baseToken), address(routing_.quoteToken)
        );
    }

    /// @notice     Cancels an auction lot
    /// @dev        This function performs the following:
    ///             - Checks that the lot ID is valid
    ///             - Checks that caller is the auction owner
    ///             - Calls the auction module to validate state, update records and determine the amount to be refunded
    ///             - If prefunded, sends the refund of payout tokens to the owner
    ///
    ///             The function reverts if:
    ///             - The lot ID is invalid
    ///             - The caller is not the auction owner
    ///             - The respective auction module reverts
    ///             - The transfer of payout tokens fails
    ///             - re-entrancy is detected
    ///
    /// @param      lotId_      ID of the auction lot
    function cancel(uint96 lotId_) external nonReentrant {
        // Validation
        _isLotValid(lotId_);

        Routing storage routing = lotRouting[lotId_];

        // Check ownership
        if (msg.sender != routing.owner) revert NotPermitted(msg.sender);

        // Validation
        _revertIfLotInvalid(lotId_);
        _revertIfLotConcluded(lotId_);

        // Call internal closeAuction function to update any other required parameters
        _cancelAuction(lotId_);

        // Update lot
        Lot storage lot = lotData[lotId_];

        lot.conclusion = uint48(block.timestamp);
        lot.capacity = 0;

        // If the auction is prefunded and supported, transfer the remaining capacity to the owner
        if (routing.prefunding > 0) {
            uint256 prefunding = routing.prefunding;

            // Set to 0 before transfer to avoid re-entrancy
            lotRouting[lotId_].prefunding = 0;

            // Transfer payout tokens to the owner
            Transfer.transfer(routing.baseToken, routing.owner, prefunding, false);
        }

        emit AuctionCancelled(lotId_, routing.auctionReference);
    }

    /// @notice     Determines if `caller_` is allowed to purchase/bid on a lot.
    ///             If no allowlist is defined, this function will return true.
    ///
    /// @param      allowlist_       Allowlist contract
    /// @param      lotId_           Lot ID
    /// @param      caller_          Address of caller
    /// @param      allowlistProof_  Proof of allowlist inclusion
    /// @return     bool             True if caller is allowed to purchase/bid on the lot
    function _isAllowed(
        IAllowlist allowlist_,
        uint96 lotId_,
        address caller_,
        bytes memory allowlistProof_
    ) internal view returns (bool) {
        if (address(allowlist_) == address(0)) {
            return true;
        } else {
            return allowlist_.isAllowed(lotId_, caller_, allowlistProof_);
        }
    }

    // ========== BATCH AUCTIONS ========== //

    /// @inheritdoc Router
    /// @dev        This function reverts if:
    ///             - lotId is invalid
    ///             - the bidder is not on the optional allowlist
    ///             - the auction module reverts when creating a bid
    ///             - the quote token transfer fails
    ///             - re-entrancy is detected
    function bid(BidParams memory params_) external override nonReentrant returns (uint96) {
        _isLotValid(params_.lotId);

        // Load routing data for the lot
        Routing memory routing = lotRouting[params_.lotId];

        // Determine if the bidder is authorized to bid
        if (!_isAllowed(routing.allowlist, params_.lotId, msg.sender, params_.allowlistProof)) {
            revert InvalidBidder(msg.sender);
        }

        // Record the bid on the auction module
        // The module will determine if the bid is valid - minimum bid size, minimum price, auction status, etc
        uint96 bidId = getModuleForId(params_.lotId).bid(
            params_.lotId,
            msg.sender,
            params_.referrer,
            params_.amount,
            params_.auctionData
        );

        // Transfer the quote token from the bidder
        _collectPayment(
            params_.lotId,
            params_.amount,
            routing.quoteToken,
            routing.hooks,
            Transfer.decodePermit2Approval(params_.permit2Data)
        );

        // Emit event
        emit Bid(params_.lotId, bidId, msg.sender, params_.amount);

        return bidId;
    }

    /// @inheritdoc Router
    /// @dev        This function reverts if:
    ///             - the lot ID is invalid
    ///             - the auction module reverts when cancelling the bid
    ///             - re-entrancy is detected
    function refundBid(uint96 lotId_, uint96 bidId_) external override nonReentrant {
        _isLotValid(lotId_);

        // Refund the bid on the auction module
        // The auction module is responsible for validating the bid and authorizing the caller
        uint256 refundAmount = getModuleForId(lotId_).refundBid(lotId_, bidId_, msg.sender);

        // Transfer the quote token to the bidder
        // The ownership of the bid has already been verified by the auction module
        Transfer.transfer(lotRouting[lotId_].quoteToken, msg.sender, refundAmount, false);

        // Emit event
        emit RefundBid(lotId_, bidId_, msg.sender);
    }

    /// @inheritdoc Router
    /// @dev        This function handles the following:
    ///             - Settles the auction on the auction module
    ///             - Calculates the payout amount, taking partial fill into consideration
    ///             - Calculates the fees taken on the quote token
    ///             - Collects the payout from the auction owner (if necessary)
    ///             - Sends the payout to each bidder
    ///             - Sends the payment to the auction owner
    ///             - Sends the refund to the bidder if the last bid was a partial fill
    ///             - Refunds any unused base token to the auction owner
    ///
    ///             This function reverts if:
    ///             - the lot ID is invalid
    ///             - the auction module reverts when settling the auction
    ///             - transferring the quote token to the auction owner fails
    ///             - collecting the payout from the auction owner fails
    ///             - sending the payout to each bidder fails
    ///             - re-entrancy is detected
    function settle(uint96 lotId_) external override nonReentrant {
        // Validation
        _isLotValid(lotId_);

        // Settle the auction
        // Check that auction is in the right state for settlement
        if (auctionData[lotId_].status != AuctionStatus.Decrypted) revert Auction_WrongState();

        // Calculate marginal price and number of winning bids
        // Cache capacity and scaling values
        // Capacity is always in base token units for this auction type
        uint256 capacity = lotData[lotId_].capacity;
        uint256 baseScale = 10 ** lotData[lotId_].baseTokenDecimals;
        uint256 minimumPrice = auctionData[lotId_].minimumPrice;

        // Iterate over bid queue (sorted in descending price) to calculate the marginal clearing price of the auction
        Queue storage queue = lotSortedBids[lotId_];
        uint256 numBids = queue.getNumBids();
        uint256 totalAmountIn;
        uint256 lastPrice;
        uint256 capacityExpended;
        uint64 partialFillBidId;
        for (uint256 i = 0; i < numBids; i++) {
            // Load bid info (in quote token units)
            uint64 bidId = queue.getMaxId();
            QueueBid memory qBid = queue.delMax();

            // A bid can be considered if:
            // - the bid price is greater than or equal to the minimum
            // - previous bids did not fill the capacity
            //
            // There is no need to check if the bid is the minimum bid size, as this was checked during decryption

            // If the price is below the minimum price, the previous price is the marginal price
            if (price < minimumPrice) {
                marginalPrice = lastPrice;
                numWinningBids = i;
                break;
            }

            // The current price will now be considered, so we can set this
            lastPrice = price;

            // Increment total amount in
            totalAmountIn += qBid.amountIn;

            // Determine total capacity expended at this price (in base token units)
            // quote scale * base scale / quote scale = base scale
            capacityExpended = (totalAmountIn * baseScale) / price;

            // If total capacity expended is greater than or equal to the capacity, we have found the marginal price
            if (capacityExpended >= capacity) {
                marginalPrice = price;
                numWinningBids = i + 1;
                if (capacityExpended > capacity) {
                    partialFillBidId = bidId;
                }
                break;
            }

            // If we have reached the end of the queue, we have found the marginal price and the maximum capacity that can be filled
            if (i == numBids - 1) {
                marginalPrice = price;
                numWinningBids = numBids;
            }
        }

        // Delete the rest of the decrypted bids queue for a gas refund
        delete queue;
        
        // Determine if the auction can be filled, if so settle the auction, otherwise refund the seller
        // We set the status as settled either way to denote this function has been executed
        lotData[lotId_].status = AuctionStatus.Settled;
        // Auction cannot be settled if the total filled is less than the minimum filled
        // or if the marginal price is less than the minimum price
        if (capacityExpended >= lotData[lotId_].minFilled && marginalPrice >= lotData[lotId_].minimumPrice) {
            // Auction can be settled at the marginal price if we reach this point
            bidData[lotId_].marginalPrice = marginalPrice;

            // If there is a partially filled bid, send proceeds and refund to that bidder now
            if (partifillBidId != 0) {
                // Load bid data
                Bid storage _bid = bidData[lotId_].bids[partialFillBidId];

                // Calculate the payout and refund amounts
                uint256 fullFill = (_bid.amountIn * baseScale) / marginalPrice;
                uint256 payout = fullFill - (capacityExpended - capacity);
                uint256 refundAmount = (_bid.amountIn * payout) / fullFill;

                // Set bid as claimed
                _bid.status = BidStatus.Claimed;

                // Allocate quote and protocol fees for bid
                _allocateQuoteFees(lotId_, routing.quoteToken, _bid.amountIn - refundAmount);

                // Send refund and payout to the bidder
                address bidder = _getUserId(_bid.bidderId);
                Transfer.transfer(routing.quoteToken, bidder, refundAmount, false);
                _sendPayout(lotId_, bidder, payout, routing, auctionOutput);
            }

            // Calculate the referrer and protocol fees for the amount in
            // Fees are not allocated until the user claims their payout so that we don't have to iterate through them here
            // If a referrer is not set, that portion of the fee defaults to the protocol
            uint256 totalAmountInLessFees = totalAmountIn - _calculateQuoteFees(totalAmountIn, routing.quoteToken);

            // Send payment in bulk to auction owner
            _sendPayment(_getUserId(routing.ownerId), totalAmountInLessFees, routing.quoteToken, routing.hooks);

            // If capacity expended is less than the total capacity, refund the remaining capacity to the seller
            if (capacityExpended < capacity) {
                address owner = _getUserId(routing.ownerId);
                Transfer.transfer(routing.baseToken, owner, capacity - capacityExpended, false);
            }

            // Calculate and send curator fee to curator (if applicable)
            address curator = _getUserId(routing.curatorId);
            uint256 curatorFee = _calculatePayoutFees(
                curator,
                capacityExpended > capacity ? capacity : capacityExpended
            );
            if (curatorFee > 0) _sendPayout(lotId_, curator, curatorFee, routing, auctionOutput);
            
        } else {
            // Auction cannot be settled if we reach this point
            // Marginal price is not set for the auction so the system knows all bids should be refunded

            // Refund the capacity to the seller, no fees are taken
            address owner = _getUserId(lotRouting[lotId_].ownerId);
            Transfer.transfer(lotRouting[lotId_].baseToken, owner, capacity, false);
        }

        // Emit event
        emit Settle(lotId_);
    }

    function claim(uint96 lotId_, uint96 bidId_) external override nonReentrant {
        // Validation
        _isLotValid(lotId_);
        // TODO
        // hasn't claimed yet
        // hasn't been refunded
        // lot has been settled

        // Logic
        // Get the bid and compare to settled auction price
        // If the bid price is greater than the settled price, then payout expected amount
        // If the bid price is equal to the settled price, then check if bid is partially filled, then payout and refund as applicable
        // If the bid price is less than the settled price, then refund the bid amount

        // Emit event
        emit Claim(lotId_, bidId_);
    }

    // ========== CURATION ========== //

    /// @notice     Accept curation request for a lot.
    /// @notice     Access controlled. Must be proposed curator for lot.
    /// @dev        This function reverts if:
    ///             - the lot ID is invalid
    ///             - the caller is not the proposed curator
    ///             - the auction has ended or been cancelled
    ///             - the curator fee is not set
    ///             - the auction is prefunded and the fee cannot be collected
    ///             - re-entrancy is detected
    ///
    /// @param     lotId_       Lot ID
    function curate(uint96 lotId_) external nonReentrant {
        _isLotValid(lotId_);

        Routing storage routing = lotRouting[lotId_];
        Curation storage curation = lotCuration[lotId_];
        Keycode auctionType = keycodeFromVeecode(routing.auctionReference);

        // Check that the caller is the proposed curator
        if (msg.sender != curation.curator) revert NotPermitted(msg.sender);

        // Check that the curator has not already approved the auction
        if (curation.curated) revert InvalidState();

        // Check that the auction has not ended or been cancelled
        AuctionModule module = getModuleForId(lotId_);
        if (module.hasEnded(lotId_) == true) revert InvalidState();

        // Check that the curator fee is set
        if (fees[auctionType].curator[msg.sender] == 0) revert InvalidFee();

        // Set the curator as approved
        curation.curated = true;

        // If the auction is pre-funded, transfer the fee amount from the owner
        if (routing.prefunding > 0) {
            // Calculate the fee amount based on the remaining capacity (must be in base token if auction is pre-funded)
            uint256 fee =
                _calculatePayoutFees(auctionType, msg.sender, module.remainingCapacity(lotId_));

            // Increment the prefunding
            routing.prefunding += fee;

            // Don't need to check for fee on transfer here because it was checked on auction creation
            Transfer.transferFrom(routing.baseToken, routing.owner, address(this), fee, false);
        }

        // Emit event that the lot is curated by the proposed curator
        emit Curated(lotId_, msg.sender);
    }

    // ========== ADMIN FUNCTIONS ========== //

    /// @inheritdoc FeeManager
    function setFee(Keycode auctionType_, FeeType type_, uint48 fee_) external override onlyOwner {
        // Check that the fee is a valid percentage
        if (fee_ > _FEE_DECIMALS) revert InvalidFee();

        // Set fee based on type
        // TODO should we have hard-coded maximums for these fees?
        // Or a combination of protocol and referrer fee since they are both in the quoteToken?
        if (type_ == FeeType.Protocol) {
            fees[auctionType_].protocol = fee_;
        } else if (type_ == FeeType.Referrer) {
            fees[auctionType_].referrer = fee_;
        } else if (type_ == FeeType.MaxCurator) {
            fees[auctionType_].maxCuratorFee = fee_;
        }
    }

    /// @inheritdoc FeeManager
    function setProtocol(address protocol_) external override onlyOwner {
        _protocol = protocol_;
    }

    // ========== TOKEN TRANSFERS ========== //

    /// @notice     Collects payment of the quote token from the user
    /// @dev        This function handles the following:
    ///             1. Calls the pre hook on the hooks contract (if provided)
    ///             2. Transfers the quote token from the user
    ///             2a. Uses Permit2 to transfer if approval signature is provided
    ///             2b. Otherwise uses a standard ERC20 transfer
    ///
    ///             This function reverts if:
    ///             - The Permit2 approval is invalid
    ///             - The caller does not have sufficient balance of the quote token
    ///             - Approval has not been granted to transfer the quote token
    ///             - The quote token transfer fails
    ///             - Transferring the quote token would result in a lesser amount being received
    ///             - The pre-hook reverts
    ///             - TODO: The pre-hook invariant is violated
    ///
    /// @param      lotId_              Lot ID
    /// @param      amount_             Amount of quoteToken to collect (in native decimals)
    /// @param      quoteToken_         Quote token to collect
    /// @param      hooks_              Hooks contract to call (optional)
    /// @param      permit2Approval_    Permit2 approval data (optional)
    function _collectPayment(
        uint96 lotId_,
        uint256 amount_,
        ERC20 quoteToken_,
        IHooks hooks_,
        Transfer.Permit2Approval memory permit2Approval_
    ) internal {
        // Call pre hook on hooks contract if provided
        if (address(hooks_) != address(0)) {
            hooks_.pre(lotId_, amount_);
        }

        Transfer.permit2OrTransferFrom(
            quoteToken_, _PERMIT2, msg.sender, address(this), amount_, permit2Approval_, true
        );
    }

    /// @notice     Sends payment of the quote token to the auction owner
    /// @dev        This function handles the following:
    ///             1. Sends the payment amount to the auction owner or hook (if provided)
    ///             This function assumes:
    ///             - The quote token has already been transferred to this contract
    ///             - The quote token is supported (e.g. not fee-on-transfer)
    ///
    ///             This function reverts if:
    ///             - The transfer fails
    ///
    /// @param      lotOwner_       Owner of the lot
    /// @param      amount_         Amount of quoteToken to send (in native decimals)
    /// @param      quoteToken_     Quote token to send
    /// @param      hooks_          Hooks contract to call (optional)
    function _sendPayment(
        address lotOwner_,
        uint256 amount_,
        ERC20 quoteToken_,
        IHooks hooks_
    ) internal {
        Transfer.transfer(
            quoteToken_, address(hooks_) == address(0) ? lotOwner_ : address(hooks_), amount_, false
        );
    }

    /// @notice     Collects the payout token from the auction owner
    /// @dev        This function handles the following:
    ///             1. Calls the mid hook on the hooks contract (if provided)
    ///             2. Transfers the payout token from the auction owner
    ///             2a. If the auction is pre-funded, then the transfer is skipped
    ///
    ///             This function reverts if:
    ///             - Approval has not been granted to transfer the payout token
    ///             - The auction owner does not have sufficient balance of the payout token
    ///             - The payout token transfer fails
    ///             - Transferring the payout token would result in a lesser amount being received
    ///             - The mid-hook reverts
    ///             - The mid-hook invariant is violated
    ///
    /// @param      lotId_          Lot ID
    /// @param      paymentAmount_  Amount of quoteToken collected (in native decimals)
    /// @param      payoutAmount_   Amount of payoutToken to collect (in native decimals)
    /// @param      routingParams_  Routing parameters for the lot
    function _collectPayout(
        uint96 lotId_,
        uint256 paymentAmount_,
        uint256 payoutAmount_,
        Routing memory routingParams_
    ) internal {
        // If pre-funded, then the payout token is already in this contract
        if (routingParams_.prefunding > 0) {
            return;
        }

        // Get the balance of the payout token before the transfer
        ERC20 baseToken = routingParams_.baseToken;

        // Call mid hook on hooks contract if provided
        if (address(routingParams_.hooks) != address(0)) {
            uint256 balanceBefore = baseToken.balanceOf(address(this));

            // The mid hook is expected to transfer the payout token to this contract
            routingParams_.hooks.mid(lotId_, paymentAmount_, payoutAmount_);

            // Check that the mid hook transferred the expected amount of payout tokens
            if (baseToken.balanceOf(address(this)) < balanceBefore + payoutAmount_) {
                revert InvalidHook();
            }
        }
        // Otherwise fallback to a standard ERC20 transfer
        else {
            Transfer.transferFrom(
                baseToken, routingParams_.owner, address(this), payoutAmount_, true
            );
        }
    }

    /// @notice     Sends the payout token to the recipient
    /// @dev        This function handles the following:
    ///             1. Sends the payout token from the router to the recipient
    ///             1a. If the lot is a derivative, mints the derivative token to the recipient
    ///             2. Calls the post hook on the hooks contract (if provided)
    ///
    ///             This function assumes that:
    ///             - The payout token has already been transferred to this contract
    ///             - The payout token is supported (e.g. not fee-on-transfer)
    ///
    ///             This function reverts if:
    ///             - The payout token transfer fails
    ///             - The payout token transfer would result in a lesser amount being received
    ///             - The post-hook reverts
    ///             - The post-hook invariant is violated
    ///
    /// @param      lotId_          Lot ID
    /// @param      recipient_      Address to receive payout
    /// @param      payoutAmount_   Amount of payoutToken to send (in native decimals)
    /// @param      routingParams_  Routing parameters for the lot
    /// @param      auctionOutput_  Custom data returned by the auction module
    function _sendPayout(
        uint96 lotId_,
        address recipient_,
        uint256 payoutAmount_,
        Routing memory routingParams_,
        bytes memory auctionOutput_
    ) internal {
        Veecode derivativeReference = routingParams_.derivativeReference;
        ERC20 baseToken = routingParams_.baseToken;

        // If no derivative, then the payout is sent directly to the recipient
        if (fromVeecode(derivativeReference) == bytes7("")) {
            Transfer.transfer(baseToken, recipient_, payoutAmount_, true);
        }
        // Otherwise, send parameters and payout to the derivative to mint to recipient
        else {
            // Get the module for the derivative type
            // We assume that the module type has been checked when the lot was created
            DerivativeModule module = DerivativeModule(_getModuleIfInstalled(derivativeReference));

            bytes memory derivativeParams = routingParams_.derivativeParams;

            // Lookup condensor module from combination of auction and derivative types
            // If condenser specified, condense auction output and derivative params before sending to derivative module
            Veecode condenserRef = condensers[routingParams_.auctionReference][derivativeReference];
            if (fromVeecode(condenserRef) != bytes7("")) {
                // Get condenser module
                CondenserModule condenser = CondenserModule(_getModuleIfInstalled(condenserRef));

                // Condense auction output and derivative params
                derivativeParams = condenser.condense(auctionOutput_, derivativeParams);
            }

            // Approve the module to transfer payout tokens when minting
            Transfer.approve(baseToken, address(module), payoutAmount_);

            // Call the module to mint derivative tokens to the recipient
            module.mint(
                recipient_,
                address(baseToken),
                derivativeParams,
                payoutAmount_,
                routingParams_.wrapDerivative
            );
        }

        // Call post hook on hooks contract if provided
        if (address(routingParams_.hooks) != address(0)) {
            routingParams_.hooks.post(lotId_, payoutAmount_);
        }
    }

    // ========== FEE FUNCTIONS ========== //

    function _allocateQuoteFees(
        Keycode auctionType_,
        Bid[] memory bids_,
        address owner_,
        ERC20 quoteToken_
    ) internal returns (uint256 totalAmountIn, uint256 totalFees, uint256 totalAmountInLessFees) {
        // Calculate fees for purchase
        uint256 bidCount = bids_.length;
        uint256 totalProtocolFees;
        for (uint256 i; i < bidCount; i++) {
            address bidReferrer = bids_[i].referrer;
            uint256 bidAmount = bids_[i].amount;

            // Calculate fees from bid amount
            (uint256 toReferrer, uint256 toProtocol) = calculateQuoteFees(
                auctionType_, bidReferrer != address(0) && bidReferrer != owner_, bidAmount
            );

            // Update referrer fee balances if non-zero and increment the total protocol fee
            if (toReferrer > 0) {
                rewards[bidReferrer][quoteToken_] += toReferrer;
            }
            totalProtocolFees += toProtocol;
            totalFees += toReferrer + toProtocol;

            // Increment total amount in
            totalAmountIn += bidAmount;
        }

        // Update protocol fee if not zero
        if (totalProtocolFees > 0) rewards[_protocol][quoteToken_] += totalProtocolFees;

        totalAmountInLessFees = totalAmountIn - totalFees;
    }
}
