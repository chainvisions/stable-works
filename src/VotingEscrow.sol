// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

/// @title Voting Escrow
/// @author Curve Finance, implemented into Solidity by Stable.Works
/// @notice Contract for locking tokens up for voting power

contract VotingEscrow {

    struct Point {
        int128 bias;
        int128 slope;
        uint256 ts;
        uint256 blk;
    }

    struct LockedBalance {
        int128 amount;
        uint256 end;
    }

}