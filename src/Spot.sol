// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// internal & private view & pure functions
// external & public view & pure functions

// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Auth} from "./Auth.sol";

interface VatLike {
    function file(bytes32, bytes32, uint256) external;
}

interface PipLike {
    function peek() external returns (bytes32, bool);
}

contract Spotter {}
