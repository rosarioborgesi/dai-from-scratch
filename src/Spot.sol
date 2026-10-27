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
import {Math} from "./libraries/Math.sol";

interface VatLike {
    function file(bytes32, bytes32, uint256) external;
}

interface PipLike {
    function peek() external returns (bytes32, bool);
}

// This contract calculates the Price with Safety Margin (spot) of your collateral (ilk)
// And writes it into the Vat. The poke function does this calculation.
contract Spotter is Shutdown {
    ///////////////////////////////////
    //            Libraries          //
    ///////////////////////////////////
    using Math for uint256;

    ////////////////////////////////
    //            Errors          //
    ////////////////////////////////
    error Spotter__NotLive();
    error Spotter__NotAuthorized();
    error Spotter__FileUnrecognizedParam();

    ///////////////////////////////////
    //            Libraries          //
    ///////////////////////////////////
    using Math for uint256;

    //////////////////////////////////////////
    //           Type declarations          //
    //////////////////////////////////////////
    struct Ilk {
        PipLike pip; // Price Feed
        uint256 mat; // Liquidation ratio [ray]
    }

    ////////////////////////////////////////
    //           State variables          //
    ////////////////////////////////////////
    mapping(bytes32 ilk => Ilk data) private s_ilks;

    VatLike private immutable i_vat;

    uint256 private s_par; // [ray] value of DAI in the reference asset (e.g. $1 per DAI)

    ///////////////////////////////
    //           Events          //
    ///////////////////////////////
    event Poke(
        bytes32 ilk,
        bytes32 val, // [wad]
        uint256 spot // [ray]
    );

    //////////////////////////////////
    //           Functions          //
    //////////////////////////////////
    constructor(address vat) {
        i_vat = VatLike(vat);
        s_par = Math.RAY;
    }

    ////////////////////////////////////////////
    //            External Functions          //
    ////////////////////////////////////////////
    function file(bytes32 ilk, bytes32 what, address pip) external auth isAlive {
        if (what == "pip") {
            s_ilks[ilk].pip = PipLike(pip);
        } else {
            revert Spotter__FileUnrecognizedParam();
        }
    }

    function file(bytes32 what, uint256 data) external auth isAlive {
        if (what == "par") {
            s_par = data;
        } else {
            revert Spotter__FileUnrecognizedParam();
        }
    }

    function file(bytes32 ilk, bytes32 what, uint256 data) external auth isAlive {
        if (what == "mat") {
            s_ilks[ilk].mat = data;
        } else {
            revert Spotter__FileUnrecognizedParam();
        }
    }

    // How much debt (DAI) does 1 unit of collateral (spot) support?
    // Reads a collateral's type oracle price, 
    // adjust it for the required collateralization ratio, 
    // and stores the result in Vat.
    // - ilk is the collateral type
    function poke(bytes32 ilk) external {
        // 1. Read the oracle
        // pip is the configured price feed. It returns:
        //  - val: the collateral price [wad]
        //  - has: whether the feed considers that price valid. 
        (bytes32 val, bool has) = s_ilks[ilk].pip.peek();

        // 2. Calculate the safety-adjusted price (spot)
        //  spot = oracle price / par / mat
        //  where:
        //  - s_par is the reference currency value of one Dai (1$)
        //  - mat is the required collateralization ratio
        uint256 ray = Math.toRay(uint256(val)); // converts the oracle’s 18-decimal wad into a 27-decimal ray.
        uint256 spot = has ? Math.toRay(uint256(val)).rdiv(s_par).rdiv(s_ilks[ilk].mat) : 0;

        // 3. Update Vat
        i_vat.file(ilk, "spot", spot);

        emit Poke(ilk, val, spot);
    }

    ////////////////////////////////////////////
    //            Internal Functions          //
    ////////////////////////////////////////////
    function _revertNotLive() internal pure override {
        revert Spotter__NotLive();
    }

    function _revertNotAuthorized() internal pure override {
        revert Spotter__NotAuthorized();
    }

    //////////////////////////////////////////////////////
    //      External & Public View & Pure Functions     //
    //////////////////////////////////////////////////////
    function ilks(bytes32 ilk) external view returns (Ilk memory) {
        return s_ilks[ilk];
    }
}
