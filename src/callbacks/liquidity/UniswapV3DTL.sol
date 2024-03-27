// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// Libraries
import {ERC20} from "solmate/tokens/ERC20.sol";
import {SqrtPriceMath} from "src/lib/uniswap-v3/SqrtPriceMath.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

// Uniswap
import {IUniswapV3Pool} from "uniswap-v3-core/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "uniswap-v3-core/interfaces/IUniswapV3Factory.sol";
import {TickMath} from "uniswap-v3-core/libraries/TickMath.sol";

// G-UNI
import {IGUniFactory} from "g-uni-v1-core/interfaces/IGUniFactory.sol";
import {GUniPool} from "g-uni-v1-core/GUniPool.sol";

// Callbacks
import {BaseCallback} from "src/callbacks/BaseCallback.sol";
import {Callbacks} from "src/lib/Callbacks.sol";

// AuctionHouse
import {LinearVesting} from "src/modules/derivatives/LinearVesting.sol";
import {AuctionHouse} from "src/AuctionHouse.sol";
import {Keycode, wrapVeecode} from "src/modules/Modules.sol";

/// @title      UniswapV3DirectToLiquidity
/// @notice     This Callback contract deposits the proceeds from a batch auction into a Uniswap V3 pool
///             in order to create liquidity immediately.
///
///             The LP tokens can optionally vest to the auction seller.
///
///             An important risk to consider: if the auction's base token is available and liquid, a third-party
///             could front-run the auction by creating the pool before the auction ends. This would allow them to
///             manipulate the price of the pool and potentially profit from the eventual deposit of the auction proceeds.
///
/// @dev        As a general rule, this callback contract does not retain balances of tokens between calls.
///             Transfers are performed within the same function that requires the balance.
contract UniswapV3DirectToLiquidity is BaseCallback {
    using SafeTransferLib for ERC20;

    // ========== ERRORS ========== //

    error Callback_Params_InvalidAddress();

    error Callback_Params_UtilisationPercentOutOfBounds(uint24 actual_, uint24 min_, uint24 max_);

    error Callback_Params_PoolFeeNotEnabled();

    error Callback_Params_PoolExists();

    error Callback_Params_InvalidVestingParams();

    error Callback_LinearVestingModuleNotFound();

    // ========== STRUCTS ========== //

    /// @notice     Configuration for the DTL callback
    /// @param      baseToken                   The base token address
    /// @param      quoteToken                  The quote token address
    /// @param      recipient                   The recipient of the LP tokens
    /// @param      lotCapacity                 The capacity of the lot
    /// @param      lotCuratorPayout            The maximum curator payout of the lot
    /// @param      proceedsUtilisationPercent  The percentage of the proceeds to deposit into the pool
    /// @param      poolFee                     The Uniswap V3 fee tier for the pool
    /// @param      vestingStart                The start of the vesting period for the LP tokens (0 if disabled)
    /// @param      vestingExpiry               The end of the vesting period for the LP tokens (0 if disabled)
    /// @param      linearVestingModule         The LinearVesting module for the LP tokens (only set if linear vesting is enabled)
    /// @param      active                      Whether the lot is active
    struct DTLConfiguration {
        address baseToken;
        address quoteToken;
        address recipient;
        uint96 lotCapacity;
        uint96 lotCuratorPayout;
        uint24 proceedsUtilisationPercent;
        uint24 poolFee;
        uint48 vestingStart;
        uint48 vestingExpiry;
        LinearVesting linearVestingModule;
        bool active;
    }

    /// @notice     Parameters used in the onCreate callback
    ///
    /// @param      proceedsUtilisationPercent   The percentage of the proceeds to use in the pool
    /// @param      poolFee                      The Uniswap V3 fee tier for the pool
    /// @param      vestingStart                 The start of the vesting period for the LP tokens (0 if disabled)
    /// @param      vestingExpiry                The end of the vesting period for the LP tokens (0 if disabled)
    /// @param      recipient                    The recipient of the LP tokens
    struct DTLParams {
        uint24 proceedsUtilisationPercent;
        uint24 poolFee;
        uint48 vestingStart;
        uint48 vestingExpiry;
        address recipient;
    }

    // ========== STATE VARIABLES ========== //

    uint8 internal constant _DTL_PARAMS_LENGTH = 160;
    uint24 public constant MAX_PERCENT = 1e5;
    bytes5 public constant LINEAR_VESTING_KEYCODE = 0x4c49560000; // "LIV"

    /// @notice     Maps the lot id to the DTL configuration
    mapping(uint96 lotId => DTLConfiguration) public lotConfiguration;

    /// @notice     The Uniswap V3 Factory contract
    /// @dev        This contract is used to create Uniswap V3 pools
    IUniswapV3Factory public uniV3Factory;

    /// @notice     The G-UNI Factory contract
    /// @dev        This contract is used to create the ERC20 LP tokens
    IGUniFactory public gUniFactory;

    constructor(
        address auctionHouse_,
        address seller_,
        address uniV3Factory_,
        address gUniFactory_
    )
        BaseCallback(
            auctionHouse_,
            Callbacks.Permissions({
                onCreate: true,
                onCancel: true,
                onCurate: true,
                onPurchase: false,
                onBid: false,
                onClaimProceeds: true,
                receiveQuoteTokens: true,
                sendBaseTokens: false
            }),
            seller_
        )
    {
        if (uniV3Factory_ == address(0)) {
            revert Callback_Params_InvalidAddress();
        }
        uniV3Factory = IUniswapV3Factory(uniV3Factory_);

        if (gUniFactory_ == address(0)) {
            revert Callback_Params_InvalidAddress();
        }
        gUniFactory = IGUniFactory(gUniFactory_);
    }

    // ========== CALLBACK FUNCTIONS ========== //

    /// @notice     Callback for when a lot is created
    /// @dev        This function performs the following:
    ///             - Validates the input data
    ///             - Stores the configuration for the lot
    ///
    ///             This function reverts if:
    ///             - DTLParams.proceedsUtilisationPercent is out of bounds
    ///             - DTLParams.poolFee is not enabled
    ///             - The pool for the token and fee combination already exists
    ///             - DTLParams.vestingStart or DTLParams.vestingExpiry do not pass validation
    ///             - Vesting is enabled and the linear vesting module is not found
    ///             - The DTLParams.recipient address is the zero address
    ///
    /// @param      lotId_          The lot ID
    /// @param      baseToken_      The base token address
    /// @param      quoteToken_     The quote token address
    /// @param      capacity_       The capacity of the lot
    /// @param      callbackData_   Encoded DTLParams struct
    function _onCreate(
        uint96 lotId_,
        address,
        address baseToken_,
        address quoteToken_,
        uint96 capacity_,
        bool,
        bytes calldata callbackData_
    ) internal virtual override onlyIfLotDoesNotExist(lotId_) {
        // Decode callback data into the params
        if (callbackData_.length != _DTL_PARAMS_LENGTH) {
            revert Callback_InvalidParams();
        }
        DTLParams memory params = abi.decode(callbackData_, (DTLParams));

        // Validate the parameters
        // Proceeds utilisation
        if (
            params.proceedsUtilisationPercent == 0
                || params.proceedsUtilisationPercent > MAX_PERCENT
        ) {
            revert Callback_Params_UtilisationPercentOutOfBounds(
                params.proceedsUtilisationPercent, 1, MAX_PERCENT
            );
        }

        // Pool fee
        // Fee not enabled
        if (uniV3Factory.feeAmountTickSpacing(params.poolFee) == 0) {
            revert Callback_Params_PoolFeeNotEnabled();
        }

        // Check that the pool does not exist
        if (uniV3Factory.getPool(baseToken_, quoteToken_, params.poolFee) != address(0)) {
            revert Callback_Params_PoolExists();
        }

        // Vesting
        LinearVesting linearVestingModule;

        // If vesting is enabled
        if (params.vestingStart != 0 || params.vestingExpiry != 0) {
            // Get the linear vesting module (or revert)
            linearVestingModule = LinearVesting(_getLatestLinearVestingModule());

            // Validate
            if (
                // We will actually use the LP tokens, but this is a placeholder as we really want to validate the vesting parameters
                !linearVestingModule.validate(
                    address(baseToken_),
                    _getEncodedVestingParams(params.vestingStart, params.vestingExpiry)
                )
            ) {
                revert Callback_Params_InvalidVestingParams();
            }
        }

        // If the recipient is the zero address
        if (params.recipient == address(0)) {
            revert Callback_Params_InvalidAddress();
        }

        // Store the configuration
        lotConfiguration[lotId_] = DTLConfiguration({
            baseToken: baseToken_,
            quoteToken: quoteToken_,
            recipient: params.recipient,
            lotCapacity: capacity_,
            lotCuratorPayout: 0,
            proceedsUtilisationPercent: params.proceedsUtilisationPercent,
            poolFee: params.poolFee,
            vestingStart: params.vestingStart,
            vestingExpiry: params.vestingExpiry,
            linearVestingModule: linearVestingModule,
            active: true
        });
    }

    /// @notice     Callback for when a lot is cancelled
    /// @dev        This function performs the following:
    ///             - Marks the lot as inactive
    ///
    ///             This function reverts if:
    ///             - The lot is not registered
    ///
    /// @param      lotId_          The lot ID
    function _onCancel(
        uint96 lotId_,
        uint96,
        bool,
        bytes calldata
    ) internal override onlyIfLotExists(lotId_) {
        // Mark the lot as inactive to prevent further actions
        DTLConfiguration storage config = lotConfiguration[lotId_];
        config.active = false;
    }

    /// @notice     Callback for when a lot is curated
    /// @dev        This function performs the following:
    ///             - Records the curator payout
    ///
    ///             This function reverts if:
    ///             - The lot is not registered
    ///
    /// @param      lotId_          The lot ID
    /// @param      curatorPayout_  The maximum curator payout
    function _onCurate(
        uint96 lotId_,
        uint96 curatorPayout_,
        bool,
        bytes calldata
    ) internal override onlyIfLotExists(lotId_) {
        // Update the funding
        DTLConfiguration storage config = lotConfiguration[lotId_];
        config.lotCuratorPayout = curatorPayout_;
    }

    /// @notice     Callback for a purchase
    /// @dev        Not implemented
    function _onPurchase(
        uint96,
        address,
        uint96,
        uint96,
        bool,
        bytes calldata
    ) internal pure override {
        // Not implemented
        revert Callback_NotImplemented();
    }

    /// @notice     Callback for a bid
    /// @dev        Not implemented
    function _onBid(uint96, uint64, address, uint96, bytes calldata) internal pure override {
        // Not implemented
        revert Callback_NotImplemented();
    }

    /// @notice     Callback for claiming the proceeds
    /// @dev        This function performs the following:
    ///             - Calculates the base and quote tokens to deposit into the Uniswap V3 pool
    ///             - Creates and initializes the pool, if necessary
    ///             - Deploys a pool token to wrap the Uniswap V3 position as an ERC-20
    ///             - Deposits the tokens into the pool and mint the LP tokens
    ///             - If vesting is enabled, mints the vesting tokens, or transfers the LP tokens to the recipient
    ///             - Sends any remaining quote and base tokens to the seller
    ///
    ///             The assumptions are:
    ///             - the callback has `proceeds_` quantity of quote tokens (as `receiveQuoteTokens` flag is set)
    ///             - the seller has the required balance of base tokens
    ///             - the seller has approved the callback to spend the base tokens
    ///
    ///             This function reverts if:
    ///             - The lot is not registered
    ///             - The callback data is not the correct length
    ///
    /// @param      lotId_          The lot ID
    /// @param      proceeds_       The proceeds from the auction
    /// @param      refund_         The refund from the auction
    function _onClaimProceeds(
        uint96 lotId_,
        uint96 proceeds_,
        uint96 refund_,
        bytes calldata
    ) internal virtual override onlyIfLotExists(lotId_) {
        DTLConfiguration memory config = lotConfiguration[lotId_];

        uint256 baseTokensRequired;
        uint256 quoteTokensRequired;
        {
            // Calculate the actual lot capacity that was used
            uint96 capacityUtilised;
            {
                // If curation is enabled, refund_ will also contain the refund on the curator payout. Adjust for that.
                // Example:
                // 100 capacity + 10 curator
                // 90 capacity sold, 9 curator payout
                // 11 refund
                // Utilisation = 1 - 11/110 = 90%
                uint96 utilisationPercent =
                    1e5 - refund_ * 1e5 / (config.lotCapacity + config.lotCuratorPayout);

                capacityUtilised = (config.lotCapacity * utilisationPercent) / MAX_PERCENT;
            }

            // Calculate the base tokens required to create the pool
            baseTokensRequired =
                _tokensRequiredForPool(capacityUtilised, config.proceedsUtilisationPercent);
            quoteTokensRequired =
                _tokensRequiredForPool(proceeds_, config.proceedsUtilisationPercent);
        }

        // Determine the ordering of tokens
        bool quoteTokenIsToken0 = config.quoteToken < config.baseToken;

        // Create and initialize the pool if necessary
        {
            // Determine sqrtPriceX96
            uint160 sqrtPriceX96 = SqrtPriceMath.getSqrtPriceX96(
                config.quoteToken, config.baseToken, quoteTokensRequired, baseTokensRequired
            );

            // If the pool already exists and is initialized, it will have no effect
            // Please see the risks section in the contract documentation for more information
            _createAndInitializePoolIfNecessary(
                quoteTokenIsToken0 ? config.quoteToken : config.baseToken,
                quoteTokenIsToken0 ? config.baseToken : config.quoteToken,
                config.poolFee,
                sqrtPriceX96
            );
        }

        // Deploy the pool token
        address poolTokenAddress;
        {
            // Adjust the full-range ticks according to the tick spacing for the current fee
            int24 tickSpacing = uniV3Factory.feeAmountTickSpacing(config.poolFee);
            int24 minTick = TickMath.MIN_TICK / tickSpacing * tickSpacing;
            int24 maxTick = TickMath.MAX_TICK / tickSpacing * tickSpacing;

            // Create an unmanaged pool
            // The range of the position will not be changed after deployment
            // Fees will also be collected at the time of withdrawal
            poolTokenAddress = gUniFactory.createPool(
                quoteTokenIsToken0 ? config.quoteToken : config.baseToken,
                quoteTokenIsToken0 ? config.baseToken : config.quoteToken,
                config.poolFee,
                minTick,
                maxTick
            );
        }

        // Deposit into the pool
        uint256 poolTokenQuantity;
        {
            GUniPool poolToken = GUniPool(poolTokenAddress);

            // Approve the vault to spend the tokens
            ERC20(config.quoteToken).approve(address(poolTokenAddress), quoteTokensRequired);
            ERC20(config.baseToken).approve(address(poolTokenAddress), baseTokensRequired);

            // Calculate the mint amount
            uint256 amount0Required;
            uint256 amount1Requied;
            (amount0Required, amount1Requied, poolTokenQuantity) = poolToken.getMintAmounts(
                quoteTokenIsToken0 ? quoteTokensRequired : baseTokensRequired,
                quoteTokenIsToken0 ? baseTokensRequired : quoteTokensRequired
            );

            // Update the tokens required based on actuals
            quoteTokensRequired = quoteTokenIsToken0 ? amount0Required : amount1Requied;
            baseTokensRequired = quoteTokenIsToken0 ? amount1Requied : amount0Required;
        }

        // Ensure the required tokens are present before minting
        uint256 quoteTokenBalance;
        uint256 baseTokenBalance;
        {
            // As receiveQuoteTokens is set, the quote tokens have been transferred to the callback
            quoteTokenBalance += proceeds_;

            // Fund the callback by the seller
            ERC20(config.baseToken).safeTransferFrom(seller, address(this), baseTokensRequired);
            baseTokenBalance += baseTokensRequired;
        }

        // Mint LP tokens
        {
            GUniPool poolToken = GUniPool(poolTokenAddress);

            // Mint the LP tokens
            (uint256 amount0Used, uint256 amount1Used,) =
                poolToken.mint(poolTokenQuantity, address(this));

            // Adjust running balance
            quoteTokenBalance -= quoteTokenIsToken0 ? amount0Used : amount1Used;
            baseTokenBalance -= quoteTokenIsToken0 ? amount1Used : amount0Used;
        }

        // If vesting is enabled, create the vesting tokens
        if (address(config.linearVestingModule) != address(0)) {
            // Approve spending of the tokens
            ERC20(poolTokenAddress).approve(address(config.linearVestingModule), poolTokenQuantity);

            // Mint the vesting tokens (it will deploy if necessary)
            config.linearVestingModule.mint(
                config.recipient,
                poolTokenAddress,
                _getEncodedVestingParams(config.vestingStart, config.vestingExpiry),
                poolTokenQuantity,
                true // Wrap vesting LP tokens so they are easily visible
            );
        }
        // Send the LP tokens to the seller
        else {
            ERC20(poolTokenAddress).safeTransfer(config.recipient, poolTokenQuantity);
        }

        // Send any remaining quote tokens to the seller
        if (quoteTokenBalance > 0) {
            ERC20(config.quoteToken).safeTransfer(seller, quoteTokenBalance);
        }

        // Send any remaining base tokens to the seller
        if (baseTokenBalance > 0) {
            ERC20(config.baseToken).safeTransfer(seller, baseTokenBalance);
        }
    }

    // ========== MODIFIERS ========== //

    modifier onlyIfLotDoesNotExist(uint96 lotId_) {
        if (lotConfiguration[lotId_].baseToken != address(0)) {
            revert Callback_InvalidParams();
        }
        _;
    }

    modifier onlyIfLotExists(uint96 lotId_) {
        if (!lotConfiguration[lotId_].active) {
            revert Callback_InvalidParams();
        }
        _;
    }

    // ========== INTERNAL FUNCTIONS ========== //

    function _tokensRequiredForPool(
        uint96 amount_,
        uint24 proceedsUtilisationPercent_
    ) internal pure returns (uint96) {
        return (amount_ * proceedsUtilisationPercent_) / MAX_PERCENT;
    }

    function _getLatestLinearVestingModule() internal view returns (address) {
        AuctionHouse auctionHouseContract = AuctionHouse(auctionHouse);
        Keycode moduleKeycode = Keycode.wrap(LINEAR_VESTING_KEYCODE);

        // Get the module status
        (uint8 latestVersion, bool isSunset) = auctionHouseContract.getModuleStatus(moduleKeycode);

        if (isSunset || latestVersion == 0) {
            revert Callback_LinearVestingModuleNotFound();
        }

        return address(
            auctionHouseContract.getModuleForVeecode(wrapVeecode(moduleKeycode, latestVersion))
        );
    }

    function _getEncodedVestingParams(
        uint48 start_,
        uint48 expiry_
    ) internal pure returns (bytes memory) {
        return abi.encode(LinearVesting.VestingParams({start: start_, expiry: expiry_}));
    }

    /// @dev    Copied from UniswapV3's PoolInitializer (which is GPL >= 2)
    function _createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) internal returns (address pool) {
        require(token0 < token1);
        pool = uniV3Factory.getPool(token0, token1, fee);

        if (pool == address(0)) {
            pool = uniV3Factory.createPool(token0, token1, fee);
            IUniswapV3Pool(pool).initialize(sqrtPriceX96);
        } else {
            (uint160 sqrtPriceX96Existing,,,,,,) = IUniswapV3Pool(pool).slot0();
            if (sqrtPriceX96Existing == 0) {
                IUniswapV3Pool(pool).initialize(sqrtPriceX96);
            }
        }
    }
}
