// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Auth} from "./Auth.sol";

/// @notice Provides an independent, irreversible shutdown flag for each inheriting contract.
abstract contract Shutdown is Auth {
    // Indicates whether the contract is active (1) or shut down (0)
    uint256 private s_live; // Active Flag

    event Cage();

    modifier isAlive() {
        if (s_live != 1) {
            _revertNotLive();
        }
        _;
    }

    constructor() {
        // Sets the contract as active
        s_live = 1;
    }

    function cage() external auth {
        s_live = 0;
        emit Cage();
    }

    function _revertNotLive() internal pure virtual;

    function live() external view returns (uint256) {
        return s_live;
    }
}
