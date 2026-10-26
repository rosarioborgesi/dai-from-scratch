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

import {Shutdown} from "./Shutdown.sol";

interface VatLike {
    function file(bytes32, bytes32, uint256) external;
}

interface PipLike {
    function peek() external returns (bytes32, bool);
}

contract Spotter is Shutdown {
    ////////////////////////////////
    //            Errors          //
    ////////////////////////////////
    error Spot__NotLive();
    error Spot__NotAuthorized();

    //////////////////////////////////////////
    //           Type declarations          //
    ////////////////////////////////////////// 
    struct Ilk {
        PipLike pip;  // Price Feed
        uint256 mat;  // Liquidation ratio [ray]
    }

    ////////////////////////////////////////
    //           State variables          //
    ////////////////////////////////////////
    mapping(bytes32 ilk => Ilk data) private s_ilks;

    VatLike private immutable i_vat;

    uint256 private s_par; // ref per dai [ray]

    uint256 constant ONE = 1e27; // 1 Ray = 1.0

    ///////////////////////////////
    //           Events          //
    ///////////////////////////////
    event Poke(
      bytes32 ilk,
      bytes32 val,  // [wad]
      uint256 spot  // [ray]
    );

    //////////////////////////////////
    //           Functions          //
    //////////////////////////////////
    constructor (address vat) {
        i_vat = VatLike(vat);
        s_par = ONE;
    }

    ////////////////////////////////////////////
    //            Internal Functions          //
    ////////////////////////////////////////////
    function _revertNotLive() internal pure override {
        revert Spot__NotLive();
    }

    function _revertNotAuthorized() internal pure override {
        revert Spot__NotAuthorized();
    }

    //function _rdiv

    //////////////////////////////////////////////////////
    //      External & Public View & Pure Functions     //
    //////////////////////////////////////////////////////
    function ilks(bytes32 ilk) external view returns(Ilk memory) {
        return s_ilks[ilk];
    }
}
