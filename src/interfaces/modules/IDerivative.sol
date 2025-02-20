// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.0;

/// @title      IDerivative
/// @notice     Interface for Derivative functionality
/// @dev        Derivatives provide a mechanism to create synthetic assets that are backed by collateral, such as base tokens from an auction.
interface IDerivative {
    // ========== ERRORS ========== //

    error Derivative_NotImplemented();

    // ========== DATA STRUCTURES ========== //

    /// @notice     Metadata for a derivative token
    ///
    /// @param      exists          True if the token has been deployed
    /// @param      wrapped         Non-zero if an ERC20-wrapped derivative has been deployed
    /// @param      underlyingToken The address of the underlying token
    /// @param      supply          The total supply of the derivative token
    /// @param      data            Implementation-specific data
    struct Token {
        bool exists;
        address wrapped;
        address underlyingToken;
        uint256 supply;
        bytes data;
    }

    // ========== STATE VARIABLES ========== //

    /// @notice The metadata for a derivative token
    ///
    /// @param  tokenId         The ID of the derivative token
    /// @return exists          True if the token has been deployed
    /// @return wrapped         Non-zero if an ERC20-wrapped derivative has been deployed
    /// @return underlyingToken The address of the underlying token
    /// @return supply          The total supply of the derivative token
    /// @return data            Implementation-specific data
    function tokenMetadata(uint256 tokenId)
        external
        view
        returns (
            bool exists,
            address wrapped,
            address underlyingToken,
            uint256 supply,
            bytes memory data
        );

    // ========== DERIVATIVE MANAGEMENT ========== //

    /// @notice     Deploy a new derivative token. Optionally, deploys an ERC20 wrapper for composability.
    ///
    /// @param      underlyingToken_    The address of the underlying token
    /// @param      params_             ABI-encoded parameters for the derivative to be created
    /// @param      wrapped_            Whether (true) or not (false) the derivative should be wrapped in an ERC20 token for composability
    /// @return     tokenId_            The ID of the newly created derivative token
    /// @return     wrappedAddress_     The address of the ERC20 wrapped derivative token, if wrapped_ is true, otherwise, it's the zero address.
    function deploy(
        address underlyingToken_,
        bytes memory params_,
        bool wrapped_
    ) external returns (uint256 tokenId_, address wrappedAddress_);

    /// @notice     Mint new derivative tokens.
    /// @notice     Deploys the derivative token if it does not already exist.
    /// @notice     The module is expected to transfer the collateral token to itself.
    ///
    /// @param      to_                 The address to mint the derivative tokens to
    /// @param      underlyingToken_    The address of the underlying token
    /// @param      params_             ABI-encoded parameters for the derivative to be created
    /// @param      amount_             The amount of derivative tokens to create
    /// @param      wrapped_            Whether (true) or not (false) the derivative should be wrapped in an ERC20 token for composability
    /// @return     tokenId_            The ID of the newly created derivative token
    /// @return     wrappedAddress_     The address of the ERC20 wrapped derivative token, if wrapped_ is true, otherwise, it's the zero address.
    /// @return     amountCreated_      The amount of derivative tokens created
    function mint(
        address to_,
        address underlyingToken_,
        bytes memory params_,
        uint256 amount_,
        bool wrapped_
    ) external returns (uint256 tokenId_, address wrappedAddress_, uint256 amountCreated_);

    /// @notice     Mint new derivative tokens for a specific token ID
    ///
    /// @param      to_                 The address to mint the derivative tokens to
    /// @param      tokenId_            The ID of the derivative token
    /// @param      amount_             The amount of derivative tokens to create
    /// @param      wrapped_            Whether (true) or not (false) the derivative should be wrapped in an ERC20 token for composability
    /// @return     tokenId_            The ID of the derivative token
    /// @return     wrappedAddress_     The address of the ERC20 wrapped derivative token, if wrapped_ is true, otherwise, it's the zero address.
    /// @return     amountCreated_      The amount of derivative tokens created
    function mint(
        address to_,
        uint256 tokenId_,
        uint256 amount_,
        bool wrapped_
    ) external returns (uint256, address, uint256);

