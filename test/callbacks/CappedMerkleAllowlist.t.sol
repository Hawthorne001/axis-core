// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import {Test} from "forge-std/Test.sol";
import {Callbacks} from "src/lib/Callbacks.sol";
import {Permit2User} from "test/lib/permit2/Permit2User.sol";

import {AtomicAuctionHouse} from "src/AtomicAuctionHouse.sol";
import {BatchAuctionHouse} from "src/BatchAuctionHouse.sol";

import {BaseCallback} from "src/callbacks/BaseCallback.sol";

import {CappedMerkleAllowlist} from "src/callbacks/allowlists/CappedMerkleAllowlist.sol";

contract CappedMerkleAllowlistTest is Test, Permit2User {
    using Callbacks for CappedMerkleAllowlist;

    address internal constant _OWNER = address(0x1);
    address internal constant _PROTOCOL = address(0x2);
    address internal constant _SELLER = address(0x3);
    address internal constant _BUYER = address(0x4);
    address internal constant _BUYER_TWO = address(0x5);
    address internal constant _BASE_TOKEN = address(0x6);
    address internal constant _QUOTE_TOKEN = address(0x7);
    address internal constant _SELLER_TWO = address(0x8);
    address internal constant _BUYER_THREE = address(0x9);

    uint256 internal constant _LOT_CAPACITY = 10e18;

    uint96 internal _lotId = 1;

    AtomicAuctionHouse internal _atomicAuctionHouse;
    BatchAuctionHouse internal _batchAuctionHouse;
    CappedMerkleAllowlist internal _atomicAllowlist;
    CappedMerkleAllowlist internal _batchAllowlist;

    uint256 internal constant _BUYER_LIMIT = 1e18;
    // Generated from: https://lab.miguelmota.com/merkletreejs/example/
    // Includes _BUYER, _BUYER_TWO but not _BUYER_THREE
    bytes32 internal constant _MERKLE_ROOT =
        0x40e51f1c845d99162de6c210a9eaff4729f433ac605be8f3cde6d2e0afa44aeb;
    bytes32[] internal _merkleProof;

    function setUp() public {
        _atomicAuctionHouse = new AtomicAuctionHouse(_OWNER, _PROTOCOL, _permit2Address);
        _batchAuctionHouse = new BatchAuctionHouse(_OWNER, _PROTOCOL, _permit2Address);

        // // 10010000 = 0x90
        // bytes memory bytecode = abi.encodePacked(
        //     type(CappedMerkleAllowlist).creationCode,
        //     abi.encode(
        //         address(_atomicAuctionHouse),
        //         Callbacks.Permissions({
        //             onCreate: true,
        //             onCancel: false,
        //             onCurate: false,
        //             onPurchase: true,
        //             onBid: false,
        //             onClaimProceeds: false,
        //             receiveQuoteTokens: false,
        //             sendBaseTokens: false
        //         }),
        //         _SELLER
        //     )
        // );
        // vm.writeFile("./bytecode/CappedMerkleAllowlistAtomic90.bin", vm.toString(bytecode));
        // // 10001000 = 0x88
        // bytecode = abi.encodePacked(
        //     type(CappedMerkleAllowlist).creationCode,
        //     abi.encode(
        //         address(_batchAuctionHouse),
        //         Callbacks.Permissions({
        //             onCreate: true,
        //             onCancel: false,
        //             onCurate: false,
        //             onPurchase: false,
        //             onBid: true,
        //             onClaimProceeds: false,
        //             receiveQuoteTokens: false,
        //             sendBaseTokens: false
        //         }),
        //         _SELLER
        //     )
        // );
        // vm.writeFile("./bytecode/CappedMerkleAllowlistBatch88.bin", vm.toString(bytecode));

        // cast create2 -s 90 -i $(cat ./bytecode/CappedMerkleAllowlistAtomic90.bin)
        bytes32 atomicSalt =
            bytes32(0x15d20025759e16be1d91f6c9c6c4c188b5d480d28b35c1b6bde843fc03927c5b);
        vm.broadcast();
        _atomicAllowlist = new CappedMerkleAllowlist{salt: atomicSalt}(
            address(_atomicAuctionHouse),
            Callbacks.Permissions({
                onCreate: true,
                onCancel: false,
                onCurate: false,
                onPurchase: true,
                onBid: false,
                onClaimProceeds: false,
                receiveQuoteTokens: false,
                sendBaseTokens: false
            }),
            _SELLER
        );

        // cast create2 -s 88 -i $(cat ./bytecode/CappedMerkleAllowlistBatch88.bin)
        bytes32 batchSalt =
            bytes32(0xe5ac433cbb37a89e6ca69e2a407b8d3f5b413528778a0dbd34eee744daf9e7c9);
        vm.broadcast();
        _batchAllowlist = new CappedMerkleAllowlist{salt: batchSalt}(
            address(_batchAuctionHouse),
            Callbacks.Permissions({
                onCreate: true,
                onCancel: false,
                onCurate: false,
                onPurchase: false,
                onBid: true,
                onClaimProceeds: false,
                receiveQuoteTokens: false,
                sendBaseTokens: false
            }),
            _SELLER
        );

        _merkleProof.push(
            bytes32(0x421df1fa259221d02aa4956eb0d35ace318ca24c0a33a64c1af96cf67cf245b6)
        ); // Corresponds to _BUYER
            // _merkleProof.push(
            //     bytes32(0xa876da518a393dbd067dc72abfa08d475ed6447fca96d92ec3f9e7eba503ca61)
            // ); // Corresponds to _BUYER_TWO
    }

    modifier givenAtomicOnCreate() {
        vm.prank(address(_atomicAuctionHouse));
        _atomicAllowlist.onCreate(
            _lotId,
            _SELLER,
            _BASE_TOKEN,
            _QUOTE_TOKEN,
            _LOT_CAPACITY,
            false,
            abi.encode(_MERKLE_ROOT, _BUYER_LIMIT)
        );
        _;
    }

    modifier givenBatchOnCreate() {
        vm.prank(address(_batchAuctionHouse));
        _batchAllowlist.onCreate(
            _lotId,
            _SELLER,
            _BASE_TOKEN,
            _QUOTE_TOKEN,
            _LOT_CAPACITY,
            false,
            abi.encode(_MERKLE_ROOT, _BUYER_LIMIT)
        );
        _;
    }

    function _onPurchase(uint96 lotId_, address buyer_, uint256 amount_) internal {
        vm.prank(address(_atomicAuctionHouse));
        _atomicAllowlist.onPurchase(lotId_, buyer_, amount_, 0, false, abi.encode(_merkleProof));
    }

    function _onBid(uint96 lotId_, address buyer_, uint256 amount_) internal {
        vm.prank(address(_batchAuctionHouse));
        _batchAllowlist.onBid(lotId_, 1, buyer_, amount_, abi.encode(_merkleProof));
    }

    // onCreate
    // [X] if the caller is not the auction house
    //  [X] it reverts
    // [X] if the seller is not the seller for the allowlist
    //  [X] it reverts
    // [X] if the lot is already registered
    //  [X] it reverts
    // [X] it sets the merkle root and buyer limit

    function test_onCreate_callerNotAuctionHouse_reverts() public {
        // Expect revert
        bytes memory err = abi.encodeWithSelector(BaseCallback.Callback_NotAuthorized.selector);
        vm.expectRevert(err);

        _atomicAllowlist.onCreate(
            _lotId,
            _SELLER,
            _BASE_TOKEN,
            _QUOTE_TOKEN,
            _LOT_CAPACITY,
            false,
            abi.encode(_MERKLE_ROOT, _BUYER_LIMIT)
        );
    }

    function test_onCreate_sellerNotSeller_reverts() public {
        // Expect revert
        bytes memory err = abi.encodeWithSelector(BaseCallback.Callback_NotAuthorized.selector);
        vm.expectRevert(err);

        vm.prank(address(_atomicAuctionHouse));
        _atomicAllowlist.onCreate(
            _lotId,
            _SELLER_TWO,
            _BASE_TOKEN,
            _QUOTE_TOKEN,
            _LOT_CAPACITY,
            false,
            abi.encode(_MERKLE_ROOT, _BUYER_LIMIT)
        );
    }

    function test_onCreate_alreadyRegistered_reverts() public givenAtomicOnCreate {
        // Expect revert
        bytes memory err = abi.encodeWithSelector(BaseCallback.Callback_InvalidParams.selector);
        vm.expectRevert(err);

        vm.prank(address(_atomicAuctionHouse));
        _atomicAllowlist.onCreate(
            _lotId,
            _SELLER,
            _BASE_TOKEN,
            _QUOTE_TOKEN,
            _LOT_CAPACITY,
            false,
            abi.encode(_MERKLE_ROOT, _BUYER_LIMIT)
        );
    }

    function test_onCreate() public givenAtomicOnCreate {
        assertEq(_atomicAllowlist.lotIdRegistered(_lotId), true, "lotIdRegistered");
        assertEq(_atomicAllowlist.lotMerkleRoot(_lotId), _MERKLE_ROOT, "lotMerkleRoot");
        assertEq(_atomicAllowlist.lotBuyerLimit(_lotId), _BUYER_LIMIT, "lotBuyerLimit");
    }

    // onPurchase
    // [X] if the caller is not the auction house
    //  [X] it reverts
    // [X] if the lot is not registered
    //  [X] it reverts
    // [X] if the buyer is not in the merkle tree
    //  [X] it reverts
    // [X] if the amount is greater than the buyer limit
    //  [X] it reverts
    // [X] if the previous buyer spent plus the amount is greater than the buyer limit
    //  [X] it reverts
    // [X] it updates the buyer spent

    function test_onPurchase_callerNotAuctionHouse_reverts() public givenAtomicOnCreate {
        // Expect revert
        bytes memory err = abi.encodeWithSelector(BaseCallback.Callback_NotAuthorized.selector);
        vm.expectRevert(err);

        _atomicAllowlist.onPurchase(_lotId, _BUYER, 1e18, 0, false, "");
    }

    function test_onPurchase_lotNotRegistered_reverts() public {
        // Expect revert
        bytes memory err = abi.encodeWithSelector(BaseCallback.Callback_NotAuthorized.selector);
        vm.expectRevert(err);

        _onPurchase(_lotId, _BUYER, 1e18);
    }

    function test_onPurchase_buyerNotInMerkleTree_reverts() public givenAtomicOnCreate {
        // Expect revert
        bytes memory err = abi.encodeWithSelector(BaseCallback.Callback_NotAuthorized.selector);
        vm.expectRevert(err);

        _onPurchase(_lotId, _BUYER_THREE, 1e18);
    }

    function test_onPurchase_amountGreaterThanBuyerLimit_reverts() public givenAtomicOnCreate {
        // Expect revert
        bytes memory err =
            abi.encodeWithSelector(CappedMerkleAllowlist.Callback_ExceedsLimit.selector);
        vm.expectRevert(err);

        _onPurchase(_lotId, _BUYER, _BUYER_LIMIT + 1);
    }

    function test_onPurchase_previousBuyerSpentPlusAmountGreaterThanBuyerLimit_reverts()
        public
        givenAtomicOnCreate
    {
        _onPurchase(_lotId, _BUYER, _BUYER_LIMIT);

        // Expect revert
        bytes memory err =
            abi.encodeWithSelector(CappedMerkleAllowlist.Callback_ExceedsLimit.selector);
        vm.expectRevert(err);

        _onPurchase(_lotId, _BUYER, 1);
    }

    function test_onPurchase(uint256 amount_) public givenAtomicOnCreate {
        uint256 amount = bound(amount_, 1, _BUYER_LIMIT);

        _onPurchase(_lotId, _BUYER, amount);

        assertEq(_atomicAllowlist.lotBuyerSpent(_lotId, _BUYER), amount, "lotBuyerSpent");
    }

    // onBid
    // [X] if the caller is not the auction house
    //  [X] it reverts
    // [X] if the lot is not registered
    //  [X] it reverts
    // [X] if the buyer is not in the merkle tree
    //  [X] it reverts
    // [X] if the amount is greater than the buyer limit
    //  [X] it reverts
    // [X] if the previous buyer spent plus the amount is greater than the buyer limit
    //  [X] it reverts
    // [X] it updates the buyer spent

    function test_onBid_callerNotAuctionHouse_reverts() public givenBatchOnCreate {
        // Expect revert
        bytes memory err = abi.encodeWithSelector(BaseCallback.Callback_NotAuthorized.selector);
        vm.expectRevert(err);

        _batchAllowlist.onBid(_lotId, 1, _BUYER, 1e18, "");
    }

    function test_onBid_lotNotRegistered_reverts() public {
        // Expect revert
        bytes memory err = abi.encodeWithSelector(BaseCallback.Callback_NotAuthorized.selector);
        vm.expectRevert(err);

        _onBid(_lotId, _BUYER, 1e18);
    }

    function test_onBid_buyerNotInMerkleTree_reverts() public givenBatchOnCreate {
        // Expect revert
        bytes memory err = abi.encodeWithSelector(BaseCallback.Callback_NotAuthorized.selector);
        vm.expectRevert(err);

        _onBid(_lotId, _BUYER_THREE, 1e18);
    }

    function test_onBid_amountGreaterThanBuyerLimit_reverts() public givenBatchOnCreate {
        // Expect revert
        bytes memory err =
            abi.encodeWithSelector(CappedMerkleAllowlist.Callback_ExceedsLimit.selector);
        vm.expectRevert(err);

        _onBid(_lotId, _BUYER, _BUYER_LIMIT + 1);
    }

    function test_onBid_previousBuyerSpentPlusAmountGreaterThanBuyerLimit_reverts()
        public
        givenBatchOnCreate
    {
        _onBid(_lotId, _BUYER, _BUYER_LIMIT);

        // Expect revert
        bytes memory err =
            abi.encodeWithSelector(CappedMerkleAllowlist.Callback_ExceedsLimit.selector);
        vm.expectRevert(err);

        _onBid(_lotId, _BUYER, 1);
    }

    function test_onBid(uint256 amount_) public givenBatchOnCreate {
        uint256 amount = bound(amount_, 1, _BUYER_LIMIT);

        _onBid(_lotId, _BUYER, amount);

        assertEq(_batchAllowlist.lotBuyerSpent(_lotId, _BUYER), amount, "lotBuyerSpent");
    }
}
