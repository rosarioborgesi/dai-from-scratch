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

interface ClipperLike {
    function ilk() external view returns (bytes32);
    function kick(uint256 tab, uint256 lot, address usr, address kpr) external returns (uint256);
}

interface VatLike {
    function ilks(bytes32)
        external
        view
        returns (
            uint256 Art, // [wad]
            uint256 rate, // [ray]
            uint256 spot, // [ray]
            uint256 line, // [rad]
            uint256 dust // [rad]
        );
    function urns(bytes32, address)
        external
        view
        returns (
            uint256 ink, // [wad]
            uint256 art // [wad]
        );
    function grab(bytes32, address, address, address, int256, int256) external;
    function hope(address) external;
    function nope(address) external;
}

interface VowLike {
    function fess(uint256) external;
}

// The Dog contract coordinates Vault liquidations.
contract Dog is Shutdown {
    ////////////////////////////////
    //            Errors          //
    ////////////////////////////////
    error Dog__NotAuthorized();
    error Dog__NotLive();
    error Dog__FileUnrecognizedParam();
    error Dog__FileChopLtWAD();
    error Dog__FileIlkNeqClipIlk();
    error Dog__NotUnsafe();
    error Dog__NullAuction();
    error Dog__DustyActionFromPartialLiquidation();
    error Dog__LiquidationLimitHit();
    error Dog__Overflow();

    ///////////////////////////////////
    //            Libraries          //
    ///////////////////////////////////
    ///////////////////////////////////////////
    //            Type Declarations          //
    ///////////////////////////////////////////
    struct Ilk {
        address clip; // Auction contract that will sell the collateral.
        uint256 chop; // Liquidation penalty multiplier; for example, 1.13 means a 13% penalty.         [wad]
        uint256 hole; // Max DAI needed to cover debt+fees of active auctions for this collateral type. [rad]
        uint256 dirt; // Amount of that limit (hole) currently occupied for this collateral type.                                [rad]
    }

    /////////////////////////////////////////
    //            State Variables          //
    /////////////////////////////////////////
    VatLike private immutable i_vat;

    mapping(bytes32 ilk => Ilk data) private s_ilks;

    VowLike private s_vow; // Debt Engine
    uint256 public s_Hole; // Max DAI needed to cover debt+fees of active auctions [rad]
    uint256 private s_Dirt; // Amount of that limit (Hole) currently occupied foractive auctions. [rad]
    ////////////////////////////////
    //            Events          //
    ////////////////////////////////
    event File(bytes32 indexed what, uint256 data);
    event File(bytes32 indexed what, address data);
    event File(bytes32 indexed ilk, bytes32 indexed what, uint256 data);
    event File(bytes32 indexed ilk, bytes32 indexed what, address clip);

    event Bark(
        bytes32 indexed ilk,
        address indexed urn,
        uint256 ink,
        uint256 art,
        uint256 due,
        address clip,
        uint256 indexed id
    );
    event Digs(bytes32 indexed ilk, uint256 rad);

    ///////////////////////////////////
    //            Modifiers          //
    ///////////////////////////////////
    ///////////////////////////////////
    //            Functions          //
    ///////////////////////////////////
    constructor(address vat) {
        i_vat = VatLike(vat);
    }

    ////////////////////////////////////////////
    //            External Functions          //
    ////////////////////////////////////////////
    function file(bytes32 what, address data) external auth {
        if (what == "vow") {
            s_vow = VowLike(data);
        } else {
            revert Dog__FileUnrecognizedParam();
        }
        emit File(what, data);
    }

    function file(bytes32 what, uint256 data) external auth {
        if (what == "Hole") {
            s_Hole = data;
        } else {
            revert Dog__FileUnrecognizedParam();
        }
        emit File(what, data);
    }

    function file(bytes32 ilk, bytes32 what, uint256 data) external auth {
        if (what == "chop") {
            if (data < Math.WAD) {
                revert Dog__FileChopLtWAD();
            }
            s_ilks[ilk].chop = data;
        } else if (what == "hole") {
            s_ilks[ilk].hole = data;
        } else {
            revert Dog__FileUnrecognizedParam();
        }
        emit File(ilk, what, data);
    }

    function file(bytes32 ilk, bytes32 what, address clip) external auth {
        if (what == "clip") {
            if (ilk != ClipperLike(clip).ilk()) {
                revert Dog__FileIlkNeqClipIlk();
            }
            s_ilks[ilk].clip = clip;
        } else {
            revert Dog__FileUnrecognizedParam();
        }
        emit File(ilk, what, clip);
    }

    // Liquidates an unsafe Vault and starts a Dutch auction to sell its collateral for DAI.
    // Starts the liquidation of an unsafe Vault. It determines how much debt can be liquidated,
    // removes a proportional amount of collateral, transfers the debt into the protocol's liquidation accounting,
    // and starts an auction.
    // It starts the sale; buyers purchase collateral later through Clipper.
    // Parameters:
    // - ilk: collateral type, such as ETH-A.
    // - urn: address identifying the Vault in the Vat.
    // - kpr: address that receives the liquidation reward, if configured. It can differ from the caller.
    // Returns:
    // id: ID of the newly created auction.
    function bark(bytes32 ilk, address urn, address kpr) external isAlive returns (uint256 id) {
        // 1. Read the Vault and its liquidation configuration

        // reads the vaults collateral (ink) and normalized debt (art)
        (uint256 ink, uint256 art) = i_vat.urns(ilk, urn);

        Ilk memory milk = s_ilks[ilk];
        uint256 dart;
        uint256 rate;
        uint256 dust;
        {
            // 2. Check that the Vault is unsafe
            uint256 spot;
            (, rate, spot,, dust) = i_vat.ilks(ilk);
            // ink * spot is the collateral's value adjusted for the required collateralization
            // art * rate is the actual debt because debt = normalized debt (art) * accumulated stability fees (rate)
            // The vault is unsafe when its adjusted collateral value is strictly below its debt
            // A zero spot blocks liquidation
            if (spot == 0 || ink * spot >= art * rate) {
                revert Dog__NotUnsafe();
            }

            // 2. Determine the available liquidation capacity (room)

            // There are two limits on outstanding auction targets:
            // - Global budget (Hole): all active auctions together can target up to this amount of DAI.
            // - Collateral-specific budget (milk.hole): active auctions for this particular collateral type, such as ETH-A, can target up to this amount.

            // Dirt and milk.dirt track how much of those budgets is already being used. The amounts include liquidation penalties.

            // Scope	                Limit	    Currently outstanding
            // All collateral types	    Hole	    Dirt
            // This collateral type	    milk.hole	milk.dirt

            // room is the minimum value between:
            // 1) Global remaining capacity = s_Hole − s_Dirt
            // 2) Ilk remaining capacity = milk.hole − milk.dirt
            // The following check is to  avoid subtraction underflow
            if (s_Hole <= s_Dirt || milk.hole <= milk.dirt) {
                revert Dog__LiquidationLimitHit();
            }

            uint256 room = Math.min(s_Hole - s_Dirt, milk.hole - milk.dirt);

            // 4. Convert capacity into normalized debt

            // Calculate how much of the Vault's normalized debt to liquidate
            // In other words: dart is the normalized debt to remove from the Vault

            // It takes the smaller of:
            // - art: all the Vault's normalized debt.
            // - room * WAD / rate / milk.chop: the normalized debt that fits within the available auction capacity.
            //     Explanation:
            //       - actual debt = normalized debt × rate
            //       - auction target = actual debt × penalty multiplier
            //       Working backwards:
            //       - normalized debt that fits = room ÷ penalty multiplier ÷ rate
            dart = Math.min(art, room * Math.WAD / rate / milk.chop);

            // 5. Apply the minimum-debt rules
            // Partial liquidation edge case logic
            if (art > dart) {
                // dust is the minimum debt amount
                if ((art - dart) * rate < dust) {
                    // If the remaining Vault debt would fall below dust, it liquidates the entire Vault.
                    dart = art;
                } else {
                    // the debt being liquidated must itself be at least dust;
                    if ((dart * rate) < dust) {
                        revert Dog__DustyActionFromPartialLiquidation();
                    }
                }
            }
        }

        // 6. Calculate the collateral to seize

        // The collateral removed (dink) is proportional to the debt removed (dart)
        // collateral removed / total collateral ≈ debt removed / total debt
        // For example, removing half the debt removes half the collateral. A full liquidation removes all of it.
        uint256 dink = ink * dart / art;

        // Reject a zero-collateral auction
        if (dink == 0) {
            revert Dog__NullAuction();
        }
        // Ensures that both amounts can safely become signed negative values
        if (dart > uint256(type(int256).max) || dink > uint256(type(int256).max)) {
            revert Dog__Overflow();
        }

        // 7. Move the collateral and debt in Vat
        // var.grab:
        // - Removes dink collateral and dart normalized debt from the Vault
        // - Credits the seized collateral to the Clipper's internal Vat balance
        // - Records the corresponding unbacked debt against Vow
        i_vat.grab(ilk, urn, milk.clip, address(s_vow), -int256(dink), -int256(dart));

        // 8. Queue the debt and calculate the auction target
        // due is the debt removed, including accrued fees.
        uint256 due = dart * rate;
        // The fess call queues due in the Vow.
        s_vow.fess(due);

        {
            // Avoid stack too deep
            // This calcuation will overflow if dart*rate exceeds ~10^14

            // 9. Reserve capacity and start the auction

            // tab is the auction's DAI target, including the liquidation penalty
            uint256 tab = due * milk.chop / Math.WAD;

            // Increase both outstanding-auction counters by tab
            s_Dirt += tab;
            s_ilks[ilk].dirt = milk.dirt + tab;

            // tab: tab -> DAI the auction aims to raise.
            // lot: dink -> collateral for sale
            // usr: urn -> recipient of leftover collateral
            // kpr: kpr -> recipient of any starting incentive
            id = ClipperLike(milk.clip).kick({tab: tab, lot: dink, usr: urn, kpr: kpr});
        }

        emit Bark(ilk, urn, dink, dart, due, milk.clip, id);
    }

    function digs(bytes32 ilk, uint256 rad) external auth {
        s_Dirt -= rad;
        s_ilks[ilk].dirt -= rad;
        emit Digs(ilk, rad);
    }

    ////////////////////////////////////////////
    //            Internal Functions          //
    ////////////////////////////////////////////
    function _revertNotLive() internal pure override {
        revert Dog__NotLive();
    }

    function _revertNotAuthorized() internal pure override {
        revert Dog__NotAuthorized();
    }

    //////////////////////////////////////////////////////
    //      External & Public View & Pure Functions     //
    //////////////////////////////////////////////////////
    function vat() external returns (VatLike) {
        return i_vat;
    }

    function ilks(bytes32 ilk) external returns (Ilk memory) {
        return s_ilks[ilk];
    }

    function chop(bytes32 ilk) external view returns (uint256) {
        return s_ilks[ilk].chop;
    }
}
