// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import {Test} from "forge-std/Test.sol";
import {MaxPriorityQueue, Queue, Bid} from "src/lib/MaxPriorityQueue.sol";

contract MaxPriorityQueueTest is Test {
    using MaxPriorityQueue for Queue;

    Queue internal queue;

    // [X] when added in ascending order
    // [X] when a single bid is added
    // [X] when a larger bid is added
    //  [X] it sorts in ascending order
    // [X] when a bid is added in the middle
    //  [X] it adds it to the middle
    // [X] duplicate bid id

    function test_insertAscendingPrice() external {
        queue.initialize();

        queue.insert(0, 1, 1);
        queue.insert(1, 2, 1);
        queue.insert(2, 3, 1);

        // Check values
        assertEq(queue.getNumBids(), 3);

        // Check order of values
        uint64 maxId = queue.getMaxId();
        assertEq(maxId, 2);
        Bid memory maxBid = queue.delMax();
        assertEq(maxBid.amountIn, 3);

        maxId = queue.getMaxId();
        assertEq(maxId, 1);
        maxBid = queue.delMax();
        assertEq(maxBid.amountIn, 2);

        maxId = queue.getMaxId();
        assertEq(maxId, 0);
        maxBid = queue.delMax();
        assertEq(maxBid.amountIn, 1);

        assertEq(queue.isEmpty(), true);
    }

    function test_singleBid() external {
        queue.initialize();

        queue.insert(0, 1, 1);

        // Check values
        assertEq(queue.getNumBids(), 1);

        // Check order of values
        uint64 maxId = queue.getMaxId();
        assertEq(maxId, 0);
        Bid memory maxBid = queue.delMax();
        assertEq(maxBid.amountIn, 1);

        assertEq(queue.isEmpty(), true);
    }

    function test_addLargerBid() external {
        queue.initialize();

        queue.insert(0, 1, 1);
        queue.insert(1, 4, 2);

        // Check values
        assertEq(queue.getNumBids(), 2);

        // Check order of values
        uint64 maxId = queue.getMaxId();
        assertEq(maxId, 1);
        Bid memory maxBid = queue.delMax();
        assertEq(maxBid.amountIn, 4);

        maxId = queue.getMaxId();
        assertEq(maxId, 0);
        maxBid = queue.delMax();
        assertEq(maxBid.amountIn, 1);

        assertEq(queue.isEmpty(), true);
    }

    function test_addBidInMiddle() external {
        queue.initialize();

        queue.insert(0, 1, 1);
        queue.insert(1, 3, 1);
        queue.insert(2, 2, 1);

        // Check values
        assertEq(queue.getNumBids(), 3);

        // Check order of values
        uint64 maxId = queue.getMaxId();
        assertEq(maxId, 1);
        Bid memory maxBid = queue.delMax();
        assertEq(maxBid.amountIn, 3);

        maxId = queue.getMaxId();
        assertEq(maxId, 2);
        maxBid = queue.delMax();
        assertEq(maxBid.amountIn, 2);

        maxId = queue.getMaxId();
        assertEq(maxId, 0);
        maxBid = queue.delMax();
        assertEq(maxBid.amountIn, 1);

        assertEq(queue.isEmpty(), true);
    }

    function test_duplicateBidId() external {
        queue.initialize();

        queue.insert(0, 1, 1);
        queue.insert(0, 3, 1);

        // Check values
        assertEq(queue.getNumBids(), 2, "numBids mismatch");

        // Check order of values
        uint64 maxId = queue.getMaxId();
        assertEq(maxId, 0, "index 0: maxId mismatch");
        Bid memory maxBid = queue.delMax();
        assertEq(maxBid.amountIn, 3, "index 0: amountIn mismatch");

        maxId = queue.getMaxId();
        assertEq(maxId, 0, "index 1: maxId mismatch");
        maxBid = queue.delMax();
        assertEq(maxBid.amountIn, 1, "index 1: amountIn mismatch");

        assertEq(queue.isEmpty(), true, "isEmpty mismatch");
    }
}
