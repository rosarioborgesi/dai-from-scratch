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

import {Shutdown} from "../Shutdown.sol";

interface DSTokenLike {
    function mint(address, uint256) external;
    function burn(address, uint256) external;
}

interface VatLike {
    function slip(bytes32, address, int256) external;
    function move(address, address, uint256) external;
}

contract DaiJoin is Shutdown {
    ////////////////////////////////
    //            Errors          //
    ////////////////////////////////
    error DaiJoin__NotAuthorized();
    error DaiJoin__NotLive();

    /////////////////////////////////////////
    //            State Variables          //
    /////////////////////////////////////////
    // Vat associated with this join
    VatLike private immutable i_vat;

    // Dai token associated with this join
    DSTokenLike private immutable i_dai;

    uint256 constant RAY = 1e27;

    ////////////////////////////////
    //            Events          //
    ////////////////////////////////
    event Join(address indexed usr, uint256 wad);
    event Exit(address indexed user, uint256 wad);

    ///////////////////////////////////
    //            Functions          //
    ///////////////////////////////////
    constructor(address vat, address dai) {
        // Initializes the Vat
        i_vat = VatLike(vat);
        // Initializes the Dai token
        i_dai = DSTokenLike(dai);
    }

    ////////////////////////////////////////////
    //            External Functions          //
    ////////////////////////////////////////////

    // Converts external Dai into an internal Dai balance
    function join(address user, uint256 wad) external {
        // Moves internal Dai from the adapter to user
        i_vat.move(address(this), user, RAY * wad);
        // Burns external Dai units from msg.sender
        i_dai.burn(msg.sender, wad);
        emit Join(user, wad);
    }

    // Converts the the caller's internal Dai balance in the Vat into external Dai tokens.
    function exit(address user, uint256 wad) external isAlive {
        // Moves internal Dai from the caller's into the adapter
        i_vat.move(msg.sender, address(this), RAY * wad);
        // Mints external Dai to the user.
        i_dai.mint(user, wad);
        emit Exit(user, wad);
    }

    /////////////////////////////////
    //      Internal Functions     //
    /////////////////////////////////
    function _revertNotLive() internal pure override {
        revert DaiJoin__NotLive();
    }

    function _revertNotAuthorized() internal pure override {
        revert DaiJoin__NotAuthorized();
    }

    //////////////////////////////////////////////////////
    //      External & Public View & Pure Functions     //
    //////////////////////////////////////////////////////
    function dai() external view returns (DSTokenLike) {
        return i_dai;
    }
}

