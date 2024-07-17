// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.19;

import {FixedPriceBatch} from "../../../../modules/auctions/batch/FPB.sol";
import {BlastGas} from "../../BlastGas.sol";

contract BlastFPB is FixedPriceBatch, BlastGas {
    // ========== CONSTRUCTOR ========== //

    constructor(
        address auctionHouse_,
        address blast_
    ) FixedPriceBatch(auctionHouse_) BlastGas(auctionHouse_, blast_) {}
}
