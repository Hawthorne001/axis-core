// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import {UniswapV3DirectToLiquidityTest} from "./UniswapV3DTLTest.sol";

import {BaseCallback} from "src/callbacks/BaseCallback.sol";
import {BaseDirectToLiquidity} from "src/callbacks/liquidity/BaseDTL.sol";
import {UniswapV3DirectToLiquidity} from "src/callbacks/liquidity/UniswapV3DTL.sol";

contract UniswapV3DirectToLiquidityOnCreateTest is UniswapV3DirectToLiquidityTest {
    // ============ Modifiers ============ //

    function _performCallback() internal {
        vm.prank(address(_auctionHouse));
        _dtl.onCreate(
            _lotId,
            _SELLER,
            address(_baseToken),
            address(_quoteToken),
            _LOT_CAPACITY,
            false,
            abi.encode(_dtlCreateParams)
        );
    }

    // ============ Assertions ============ //

    function _expectTransferFrom() internal {
        vm.expectRevert("TRANSFER_FROM_FAILED");
    }

    function _expectInvalidParams() internal {
        bytes memory err = abi.encodeWithSelector(BaseCallback.Callback_InvalidParams.selector);
        vm.expectRevert(err);
    }

    function _expectNotAuthorized() internal {
        bytes memory err = abi.encodeWithSelector(BaseCallback.Callback_NotAuthorized.selector);
        vm.expectRevert(err);
    }

    function _assertBaseTokenBalances() internal {
        assertEq(_baseToken.balanceOf(_SELLER), 0, "seller balance");
        assertEq(_baseToken.balanceOf(_dtlAddress), 0, "dtl balance");
    }

    // ============ Tests ============ //

    // [X] when the callback data is incorrect
    //  [X] it reverts
    // [X] when the callback is not called by the auction house
    //  [X] it reverts
    // [X] when the lot has already been registered
    //  [X] it reverts
    // [X] when the proceeds utilisation is 0
    //  [X] it reverts
    // [X] when the proceeds utilisation is greater than 100%
    //  [X] it reverts
    // [X] given the pool fee is not enabled
    //  [X] it reverts
    // [X] given uniswap v3 pool already exists
    //  [X] it reverts
    // [X] when the start and expiry timestamps are the same
    //  [X] it reverts
    // [X] when the start timestamp is after the expiry timestamp
    //  [X] it reverts
    // [X] when the start timestamp is before the current timestamp
    //  [X] it succeeds
    // [X] when the expiry timestamp is before the current timestamp
    //  [X] it reverts
    // [X] when the start timestamp and expiry timestamp are specified
    //  [X] given the linear vesting module is not installed
    //   [X] it reverts
    //  [X] it records the address of the linear vesting module
    // [X] when the recipient is the zero address
    //  [X] it reverts
    // [X] when the recipient is not the seller
    //  [X] it records the recipient
    // [ ] when multiple lots are created
    //  [ ] it registers each lot
    // [X] it registers the lot

    function test_whenCallbackDataIsIncorrect_reverts() public givenCallbackIsCreated {
        // Expect revert
        vm.expectRevert();

        vm.prank(address(_auctionHouse));
        _dtl.onCreate(
            _lotId,
            _SELLER,
            address(_baseToken),
            address(_quoteToken),
            _LOT_CAPACITY,
            false,
            abi.encode(uint256(10))
        );
    }

    function test_whenCallbackIsNotCalledByAuctionHouse_reverts() public givenCallbackIsCreated {
        _expectNotAuthorized();

        _dtl.onCreate(
            _lotId,
            _SELLER,
            address(_baseToken),
            address(_quoteToken),
            _LOT_CAPACITY,
            false,
            abi.encode(_dtlCreateParams)
        );
    }

    function test_whenLotHasAlreadyBeenRegistered_reverts() public givenCallbackIsCreated {
        _performCallback();

        _expectInvalidParams();

        _performCallback();
    }

    function test_whenProceedsUtilisationIs0_reverts()
        public
        givenCallbackIsCreated
        givenProceedsUtilisationPercent(0)
    {
        // Expect revert
        bytes memory err = abi.encodeWithSelector(
            BaseDirectToLiquidity.Callback_Params_PercentOutOfBounds.selector, 0, 1, 1e5
        );
        vm.expectRevert(err);

        _performCallback();
    }

    function test_whenProceedsUtilisationIsGreaterThan100Percent_reverts()
        public
        givenCallbackIsCreated
        givenProceedsUtilisationPercent(1e5 + 1)
    {
        // Expect revert
        bytes memory err = abi.encodeWithSelector(
            BaseDirectToLiquidity.Callback_Params_PercentOutOfBounds.selector, 1e5 + 1, 1, 1e5
        );
        vm.expectRevert(err);

        _performCallback();
    }

    function test_givenPoolFeeIsNotEnabled_reverts()
        public
        givenCallbackIsCreated
        givenPoolFee(0)
    {
        // Expect revert
        bytes memory err = abi.encodeWithSelector(
            UniswapV3DirectToLiquidity.Callback_Params_PoolFeeNotEnabled.selector
        );
        vm.expectRevert(err);

        _performCallback();
    }

    function test_givenUniswapV3PoolAlreadyExists_reverts()
        public
        givenCallbackIsCreated
        givenPoolFee(500)
    {
        // Create the pool
        _uniV3Factory.createPool(address(_baseToken), address(_quoteToken), 500);

        // Expect revert
        bytes memory err =
            abi.encodeWithSelector(BaseDirectToLiquidity.Callback_Params_PoolExists.selector);
        vm.expectRevert(err);

        _performCallback();
    }

    function test_whenStartAndExpiryTimestampsAreTheSame_reverts()
        public
        givenCallbackIsCreated
        givenLinearVestingModuleIsInstalled
        givenVestingStart(_START + 1)
        givenVestingExpiry(_START + 1)
    {
        // Expect revert
        bytes memory err = abi.encodeWithSelector(
            BaseDirectToLiquidity.Callback_Params_InvalidVestingParams.selector
        );
        vm.expectRevert(err);

        _performCallback();
    }

    function test_whenStartTimestampIsAfterExpiryTimestamp_reverts()
        public
        givenCallbackIsCreated
        givenLinearVestingModuleIsInstalled
        givenVestingStart(_START + 2)
        givenVestingExpiry(_START + 1)
    {
        // Expect revert
        bytes memory err = abi.encodeWithSelector(
            BaseDirectToLiquidity.Callback_Params_InvalidVestingParams.selector
        );
        vm.expectRevert(err);

        _performCallback();
    }

    function test_whenStartTimestampIsBeforeCurrentTimestamp_succeeds()
        public
        givenCallbackIsCreated
        givenLinearVestingModuleIsInstalled
        givenVestingStart(_START - 1)
        givenVestingExpiry(_START + 1)
    {
        _performCallback();

        // Assert values
        BaseDirectToLiquidity.DTLConfiguration memory configuration = _getDTLConfiguration(_lotId);
        assertEq(configuration.vestingStart, _START - 1, "vestingStart");
        assertEq(configuration.vestingExpiry, _START + 1, "vestingExpiry");
        assertEq(
            address(configuration.linearVestingModule),
            address(_linearVesting),
            "linearVestingModule"
        );

        // Assert balances
        _assertBaseTokenBalances();
    }

    function test_whenExpiryTimestampIsBeforeCurrentTimestamp_reverts()
        public
        givenCallbackIsCreated
        givenLinearVestingModuleIsInstalled
        givenVestingStart(_START + 1)
        givenVestingExpiry(_START - 1)
    {
        // Expect revert
        bytes memory err = abi.encodeWithSelector(
            BaseDirectToLiquidity.Callback_Params_InvalidVestingParams.selector
        );
        vm.expectRevert(err);

        _performCallback();
    }

    function test_whenVestingSpecified_givenLinearVestingModuleNotInstalled_reverts()
        public
        givenCallbackIsCreated
        givenVestingStart(_START + 1)
        givenVestingExpiry(_START + 2)
    {
        // Expect revert
        bytes memory err = abi.encodeWithSelector(
            BaseDirectToLiquidity.Callback_LinearVestingModuleNotFound.selector
        );
        vm.expectRevert(err);

        _performCallback();
    }

    function test_whenVestingSpecified()
        public
        givenCallbackIsCreated
        givenLinearVestingModuleIsInstalled
        givenVestingStart(_START + 1)
        givenVestingExpiry(_START + 2)
    {
        _performCallback();

        // Assert values
        BaseDirectToLiquidity.DTLConfiguration memory configuration = _getDTLConfiguration(_lotId);
        assertEq(configuration.vestingStart, _START + 1, "vestingStart");
        assertEq(configuration.vestingExpiry, _START + 2, "vestingExpiry");
        assertEq(
            address(configuration.linearVestingModule),
            address(_linearVesting),
            "linearVestingModule"
        );

        // Assert balances
        _assertBaseTokenBalances();
    }

    function test_whenRecipientIsZeroAddress_reverts() public givenCallbackIsCreated {
        _dtlCreateParams.recipient = address(0);

        // Expect revert
        bytes memory err =
            abi.encodeWithSelector(BaseDirectToLiquidity.Callback_Params_InvalidAddress.selector);
        vm.expectRevert(err);

        _performCallback();
    }

    function test_whenRecipientIsNotSeller_succeeds()
        public
        givenCallbackIsCreated
        whenRecipientIsNotSeller
    {
        _performCallback();

        // Assert values
        BaseDirectToLiquidity.DTLConfiguration memory configuration = _getDTLConfiguration(_lotId);
        assertEq(configuration.recipient, _NOT_SELLER, "recipient");

        // Assert balances
        _assertBaseTokenBalances();
    }

    function test_succeeds() public givenCallbackIsCreated {
        _performCallback();

        // Assert values
        BaseDirectToLiquidity.DTLConfiguration memory configuration = _getDTLConfiguration(_lotId);
        assertEq(configuration.recipient, _SELLER, "recipient");
        assertEq(configuration.lotCapacity, _LOT_CAPACITY, "lotCapacity");
        assertEq(configuration.lotCuratorPayout, 0, "lotCuratorPayout");
        assertEq(
            configuration.proceedsUtilisationPercent,
            _dtlCreateParams.proceedsUtilisationPercent,
            "proceedsUtilisationPercent"
        );
        assertEq(configuration.vestingStart, 0, "vestingStart");
        assertEq(configuration.vestingExpiry, 0, "vestingExpiry");
        assertEq(address(configuration.linearVestingModule), address(0), "linearVestingModule");
        assertEq(configuration.active, true, "active");

        (uint24 configurationPoolFee) = abi.decode(configuration.implParams, (uint24));
        assertEq(configurationPoolFee, _poolFee, "poolFee");
        assertEq(configuration.implParams, _dtlCreateParams.implParams, "implParams");

        // Assert balances
        _assertBaseTokenBalances();
    }
}
