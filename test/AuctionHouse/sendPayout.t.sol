/// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.19;

import {Test} from "forge-std/Test.sol";
import {Transfer} from "src/lib/Transfer.sol";

import {MockHook} from "test/modules/Auction/MockHook.sol";
import {MockAuctionHouse} from "test/AuctionHouse/MockAuctionHouse.sol";
import {MockAtomicAuctionModule} from "test/modules/Auction/MockAtomicAuctionModule.sol";
import {MockDerivativeModule} from "test/modules/derivatives/mocks/MockDerivativeModule.sol";
import {MockCondenserModule} from "test/modules/Condenser/MockCondenserModule.sol";
import {MockFeeOnTransferERC20} from "test/lib/mocks/MockFeeOnTransferERC20.sol";
import {Permit2User} from "test/lib/permit2/Permit2User.sol";
import {MockWrappedDerivative} from "test/lib/mocks/MockWrappedDerivative.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {IAllowlist} from "src/interfaces/IAllowlist.sol";
import {Auctioneer} from "src/bases/Auctioneer.sol";

import {Veecode, toVeecode} from "src/modules/Modules.sol";

contract SendPayoutTest is Test, Permit2User {
    MockAuctionHouse internal _auctionHouse;
    MockAtomicAuctionModule internal _mockAuctionModule;
    MockDerivativeModule internal _mockDerivativeModule;
    MockCondenserModule internal _mockCondenserModule;
    MockWrappedDerivative internal _derivativeWrappedImplementation;

    address internal constant _PROTOCOL = address(0x1);
    address internal constant _USER = address(0x2);
    address internal constant _OWNER = address(0x3);
    address internal constant _RECIPIENT = address(0x4);

    uint48 internal constant _DERIVATIVE_EXPIRY = 1 days;

    // Function parameters
    uint96 internal _lotId = 1;
    uint256 internal _payoutAmount = 10e18;
    MockFeeOnTransferERC20 internal _quoteToken;
    MockFeeOnTransferERC20 internal _payoutToken;
    MockHook internal _hook;
    Veecode internal _derivativeReference;
    uint256 internal _derivativeTokenId;
    bytes internal _derivativeParams;
    bool internal _wrapDerivative;
    ERC20 internal _wrappedDerivative;
    uint256 internal _auctionOutputMultiplier;
    bytes internal _auctionOutput;

    Auctioneer.Routing internal _routingParams;

    function setUp() public {
        // Set reasonable starting block
        vm.warp(1_000_000);

        _auctionHouse = new MockAuctionHouse(_PROTOCOL, _PERMIT2_ADDRESS);
        _mockAuctionModule = new MockAtomicAuctionModule(address(_auctionHouse));
        _mockDerivativeModule = new MockDerivativeModule(address(_auctionHouse));
        _mockCondenserModule = new MockCondenserModule(address(_auctionHouse));
        _auctionHouse.installModule(_mockAuctionModule);

        _derivativeWrappedImplementation = new MockWrappedDerivative("name", "symbol", 18);
        _mockDerivativeModule.setWrappedImplementation(_derivativeWrappedImplementation);

        _quoteToken = new MockFeeOnTransferERC20("Quote Token", "QUOTE", 18);
        _quoteToken.setTransferFee(0);

        _payoutToken = new MockFeeOnTransferERC20("Payout Token", "PAYOUT", 18);
        _payoutToken.setTransferFee(0);

        _derivativeReference = toVeecode(bytes7(""));
        _derivativeParams = bytes("");
        _wrapDerivative = false;
        _auctionOutputMultiplier = 2;
        _auctionOutput =
            abi.encode(MockAtomicAuctionModule.Output({multiplier: _auctionOutputMultiplier})); // Does nothing unless the condenser is set

        _routingParams = Auctioneer.Routing({
            auctionReference: _mockAuctionModule.VEECODE(),
            owner: _OWNER,
            baseToken: _payoutToken,
            quoteToken: _quoteToken,
            hooks: _hook,
            allowlist: IAllowlist(address(0)),
            derivativeReference: _derivativeReference,
            derivativeParams: _derivativeParams,
            wrapDerivative: _wrapDerivative,
            prefunding: 0
        });
    }

    modifier givenTokenTakesFeeOnTransfer() {
        _payoutToken.setTransferFee(1000);
        _;
    }

    modifier givenAuctionHouseHasBalance(uint256 amount_) {
        _payoutToken.mint(address(_auctionHouse), amount_);
        _;
    }

    // ========== Hooks flow ========== //

    // [ ] given the auction has hooks defined
    //  [X] when the token is unsupported
    //   [X] it reverts
    //  [X] when the post _hook reverts
    //   [X] it reverts
    //  [ ] when the post _hook invariant is broken
    //   [ ] it reverts
    //  [X] it succeeds - transfers the payout from the _auctionHouse to the recipient

    modifier givenAuctionHasHook() {
        _hook = new MockHook(address(0), address(_payoutToken));
        _routingParams.hooks = _hook;

        // Set the addresses to track
        address[] memory addresses = new address[](6);
        addresses[0] = _USER;
        addresses[1] = _OWNER;
        addresses[2] = address(_auctionHouse);
        addresses[3] = address(_hook);
        addresses[4] = _RECIPIENT;
        addresses[5] = address(_mockDerivativeModule);

        _hook.setBalanceAddresses(addresses);
        _;
    }

    modifier givenPostHookReverts() {
        _hook.setPostHookReverts(true);
        _;
    }

    function test_hooks_whenPostHookReverts_reverts()
        public
        givenAuctionHasHook
        givenPostHookReverts
        givenAuctionHouseHasBalance(_payoutAmount)
    {
        // Expect revert
        vm.expectRevert("revert");

        // Call
        vm.prank(_USER);
        _auctionHouse.sendPayout(_lotId, _RECIPIENT, _payoutAmount, _routingParams, _auctionOutput);
    }

    function test_hooks_feeOnTransfer_reverts()
        public
        givenAuctionHasHook
        givenAuctionHouseHasBalance(_payoutAmount)
        givenTokenTakesFeeOnTransfer
    {
        // Expect revert
        bytes memory err =
            abi.encodeWithSelector(Transfer.UnsupportedToken.selector, address(_payoutToken));
        vm.expectRevert(err);

        // Call
        vm.prank(_USER);
        _auctionHouse.sendPayout(_lotId, _RECIPIENT, _payoutAmount, _routingParams, _auctionOutput);
    }

    function test_hooks_insufficientBalance_reverts() public givenAuctionHasHook {
        // Expect revert
        vm.expectRevert(bytes("TRANSFER_FAILED"));

        // Call
        vm.prank(_USER);
        _auctionHouse.sendPayout(_lotId, _RECIPIENT, _payoutAmount, _routingParams, _auctionOutput);
    }

    function test_hooks() public givenAuctionHasHook givenAuctionHouseHasBalance(_payoutAmount) {
        // Call
        vm.prank(_USER);
        _auctionHouse.sendPayout(_lotId, _RECIPIENT, _payoutAmount, _routingParams, _auctionOutput);

        // Check balances
        assertEq(_payoutToken.balanceOf(_USER), 0, "user balance mismatch");
        assertEq(_payoutToken.balanceOf(_OWNER), 0, "owner balance mismatch");
        assertEq(
            _payoutToken.balanceOf(address(_auctionHouse)), 0, "_auctionHouse balance mismatch"
        );
        assertEq(_payoutToken.balanceOf(address(_hook)), 0, "_hook balance mismatch");
        assertEq(_payoutToken.balanceOf(_RECIPIENT), _payoutAmount, "recipient balance mismatch");
        assertEq(
            _payoutToken.balanceOf(address(_mockDerivativeModule)),
            0,
            "derivative module balance mismatch"
        );

        // Check the _hook was called at the right time
        assertEq(_hook.preHookCalled(), false, "pre _hook mismatch");
        assertEq(_hook.midHookCalled(), false, "mid _hook mismatch");
        assertEq(_hook.postHookCalled(), true, "post _hook mismatch");
        assertEq(_hook.postHookBalances(_payoutToken, _USER), 0, "post _hook user balance mismatch");
        assertEq(
            _hook.postHookBalances(_payoutToken, _OWNER), 0, "post _hook owner balance mismatch"
        );
        assertEq(
            _hook.postHookBalances(_payoutToken, address(_auctionHouse)),
            0,
            "post _hook _auctionHouse balance mismatch"
        );
        assertEq(
            _hook.postHookBalances(_payoutToken, address(_hook)),
            0,
            "post _hook _hook balance mismatch"
        );
        assertEq(
            _hook.postHookBalances(_payoutToken, _RECIPIENT),
            _payoutAmount,
            "post _hook recipient balance mismatch"
        );
        assertEq(
            _hook.postHookBalances(_payoutToken, address(_mockDerivativeModule)),
            0,
            "post _hook derivative module balance mismatch"
        );
    }

    // ========== Non-hooks flow ========== //

    // [X] given the auction does not have hooks defined
    //  [X] given transferring the payout token would result in a lesser amount being received
    //   [X] it reverts
    //  [X] it succeeds - transfers the payout from the _auctionHouse to the recipient

    function test_noHooks_feeOnTransfer_reverts()
        public
        givenAuctionHouseHasBalance(_payoutAmount)
        givenTokenTakesFeeOnTransfer
    {
        // Expect revert
        bytes memory err =
            abi.encodeWithSelector(Transfer.UnsupportedToken.selector, address(_payoutToken));
        vm.expectRevert(err);

        // Call
        vm.prank(_USER);
        _auctionHouse.sendPayout(_lotId, _RECIPIENT, _payoutAmount, _routingParams, _auctionOutput);
    }

    function test_noHooks_insufficientBalance_reverts() public {
        // Expect revert
        vm.expectRevert(bytes("TRANSFER_FAILED"));

        // Call
        vm.prank(_USER);
        _auctionHouse.sendPayout(_lotId, _RECIPIENT, _payoutAmount, _routingParams, _auctionOutput);
    }

    function test_noHooks() public givenAuctionHouseHasBalance(_payoutAmount) {
        // Call
        vm.prank(_USER);
        _auctionHouse.sendPayout(_lotId, _RECIPIENT, _payoutAmount, _routingParams, _auctionOutput);

        // Check balances
        assertEq(_payoutToken.balanceOf(_USER), 0, "user balance mismatch");
        assertEq(_payoutToken.balanceOf(_OWNER), 0, "owner balance mismatch");
        assertEq(
            _payoutToken.balanceOf(address(_auctionHouse)), 0, "_auctionHouse balance mismatch"
        );
        assertEq(_payoutToken.balanceOf(address(_hook)), 0, "_hook balance mismatch");
        assertEq(_payoutToken.balanceOf(_RECIPIENT), _payoutAmount, "recipient balance mismatch");
        assertEq(
            _payoutToken.balanceOf(address(_mockDerivativeModule)),
            0,
            "derivative module balance mismatch"
        );
    }

    // ========== Derivative flow ========== //

    // [X] given the base token is a derivative
    //  [X] given a condenser is set
    //   [X] given the derivative parameters are invalid
    //     [X] it reverts
    //   [X] it uses the condenser to determine derivative parameters
    //  [X] given a condenser is not set
    //   [X] given the derivative is wrapped
    //    [X] given the derivative parameters are invalid
    //     [X] it reverts
    //    [X] it mints wrapped derivative tokens to the recipient using the derivative module
    //   [X] given the derivative is not wrapped
    //    [X] given the derivative parameters are invalid
    //     [X] it reverts
    //    [X] it mints derivative tokens to the recipient using the derivative module

    modifier givenAuctionHasDerivative() {
        // Install the derivative module
        _auctionHouse.installModule(_mockDerivativeModule);

        // Deploy a new derivative token
        MockDerivativeModule.DerivativeParams memory deployParams =
            MockDerivativeModule.DerivativeParams({expiry: _DERIVATIVE_EXPIRY, multiplier: 0});
        (uint256 tokenId,) =
            _mockDerivativeModule.deploy(address(_payoutToken), abi.encode(deployParams), false);

        // Update parameters
        _derivativeReference = _mockDerivativeModule.VEECODE();
        _derivativeTokenId = tokenId;
        _derivativeParams = abi.encode(deployParams);
        _routingParams.derivativeReference = _derivativeReference;
        _routingParams.derivativeParams = _derivativeParams;
        _;
    }

    modifier givenDerivativeIsWrapped() {
        // Deploy a new wrapped derivative token
        MockDerivativeModule.DerivativeParams memory deployParams =
            MockDerivativeModule.DerivativeParams({expiry: _DERIVATIVE_EXPIRY + 1, multiplier: 0}); // Different expiry which leads to a different token id
        (uint256 tokenId_, address wrappedToken_) =
            _mockDerivativeModule.deploy(address(_payoutToken), abi.encode(deployParams), true);

        // Update parameters
        _wrappedDerivative = ERC20(wrappedToken_);
        _derivativeTokenId = tokenId_;
        _derivativeParams = abi.encode(deployParams);
        _routingParams.derivativeParams = _derivativeParams;

        _wrapDerivative = true;
        _routingParams.wrapDerivative = _wrapDerivative;
        _;
    }

    modifier givenDerivativeHasCondenser() {
        // Install the condenser module
        _auctionHouse.installModule(_mockCondenserModule);

        // Set the condenser
        _auctionHouse.setCondenser(
            _mockAuctionModule.VEECODE(),
            _mockDerivativeModule.VEECODE(),
            _mockCondenserModule.VEECODE()
        );
        _;
    }

    modifier givenDerivativeParamsAreInvalid() {
        _derivativeParams = abi.encode("one", "two", uint256(2));
        _routingParams.derivativeParams = _derivativeParams;
        _;
    }

    function test_derivative_invalidParams()
        public
        givenAuctionHouseHasBalance(_payoutAmount)
        givenAuctionHasDerivative
        givenDerivativeParamsAreInvalid
    {
        // Expect revert while decoding parameters
        vm.expectRevert();

        // Call
        vm.prank(_USER);
        _auctionHouse.sendPayout(_lotId, _RECIPIENT, _payoutAmount, _routingParams, _auctionOutput);
    }

    function test_derivative_insufficientBalance_reverts() public givenAuctionHasDerivative {
        // Expect revert
        vm.expectRevert(bytes("TRANSFER_FROM_FAILED"));

        // Call
        vm.prank(_USER);
        _auctionHouse.sendPayout(_lotId, _RECIPIENT, _payoutAmount, _routingParams, _auctionOutput);
    }

    function test_derivative()
        public
        givenAuctionHouseHasBalance(_payoutAmount)
        givenAuctionHasDerivative
    {
        // Call
        vm.prank(_USER);
        _auctionHouse.sendPayout(_lotId, _RECIPIENT, _payoutAmount, _routingParams, _auctionOutput);

        // Check balances of the derivative token
        assertEq(
            _mockDerivativeModule.derivativeToken().balanceOf(_USER, _derivativeTokenId),
            0,
            "derivative token: user balance mismatch"
        );
        assertEq(
            _mockDerivativeModule.derivativeToken().balanceOf(_OWNER, _derivativeTokenId),
            0,
            "derivative token: owner balance mismatch"
        );
        assertEq(
            _mockDerivativeModule.derivativeToken().balanceOf(
                address(_auctionHouse), _derivativeTokenId
            ),
            0,
            "derivative token: _auctionHouse balance mismatch"
        );
        assertEq(
            _mockDerivativeModule.derivativeToken().balanceOf(address(_hook), _derivativeTokenId),
            0,
            "derivative token: _hook balance mismatch"
        );
        assertEq(
            _mockDerivativeModule.derivativeToken().balanceOf(_RECIPIENT, _derivativeTokenId),
            _payoutAmount,
            "derivative token: recipient balance mismatch"
        );
        assertEq(
            _mockDerivativeModule.derivativeToken().balanceOf(
                address(_mockDerivativeModule), _derivativeTokenId
            ),
            0,
            "derivative token: derivative module balance mismatch"
        );

        // Check balances of payout token
        assertEq(_payoutToken.balanceOf(_USER), 0, "payout token: user balance mismatch");
        assertEq(_payoutToken.balanceOf(_OWNER), 0, "payout token: owner balance mismatch");
        assertEq(
            _payoutToken.balanceOf(address(_auctionHouse)),
            0,
            "payout token: _auctionHouse balance mismatch"
        );
        assertEq(_payoutToken.balanceOf(address(_hook)), 0, "payout token: _hook balance mismatch");
        assertEq(_payoutToken.balanceOf(_RECIPIENT), 0, "payout token: recipient balance mismatch");
        assertEq(
            _payoutToken.balanceOf(address(_mockDerivativeModule)),
            _payoutAmount,
            "payout token: derivative module balance mismatch"
        );
    }

    function test_derivative_wrapped()
        public
        givenAuctionHouseHasBalance(_payoutAmount)
        givenAuctionHasDerivative
        givenDerivativeIsWrapped
    {
        // Call
        vm.prank(_USER);
        _auctionHouse.sendPayout(_lotId, _RECIPIENT, _payoutAmount, _routingParams, _auctionOutput);

        // Check balances of the wrapped derivative token
        assertEq(
            _wrappedDerivative.balanceOf(_USER),
            0,
            "wrapped derivative token: user balance mismatch"
        );
        assertEq(
            _wrappedDerivative.balanceOf(_OWNER),
            0,
            "wrapped derivative token: owner balance mismatch"
        );
        assertEq(
            _wrappedDerivative.balanceOf(address(_auctionHouse)),
            0,
            "wrapped derivative token: _auctionHouse balance mismatch"
        );
        assertEq(
            _wrappedDerivative.balanceOf(address(_hook)),
            0,
            "wrapped derivative token: _hook balance mismatch"
        );
        assertEq(
            _wrappedDerivative.balanceOf(_RECIPIENT),
            _payoutAmount,
            "wrapped derivative token: recipient balance mismatch"
        );
        assertEq(
            _wrappedDerivative.balanceOf(address(_mockDerivativeModule)),
            0,
            "wrapped derivative token: derivative module balance mismatch"
        );

        // Check balances of the derivative token
        assertEq(
            _mockDerivativeModule.derivativeToken().balanceOf(_USER, _derivativeTokenId),
            0,
            "derivative token: user balance mismatch"
        );
        assertEq(
            _mockDerivativeModule.derivativeToken().balanceOf(_OWNER, _derivativeTokenId),
            0,
            "derivative token: owner balance mismatch"
        );
        assertEq(
            _mockDerivativeModule.derivativeToken().balanceOf(
                address(_auctionHouse), _derivativeTokenId
            ),
            0,
            "derivative token: _auctionHouse balance mismatch"
        );
        assertEq(
            _mockDerivativeModule.derivativeToken().balanceOf(address(_hook), _derivativeTokenId),
            0,
            "derivative token: _hook balance mismatch"
        );
        assertEq(
            _mockDerivativeModule.derivativeToken().balanceOf(_RECIPIENT, _derivativeTokenId),
            0, // No raw derivative
            "derivative token: recipient balance mismatch"
        );
        assertEq(
            _mockDerivativeModule.derivativeToken().balanceOf(
                address(_mockDerivativeModule), _derivativeTokenId
            ),
            0,
            "derivative token: derivative module balance mismatch"
        );

        // Check balances of payout token
        assertEq(_payoutToken.balanceOf(_USER), 0, "payout token: user balance mismatch");
        assertEq(_payoutToken.balanceOf(_OWNER), 0, "payout token: owner balance mismatch");
        assertEq(
            _payoutToken.balanceOf(address(_auctionHouse)),
            0,
            "payout token: _auctionHouse balance mismatch"
        );
        assertEq(_payoutToken.balanceOf(address(_hook)), 0, "payout token: _hook balance mismatch");
        assertEq(_payoutToken.balanceOf(_RECIPIENT), 0, "payout token: recipient balance mismatch");
        assertEq(
            _payoutToken.balanceOf(address(_mockDerivativeModule)),
            _payoutAmount,
            "payout token: derivative module balance mismatch"
        );
    }

    function test_derivative_wrapped_invalidParams()
        public
        givenAuctionHouseHasBalance(_payoutAmount)
        givenAuctionHasDerivative
        givenDerivativeIsWrapped
        givenDerivativeParamsAreInvalid
    {
        // Expect revert while decoding parameters
        vm.expectRevert();

        // Call
        vm.prank(_USER);
        _auctionHouse.sendPayout(_lotId, _RECIPIENT, _payoutAmount, _routingParams, _auctionOutput);
    }

    function test_derivative_condenser_invalidParams_reverts()
        public
        givenAuctionHouseHasBalance(_payoutAmount)
        givenAuctionHasDerivative
        givenDerivativeHasCondenser
        givenDerivativeParamsAreInvalid
    {
        // Expect revert while decoding parameters
        vm.expectRevert();

        // Call
        vm.prank(_USER);
        _auctionHouse.sendPayout(_lotId, _RECIPIENT, _payoutAmount, _routingParams, _auctionOutput);
    }

    function test_derivative_condenser()
        public
        givenAuctionHouseHasBalance(_payoutAmount)
        givenAuctionHasDerivative
        givenDerivativeHasCondenser
    {
        // Call
        vm.prank(_USER);
        _auctionHouse.sendPayout(_lotId, _RECIPIENT, _payoutAmount, _routingParams, _auctionOutput);

        // Check balances of the derivative token
        assertEq(
            _mockDerivativeModule.derivativeToken().balanceOf(_USER, _derivativeTokenId),
            0,
            "user balance mismatch"
        );
        assertEq(
            _mockDerivativeModule.derivativeToken().balanceOf(_OWNER, _derivativeTokenId),
            0,
            "owner balance mismatch"
        );
        assertEq(
            _mockDerivativeModule.derivativeToken().balanceOf(
                address(_auctionHouse), _derivativeTokenId
            ),
            0,
            "_auctionHouse balance mismatch"
        );
        assertEq(
            _mockDerivativeModule.derivativeToken().balanceOf(address(_hook), _derivativeTokenId),
            0,
            "_hook balance mismatch"
        );
        assertEq(
            _mockDerivativeModule.derivativeToken().balanceOf(_RECIPIENT, _derivativeTokenId),
            _payoutAmount * _auctionOutputMultiplier, // Condenser multiplies the payout
            "recipient balance mismatch"
        );
        assertEq(
            _mockDerivativeModule.derivativeToken().balanceOf(
                address(_mockDerivativeModule), _derivativeTokenId
            ),
            0,
            "derivative module balance mismatch"
        );

        // Check balances of payout token
        assertEq(_payoutToken.balanceOf(_USER), 0, "user balance mismatch");
        assertEq(_payoutToken.balanceOf(_OWNER), 0, "owner balance mismatch");
        assertEq(
            _payoutToken.balanceOf(address(_auctionHouse)), 0, "_auctionHouse balance mismatch"
        );
        assertEq(_payoutToken.balanceOf(address(_hook)), 0, "_hook balance mismatch");
        assertEq(_payoutToken.balanceOf(_RECIPIENT), 0, "recipient balance mismatch");
        assertEq(
            _payoutToken.balanceOf(address(_mockDerivativeModule)),
            _payoutAmount,
            "derivative module balance mismatch"
        );
    }
}
