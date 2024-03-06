// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

// Libraries
import {Test} from "forge-std/Test.sol";
import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";

// Mocks
import {MockERC20} from "lib/solmate/src/test/utils/mocks/MockERC20.sol";
import {MockAuctionModule} from "test/modules/Auction/MockAuctionModule.sol";
import {Permit2User} from "test/lib/permit2/Permit2User.sol";

// Auctions
import {AuctionHouse} from "src/AuctionHouse.sol";
import {Auction} from "src/modules/Auction.sol";
import {IHooks, IAllowlist, Auctioneer} from "src/bases/Auctioneer.sol";

// Modules
import {
    Keycode,
    toKeycode,
    Veecode,
    wrapVeecode,
    fromVeecode,
    WithModules,
    Module
} from "src/modules/Modules.sol";

contract CancelTest is Test, Permit2User {
    MockERC20 internal baseToken;
    MockERC20 internal quoteToken;
    MockAuctionModule internal mockAuctionModule;

    AuctionHouse internal auctionHouse;
    Auctioneer.RoutingParams internal routingParams;
    Auction.AuctionParams internal auctionParams;

    uint96 internal lotId;

    address internal constant _SELLER = address(0x1);

    address internal protocol = address(0x2);
    string internal INFO_HASH = "";

    function setUp() external {
        baseToken = new MockERC20("Base Token", "BASE", 18);
        quoteToken = new MockERC20("Quote Token", "QUOTE", 18);

        auctionHouse = new AuctionHouse(address(this), protocol, _PERMIT2_ADDRESS);
        mockAuctionModule = new MockAuctionModule(address(auctionHouse));

        auctionHouse.installModule(mockAuctionModule);

        auctionParams = Auction.AuctionParams({
            start: uint48(block.timestamp),
            duration: uint48(1 days),
            capacityInQuote: false,
            capacity: 10e18,
            implParams: abi.encode("")
        });

        routingParams = Auctioneer.RoutingParams({
            auctionType: toKeycode("MOCK"),
            baseToken: baseToken,
            quoteToken: quoteToken,
            curator: address(0),
            hooks: IHooks(address(0)),
            allowlist: IAllowlist(address(0)),
            allowlistParams: abi.encode(""),
            derivativeType: toKeycode(""),
            derivativeParams: abi.encode("")
        });
    }

    modifier whenLotIsCreated() {
        vm.prank(_SELLER);
        lotId = auctionHouse.auction(routingParams, auctionParams, INFO_HASH);
        _;
    }

    // cancel
    // [X] reverts if not the parent
    // [X] reverts if lot id is invalid
    // [X] reverts if lot is not active
    // [X] sets the lot to inactive

    function testReverts_whenCallerIsNotParent() external whenLotIsCreated {
        bytes memory err = abi.encodeWithSelector(Module.Module_OnlyParent.selector, address(this));
        vm.expectRevert(err);

        mockAuctionModule.cancelAuction(lotId);
    }

    function testReverts_whenLotIdInvalid() external {
        bytes memory err = abi.encodeWithSelector(Auction.Auction_InvalidLotId.selector, lotId);
        vm.expectRevert(err);

        vm.prank(address(auctionHouse));
        mockAuctionModule.cancelAuction(lotId);
    }

    function testReverts_whenLotIsInactive() external whenLotIsCreated {
        // Cancel once
        vm.prank(address(auctionHouse));
        mockAuctionModule.cancelAuction(lotId);

        // Cancel again
        bytes memory err = abi.encodeWithSelector(Auction.Auction_MarketNotActive.selector, lotId);
        vm.expectRevert(err);

        vm.prank(address(auctionHouse));
        mockAuctionModule.cancelAuction(lotId);
    }

    function test_success() external whenLotIsCreated {
        assertTrue(mockAuctionModule.isLive(lotId), "before cancellation: isLive mismatch");

        vm.prank(address(auctionHouse));
        mockAuctionModule.cancelAuction(lotId);

        // Get lot data from the module
        Auction.Lot memory lot = mockAuctionModule.getLot(lotId);
        assertEq(lot.conclusion, uint48(block.timestamp));
        assertEq(lot.capacity, 0);

        assertFalse(mockAuctionModule.isLive(lotId), "after cancellation: isLive mismatch");
    }
}
