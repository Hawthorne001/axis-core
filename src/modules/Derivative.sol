/// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.19;

import {ERC6909} from "lib/solmate/src/tokens/ERC6909.sol";
import {Module, Keycode} from "src/modules/Modules.sol";

abstract contract Derivative {
    // ========== ERRORS ========== //

    error Derivative_NotImplemented();

    // ========== EVENTS ========== //

    // ========== DATA STRUCTURES ========== //

    // TODO are some of the properties not redundant? exists, decimals, name, symbol. Can be fetched from the ERC20.
    struct Token {
        bool exists;
        address wrapped;
        uint8 decimals;
        string name;
        string symbol;
        // TODO clarify what kind of data could be contained here
        bytes data;
    }

    // ========== STATE VARIABLES ========== //
    mapping(Keycode dType => address) public wrappedImplementations; // TODO is this needed? Each derivative will have its own implementation(s), not share across modules
    mapping(uint256 tokenId => Token metadata) public tokenMetadata;
    mapping(uint96 lotId => uint256[] tokenIds) public lotDerivatives; // TODO lotId is not passed to any of the functions, so how will this be set?

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
    ) external virtual returns (uint256 tokenId_, address wrappedAddress_);

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
    )
        external
        virtual
        returns (uint256 tokenId_, address wrappedAddress_, uint256 amountCreated_);

    /// @notice Mint new derivative tokens for a specific token Id
    /// @param to_ The address to mint the derivative tokens to
    /// @param tokenId_ The ID of the derivative token
    /// @param amount_ The amount of derivative tokens to create
    /// @param wrapped_ Whether (true) or not (false) the derivative should be wrapped in an ERC20 token for composability
    /// @return tokenId_ The ID of the derivative token
    /// @return wrappedAddress_ The address of the ERC20 wrapped derivative token, if wrapped_ is true, otherwise, it's the zero address.
    /// @return amountCreated_ The amount of derivative tokens created
    function mint(
        address to_,
        uint256 tokenId_,
        uint256 amount_,
        bool wrapped_
    ) external virtual returns (uint256, address, uint256);

    function redeemMax(uint256 tokenId_, bool wrapped_) external virtual;

    /// @notice Redeem derivative tokens for underlying collateral
    /// @param tokenId_ The ID of the derivative token to redeem
    /// @param amount_ The amount of derivative tokens to redeem
    /// @param wrapped_ Whether (true) or not (false) to redeem wrapped ERC20 derivative tokens
    function redeem(uint256 tokenId_, uint256 amount_, bool wrapped_) external virtual;

    /// @notice     Determines the amount of redeemable tokens for a given derivative token
    ///
    /// @param      owner_      The owner of the derivative token
    /// @param      tokenId_    The ID of the derivative token
    /// @param      wrapped_    Whether (true) or not (false) to redeem wrapped ERC20 derivative tokens
    /// @return     amount_     The amount of redeemable tokens
    function redeemable(
        address owner_,
        uint256 tokenId_,
        bool wrapped_
    ) external view virtual returns (uint256);

    /// @notice Exercise a conversion of the derivative token per the specific implementation logic
    /// @dev Used for options or other derivatives with convertible options, e.g. Rage vesting.
    function exercise(uint256 tokenId_, uint256 amount, bool wrapped_) external virtual;

    /// @notice Reclaim posted collateral for a derivative token which can no longer be exercised
    /// @notice Access controlled: only callable by the derivative issuer via the auction house.
    /// @dev
    function reclaim(uint256 tokenId_) external virtual;

    /// @notice Transforms an existing derivative issued by this contract into something else. Derivative is burned and collateral sent to the auction house.
    /// @notice Access controlled: only callable by the auction house.
    function transform(
        uint256 tokenId_,
        address from_,
        uint256 amount_,
        bool wrapped_
    ) external virtual;

    /// @notice     Wrap an existing derivative into an ERC20 token for composability
    ///             Deploys the ERC20 wrapper if it does not already exist
    ///
    /// @param      tokenId_    The ID of the derivative token to wrap
    /// @param      amount_     The amount of derivative tokens to wrap
    function wrap(uint256 tokenId_, uint256 amount_) external virtual;

    /// @notice     Unwrap an ERC20 derivative token into the underlying ERC6909 derivative
    ///
    /// @param      tokenId_    The ID of the derivative token to unwrap
    /// @param      amount_     The amount of derivative tokens to unwrap
    function unwrap(uint256 tokenId_, uint256 amount_) external virtual;

    /// @notice     Validate derivative params for the specific implementation
    ///             The parameters should be the same as what is passed into `deploy()` or `mint()`
    ///
    /// @param      params_     The params to validate
    /// @return     bool        Whether or not the params are valid
    function validate(bytes memory params_) external view virtual returns (bool);

    // ========== DERIVATIVE INFORMATION ========== //

    // TODO view function to format implementation specific token data correctly and return to user

    function exerciseCost(
        bytes memory data,
        uint256 amount
    ) external view virtual returns (uint256);

    function convertsTo(
        bytes memory data,
        uint256 amount
    ) external view virtual returns (uint256);

    // Compute unique token ID for params on the submodule
    function computeId(bytes memory params_) external pure virtual returns (uint256);
}

abstract contract DerivativeModule is Derivative, ERC6909, Module {}
