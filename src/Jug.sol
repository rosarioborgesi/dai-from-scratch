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

import {JugMath} from "src/libraries/JugMath.sol";
import {Auth} from "./Auth.sol";

interface VatLike {
    function ilks(bytes32)
        external
        returns (
            uint256 art, // [wad]
            uint256 rate // [ray]
        );
    function fold(bytes32, address, int256) external;
}

// Manages the accumulation of stability fees—the interest charged on vault debt
contract Jug is Auth {
    ////////////////////////////////
    //            Errors          //
    ////////////////////////////////
    error Jug__NotAuthorized();
    error Jug__IlkAlreadyInit();
    error Jug__RhoNotUpdated();
    error Jug__FileUnrecognizedParam();
    error Jug__InvalidTimestamp();

    ///////////////////////////////////
    //            Libraries          //
    ///////////////////////////////////
    using JugMath for uint256;

    ///////////////////////////////////////////
    //            Type Declarations          //
    ///////////////////////////////////////////
    struct Ilk {
        uint256 duty; // Collateral-specific, per-second stability fee contribution [ray]
        uint256 rho; // Time of last drip [unix epoch time]
    }

    /////////////////////////////////////////
    //            State Variables          //
    /////////////////////////////////////////
    // Stores an Ilk struct for each collateral type
    mapping(bytes32 ilk => Ilk data) private s_ilks;

    VatLike private immutable i_vat; // CDP Engine (System’s Vat contract)

    address private s_vow; // Debt Engine

    uint256 private s_base; // Global, per-second stability fee contribution [ray]

    uint256 constant ONE = 1e27;

    ///////////////////////////////////
    //            Functions          //
    ///////////////////////////////////
    constructor(address vatAddress) {
        i_vat = VatLike(vatAddress);
    }

    ////////////////////////////////////////////
    //            External Functions          //
    ////////////////////////////////////////////

    // Initializes the collateral data (ilk)
    function init(bytes32 ilk) external auth {
        Ilk storage i = s_ilks[ilk];
        if (i.duty != 0) {
            revert Jug__IlkAlreadyInit();
        }
        i.duty = ONE;
        i.rho = block.timestamp;
    }

    // Sets duty, the collateral-specific, per-second stability fee contribution
    function file(bytes32 ilk, bytes32 what, uint256 data) external auth {
        if (block.timestamp != s_ilks[ilk].rho) {
            revert Jug__RhoNotUpdated();
        }
        if (what == "duty") {
            s_ilks[ilk].duty = data;
        } else {
            revert Jug__FileUnrecognizedParam();
        }
    }

    // Sets s_base, the global, per-second stability fee contribution
    function file(bytes32 what, uint256 data) external auth {
        if (what == "base") {
            s_base = data;
        } else {
            revert Jug__FileUnrecognizedParam();
        }
    }

    // Sets s_vow the debt engine address
    function file(bytes32 what, address data) external auth {
        if (what == "vow") {
            s_vow = data;
        } else {
            revert Jug__FileUnrecognizedParam();
        }
    }

    // Accrues stability fees for a collateral type (ilk) from its last
    // update until the current block timestamp.
    // It updates the debt multiplier in Vat and credits the accrued fees to vow.

    // the new rate returned by this method is a debt multipler used to calculate the actual debt
    // actual debt = normalized debt x rate
    function drip(bytes32 ilk) external returns (uint256 rate) {
        // Check that block.timestamp is greater or equal than
        // rho, the timestamp of the last accrual.
        if (block.timestamp < s_ilks[ilk].rho) {
            revert Jug__InvalidTimestamp();
        }
        // Read the previous debt multiplier (prev)
        (, uint256 prev) = i_vat.ilks(ilk);

        // Compound the fees for the elapsed seconds
        // newRate = previousRate × ((base + duty) / 10²⁷)^elapsedSeconds
        // - base: global per-second contribution
        // - duty: collateral-specific per-second contribution
        rate = JugMath.rpow(s_base + s_ilks[ilk].duty, block.timestamp - s_ilks[ilk].rho, ONE).rmul(prev);

        // Apply the change to the accounting
        i_vat.fold(ilk, s_vow, rate.diff(prev));

        // Record the update time
        s_ilks[ilk].rho = block.timestamp;

        // The next call accrues only the time since this call.
    }

    /////////////////////////////////
    //      Internal Functions     //
    /////////////////////////////////
    function _revertNotAuthorized() internal pure override {
        revert Jug__NotAuthorized();
    }

    //////////////////////////////////////////////////////
    //      External & Public View & Pure Functions     //
    //////////////////////////////////////////////////////
    function ilks(bytes32 ilk) external view returns (Ilk memory) {
        return s_ilks[ilk];
    }

    function vat() external view returns (VatLike) {
        return i_vat;
    }

    function vow() external view returns (address) {
        return s_vow;
    }

    function base() external view returns (uint256) {
        return s_base;
    }
}
