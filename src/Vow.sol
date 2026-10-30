// SPDX-License-Identifier: AGPL-3.0-or-later
// Derived from dss/src/vow.sol, Copyright (C) 2018 Rain <rainbreak@riseup.net>.
pragma solidity 0.8.35;

import {Shutdown} from "./Shutdown.sol";
import {Math} from "./libraries/Math.sol";

interface VatLike {
    function dai(address) external view returns (uint256);
    function sin(address) external view returns (uint256);
    function heal(uint256) external;
    function hope(address) external;
    function nope(address) external;
}

interface FlapLike {
    function kick(uint256 lot, uint256 bid) external returns (uint256);
    function cage(uint256 rad) external;
    function live() external view returns (uint256);
}

interface FlopLike {
    function kick(address gal, uint256 lot, uint256 bid) external returns (uint256);
    function cage() external;
    function live() external view returns (uint256);
}

// Manages the system’s surplus Dai and bad debt.
/// @notice Settles system debt with internal Dai and starts surplus or debt auctions.
/// @dev Reimplements dss/src/vow.sol. Amounts use rad (45 decimals), except dump (wad).
contract Vow is Shutdown {
    ////////////////////////////////
    //            Errors          //
    ////////////////////////////////
    error Vow__NotAuthorized();
    error Vow__NotLive();
    error Vow__FileUnrecognizedParam();
    error Vow__WaitNotFinished();
    error Vow__InsufficientSurplus();
    error Vow__InsufficientDebt();
    error Vow__NotEnoughAsh();
    error Vow__SurplusNotZero();
    error Vow__DebtNotZero();

    /////////////////////////////////////////
    //            State Variables          //
    /////////////////////////////////////////
    VatLike private immutable i_vat;
    FlapLike private s_flapper;
    FlopLike private s_flopper;

    mapping(uint256 era => uint256 debt) private s_sin; // Timestamped debt queue [rad]
    uint256 private s_Sin; // Total queued debt [rad]
    uint256 private s_Ash; // Debt assigned to debt auctions [rad]

    uint256 private s_wait; // Delay before queued debt can be released [seconds]
    uint256 private s_dump; // Initial governance-token lot for a debt auction [wad]
    uint256 private s_sump; // Fixed Dai bid for a debt auction [rad]
    uint256 private s_bump; // Fixed Dai lot for a surplus auction [rad]
    uint256 private s_hump; // Surplus buffer retained by the Vow [rad]

    event File(bytes32 indexed what, uint256 data);
    event File(bytes32 indexed what, address data);
    event Fess(uint256 indexed era, uint256 tab);
    event Flog(uint256 indexed era, uint256 tab);
    event Heal(uint256 rad);
    event Kiss(uint256 rad);
    event Flop(uint256 indexed id);
    event Flap(uint256 indexed id);

    ////////////////////////////////////////////
    //            Functions          //
    ////////////////////////////////////////////
    constructor(address vatAddress, address flapperAddress, address flopperAddress) {
        i_vat = VatLike(vatAddress);
        s_flapper = FlapLike(flapperAddress);
        s_flopper = FlopLike(flopperAddress);
        i_vat.hope(flapperAddress);
    }

    ////////////////////////////////////////////
    //            External Functions          //
    ////////////////////////////////////////////
    function file(bytes32 what, uint256 data) external auth {
        if (what == "wait") s_wait = data;
        else if (what == "bump") s_bump = data;
        else if (what == "sump") s_sump = data;
        else if (what == "dump") s_dump = data;
        else if (what == "hump") s_hump = data;
        else revert Vow__FileUnrecognizedParam();
        emit File(what, data);
    }

    function file(bytes32 what, address data) external auth {
        if (what == "flapper") {
            i_vat.nope(address(s_flapper));
            s_flapper = FlapLike(data);
            i_vat.hope(data);
        } else if (what == "flopper") {
            s_flopper = FlopLike(data);
        } else {
            revert Vow__FileUnrecognizedParam();
        }
        emit File(what, data);
    }

    /// @notice Queues debt already assigned to this Vow in Vat; does not create debt.
    function fess(uint256 tab) external auth {
        s_sin[block.timestamp] += tab;
        s_Sin += tab;
        emit Fess(block.timestamp, tab);
    }

    /// @notice Releases a timestamp's entire queue entry once the delay has elapsed.
    function flog(uint256 era) external {
        if (era + s_wait > block.timestamp) revert Vow__WaitNotFinished();
        uint256 tab = s_sin[era];
        s_Sin -= tab;
        s_sin[era] = 0;
        emit Flog(era, tab);
    }

    /// @notice Cancels debt that is neither queued nor assigned to a debt auction.
    function heal(uint256 rad) external {
        if (rad > i_vat.dai(address(this))) revert Vow__InsufficientSurplus();
        if (rad > _unqueuedDebt()) revert Vow__InsufficientDebt();
        i_vat.heal(rad);
        emit Heal(rad);
    }

    /// @notice Cancels debt assigned to auctions using Dai received by the Vow.
    function kiss(uint256 rad) external {
        if (rad > s_Ash) revert Vow__NotEnoughAsh();
        if (rad > i_vat.dai(address(this))) revert Vow__InsufficientSurplus();
        s_Ash -= rad;
        i_vat.heal(rad);
        emit Kiss(rad);
    }

    function flop() external returns (uint256 id) {
        if (s_sump > _unqueuedDebt()) revert Vow__InsufficientDebt();
        if (i_vat.dai(address(this)) != 0) revert Vow__SurplusNotZero();
        s_Ash += s_sump;
        id = s_flopper.kick(address(this), s_dump, s_sump);
        emit Flop(id);
    }

    function flap() external returns (uint256 id) {
        if (i_vat.dai(address(this)) < i_vat.sin(address(this)) + s_bump + s_hump) {
            revert Vow__InsufficientSurplus();
        }
        if (_unqueuedDebt() != 0) revert Vow__DebtNotZero();
        id = s_flapper.kick(s_bump, 0);
        emit Flap(id);
    }

    ////////////////////////////////////////////
    //            Internal Functions          //
    ////////////////////////////////////////////

    /// @notice Shuts down both auction houses and settles as much debt as possible.
    /// @dev Queue entries remain in storage, as in the reference; Sin and Ash are reset.
    function _cage() internal override isAlive {
        super._cage();
        s_Sin = 0;
        s_Ash = 0;
        s_flapper.cage(i_vat.dai(address(s_flapper)));
        s_flopper.cage();
        i_vat.heal(Math.min(i_vat.dai(address(this)), i_vat.sin(address(this))));
    }

    //////////////////////////////////////////////////////////////////
    //            Internal & Private View & Pure Functions          //
    //////////////////////////////////////////////////////////////////

    function _revertNotAuthorized() internal pure override {
        revert Vow__NotAuthorized();
    }

    // The reference blocks rely after shutdown while leaving deny available.
    function _beforeRely() internal view override isAlive {}

    function _revertNotLive() internal pure override {
        revert Vow__NotLive();
    }

    function _unqueuedDebt() internal view returns (uint256) {
        return i_vat.sin(address(this)) - s_Sin - s_Ash;
    }

    //////////////////////////////////////////////////////////////////
    //            External & Public View & Pure Functions          //
    //////////////////////////////////////////////////////////////////
    function vat() external view returns (VatLike) {
        return i_vat;
    }

    function flapper() external view returns (FlapLike) {
        return s_flapper;
    }

    function flopper() external view returns (FlopLike) {
        return s_flopper;
    }

    function sin(uint256 era) external view returns (uint256) {
        return s_sin[era];
    }

    function Sin() external view returns (uint256) {
        return s_Sin;
    }

    function Ash() external view returns (uint256) {
        return s_Ash;
    }

    function wait() external view returns (uint256) {
        return s_wait;
    }

    function dump() external view returns (uint256) {
        return s_dump;
    }

    function sump() external view returns (uint256) {
        return s_sump;
    }

    function bump() external view returns (uint256) {
        return s_bump;
    }

    function hump() external view returns (uint256) {
        return s_hump;
    }
}