    /// @notice     Redeem all available derivative tokens for underlying collateral
    ///
    /// @param      tokenId_    The ID of the derivative token to redeem
    function redeemMax(uint256 tokenId_) external;

    /// @notice     Redeem derivative tokens for underlying collateral
    ///
    /// @param      tokenId_    The ID of the derivative token to redeem
    /// @param      amount_     The amount of derivative tokens to redeem
    function redeem(uint256 tokenId_, uint256 amount_) external;

    /// @notice     Determines the amount of redeemable tokens for a given derivative token
    ///
    /// @param      owner_      The owner of the derivative token
    /// @param      tokenId_    The ID of the derivative token
    /// @return     amount      The amount of redeemable tokens
    function redeemable(address owner_, uint256 tokenId_) external view returns (uint256 amount);

    /// @notice     Exercise a conversion of the derivative token per the specific implementation logic
    /// @dev        Used for options or other derivatives with convertible options, e.g. Rage vesting.
    ///
    /// @param      tokenId_    The ID of the derivative token to exercise
    /// @param      amount      The amount of derivative tokens to exercise
    function exercise(uint256 tokenId_, uint256 amount) external;

    /// @notice     Determines the cost to exercise a derivative token in the quoted token
    /// @dev        Used for options or other derivatives with convertible options, e.g. Rage vesting.
    ///
    /// @param      tokenId_    The ID of the derivative token to exercise
    /// @param      amount      The amount of derivative tokens to exercise
    /// @return     cost        The cost to exercise the derivative token
    function exerciseCost(uint256 tokenId_, uint256 amount) external view returns (uint256 cost);

    /// @notice     Reclaim posted collateral for a derivative token which can no longer be exercised
    /// @notice     Access controlled: only callable by the derivative issuer via the auction house.
    ///
    /// @param      tokenId_    The ID of the derivative token to reclaim
    function reclaim(uint256 tokenId_) external;

    /// @notice     Transforms an existing derivative issued by this contract into something else. Derivative is burned and collateral sent to the auction house.
    /// @notice     Access controlled: only callable by the auction house.
    ///
    /// @param      tokenId_    The ID of the derivative token to transform
    /// @param      from_       The address of the owner of the derivative token
    /// @param      amount_     The amount of derivative tokens to transform
    function transform(uint256 tokenId_, address from_, uint256 amount_) external;

    /// @notice     Wrap an existing derivative into an ERC20 token for composability
    ///             Deploys the ERC20 wrapper if it does not already exist
    ///
    /// @param      tokenId_    The ID of the derivative token to wrap
    /// @param      amount_     The amount of derivative tokens to wrap
    function wrap(uint256 tokenId_, uint256 amount_) external;

    /// @notice     Unwrap an ERC20 derivative token into the underlying ERC6909 derivative
    ///
    /// @param      tokenId_    The ID of the derivative token to unwrap
    /// @param      amount_     The amount of derivative tokens to unwrap
    function unwrap(uint256 tokenId_, uint256 amount_) external;

    /// @notice     Validate derivative params for the specific implementation
    ///             The parameters should be the same as what is passed into `deploy()` or `mint()`
    ///
    /// @param      underlyingToken_    The address of the underlying token
    /// @param      params_             The params to validate
    /// @return     isValid             Whether or not the params are valid
    function validate(
        address underlyingToken_,
        bytes memory params_
    ) external view returns (bool isValid);

    // ========== DERIVATIVE INFORMATION ========== //

    /// @notice     Compute a unique token ID, given the parameters for the derivative
    ///
    /// @param      underlyingToken_    The address of the underlying token
    /// @param      params_             The parameters for the derivative
    /// @return     tokenId             The unique token ID
    function computeId(
        address underlyingToken_,
        bytes memory params_
    ) external pure returns (uint256 tokenId);

    /// @notice     Get the metadata for a derivative token
    ///
    /// @param      tokenId     The ID of the derivative token
    /// @return     tokenData   The metadata for the derivative token
    function getTokenMetadata(uint256 tokenId) external view returns (Token memory tokenData);
}
