/// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.19;

import {Test} from "forge-std/Test.sol";

import {MockCallback} from "test/AuctionHouse/MockCallback.sol";
import {MockAuctionHouse} from "test/AuctionHouse/MockAuctionHouse.sol";
import {MockFeeOnTransferERC20} from "test/lib/mocks/MockFeeOnTransferERC20.sol";
import {Permit2User} from "test/lib/permit2/Permit2User.sol";
import {Callbacks} from "src/lib/Callbacks.sol";

contract SendPaymentTest is Test, Permit2User {
    MockAuctionHouse internal _auctionHouse;

    address internal constant _OWNER = address(0x1);
    address internal constant _PROTOCOL = address(0x2);
    address internal constant _USER = address(0x3);
    address internal constant _SELLER = address(0x4);

    // Function parameters
    uint256 internal _paymentAmount = 1e18;
    MockFeeOnTransferERC20 internal _quoteToken;
    MockCallback internal _callback;
    bool internal _callbackReceiveQuoteTokens;

    function setUp() public {
        // Set reasonable starting block
        vm.warp(1_000_000);

        // Create an AuctionHouse at a deterministic address, since it is used as input to callbacks
        MockAuctionHouse mockAuctionHouse = new MockAuctionHouse(_OWNER, _PROTOCOL, _permit2Address);
        _auctionHouse = MockAuctionHouse(address(0x000000000000000000000000000000000000000A));
        vm.etch(address(_auctionHouse), address(mockAuctionHouse).code);
        vm.store(address(_auctionHouse), bytes32(uint256(0)), bytes32(abi.encode(_OWNER))); // Owner
        vm.store(address(_auctionHouse), bytes32(uint256(6)), bytes32(abi.encode(1))); // Reentrancy
        vm.store(address(_auctionHouse), bytes32(uint256(10)), bytes32(abi.encode(_PROTOCOL))); // Protocol

        _quoteToken = new MockFeeOnTransferERC20("Quote Token", "QUOTE", 18);
        _quoteToken.setTransferFee(0);
    }

    // [X] given the auction has hooks defined
    //  [X] it transfers the payment amount to the _callback
    // [X] given the auction does not have hooks defined
    //  [X] it transfers the payment amount to the seller

    modifier givenCallbackReceivesQuoteTokens() {
        _callbackReceiveQuoteTokens = true;
        _;
    }

    modifier givenAuctionHasCallback() {
        // // 00000000 - 0x00
        // // cast create2 -s 00 -i $(cat ./bytecode/MockCallback00.bin)
        // bytes memory bytecode = abi.encodePacked(
        //     type(MockCallback).creationCode,
        //     abi.encode(address(_auctionHouse), Callbacks.Permissions({
        //         onCreate: false,
        //         onCancel: false,
        //         onCurate: false,
        //         onPurchase: false,
        //         onBid: false,
        //         onClaimProceeds: false,
        //         receiveQuoteTokens: false,
        //         sendBaseTokens: false
        //     }), _SELLER)
        // );
        // vm.writeFile(
        //     "./bytecode/MockCallback00.bin",
        //     vm.toString(bytecode)
        // );
        // // 00000010 - 0x02
        // // cast create2 -s 02 -i $(cat ./bytecode/MockCallback02.bin)
        // bytecode = abi.encodePacked(
        //     type(MockCallback).creationCode,
        //     abi.encode(address(_auctionHouse), Callbacks.Permissions({
        //         onCreate: false,
        //         onCancel: false,
        //         onCurate: false,
        //         onPurchase: false,
        //         onBid: false,
        //         onClaimProceeds: false,
        //         receiveQuoteTokens: true,
        //         sendBaseTokens: false
        //     }), _SELLER)
        // );
        // vm.writeFile(
        //     "./bytecode/MockCallback02.bin",
        //     vm.toString(bytecode)
        // );

        bytes32 salt;
        if (_callbackReceiveQuoteTokens) {
            // 0x02
            salt = bytes32(0x35d2a61c56028e76b6f4cee8fd93d70cb8299b526f3de560e8db7a3c0abaa2d6);
        } else {
            // 0x00
            salt = bytes32(0xa2f366be17fbc94c1253f9916f341d254dc7a21c78212e6a49ebcdf683933c53);
        }

        vm.broadcast(); // required for CREATE2 address to work correctly. doesn't do anything in a test
        _callback = new MockCallback{salt: salt}(
            address(_auctionHouse),
            Callbacks.Permissions({
                onCreate: false,
                onCancel: false,
                onCurate: false,
                onPurchase: false,
                onBid: false,
                onClaimProceeds: false,
                receiveQuoteTokens: _callbackReceiveQuoteTokens,
                sendBaseTokens: false
            }),
            _SELLER
        );
        _;
    }

    modifier givenRouterHasBalance(uint256 amount_) {
        _quoteToken.mint(address(_auctionHouse), amount_);
        _;
    }

    function test_givenAuctionHasCallback_givenReceivesTokens()
        public
        givenCallbackReceivesQuoteTokens
        givenAuctionHasCallback
        givenRouterHasBalance(_paymentAmount)
    {
        // Call
        vm.prank(_USER);
        _auctionHouse.sendPayment(_SELLER, _paymentAmount, _quoteToken, _callback);

        // Check balances
        assertEq(_quoteToken.balanceOf(_USER), 0, "user balance mismatch");
        assertEq(_quoteToken.balanceOf(_SELLER), 0, "seller balance mismatch");
        assertEq(_quoteToken.balanceOf(address(_auctionHouse)), 0, "_auctionHouse balance mismatch");
        assertEq(
            _quoteToken.balanceOf(address(_callback)), _paymentAmount, "_callback balance mismatch"
        );
    }

    function test_givenAuctionHasCallback()
        public
        givenAuctionHasCallback
        givenRouterHasBalance(_paymentAmount)
    {
        // Call
        vm.prank(_USER);
        _auctionHouse.sendPayment(_SELLER, _paymentAmount, _quoteToken, _callback);

        // Check balances
        assertEq(_quoteToken.balanceOf(_USER), 0, "user balance mismatch");
        assertEq(_quoteToken.balanceOf(_SELLER), _paymentAmount, "seller balance mismatch");
        assertEq(_quoteToken.balanceOf(address(_auctionHouse)), 0, "_auctionHouse balance mismatch");
        assertEq(_quoteToken.balanceOf(address(_callback)), 0, "_callback balance mismatch");
    }

    function test_givenAuctionHasNoCallback() public givenRouterHasBalance(_paymentAmount) {
        // Call
        vm.prank(_USER);
        _auctionHouse.sendPayment(_SELLER, _paymentAmount, _quoteToken, _callback);

        // Check balances
        assertEq(_quoteToken.balanceOf(_USER), 0, "user balance mismatch");
        assertEq(_quoteToken.balanceOf(_SELLER), _paymentAmount, "seller balance mismatch");
        assertEq(_quoteToken.balanceOf(address(_auctionHouse)), 0, "_auctionHouse balance mismatch");
    }
}
