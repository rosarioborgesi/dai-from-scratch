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

import {Math} from "./libraries/Math.sol";

// It is the core Vault engine of dss.
// It stores and tracks all the associated Dai and collateral balances.
contract Vat {
    ////////////////////////////////
    //            Errors          //
    ////////////////////////////////
    error Vat__NotAuthorized();
    error Vat__IlkAlreadyInitialized();
    error Vat__NotLive();
    error Vat__IlkNotInit();
    error Vat__CeilingExceeded();
    error Vat__NotSafe();
    error Vat__NotAllowedU();
    error Vat__NotAllowedV();
    error Vat__NotAllowedW();
    error Vat__Dust();
    error Vat__FileUnrecognizedParam();

    ///////////////////////////////////
    //            Libraries          //
    ///////////////////////////////////
    using Math for uint256;

    ///////////////////////////////////////////
    //            Type Declarations          //
    ///////////////////////////////////////////

    // Data structure for a collateral type
    struct Ilk {
        uint256 art; // Total Normalised Debt        [wad]
        uint256 rate; // Accumulated Debt Multiplier [ray] Actual vault debt = art × rate
        uint256 spot; // Price with Safety Margin    [ray]
        uint256 line; // Debt Ceiling                [rad]
        uint256 dust; // Urn Debt Floor              [rad]
    }

    // Accounting record for one Vault
    struct Urn {
        uint256 ink; // Locked Collateral  [wad]
        uint256 art; // Normalized Debt    [wad]
    }

    /////////////////////////////////////////
    //            State Variables          //
    /////////////////////////////////////////
    // Stores the addresses that have administrative permission in the contract. (0 not authorized, 1 authorized)
    mapping(address => uint256) private s_wards;

    // Records who has permission to act on whose behalf
    // can[owner][operator]
    // - 1: the owner has authorized the operator
    // - 0: the owner has not authorized the operator—the default.
    mapping(address owner => mapping(address operator => uint256 auth)) private s_can;

    // Stores Ilk data for each collateral type (ilkType).
    // For example: "ETH-A" → Ilk { Art, rate, spot, line, dust }
    mapping(bytes32 ilkType => Ilk data) private s_ilks;

    // Stores For each collateral type (ilkType) and for each vault (urn) the vault's data (data)
    mapping(bytes32 ilkType => mapping(address urn => Urn data)) private s_urns;

    // s_gem[i][v] is address v’s free collateral balance for collateral type i.
    // This collateral is already inside the system but is not locked in a vault.
    // Example: s_gem["ETH-A"][user]
    mapping(bytes32 ilkType => mapping(address user => uint256 balance)) private s_gem; // [wad]

    // Stores user’s internal Dai balance
    mapping(address user => uint256 balance) private s_dai; // [wad]

    // Stores unbacked debt assigned to a user
    mapping(address user => uint256 balance) private s_sin; // [rad]

    uint256 private s_debt; // Total Dai Issued    [rad]

    uint256 private s_vice; // Total Unbacked Dai  [rad]

    uint256 public s_line; // Total Debt Ceiling   [rad]

    // Indicates whether the contract is active (1) or shut down (0)
    uint256 private s_live; // Active Flag
    ////////////////////////////////
    //            Events          //
    ////////////////////////////////

    ///////////////////////////////////
    //            Modifiers          //
    ///////////////////////////////////
    // Only authorized addresses (1) can execute this function
    modifier auth() {
        if (s_wards[msg.sender] != 1) {
            revert Vat__NotAuthorized();
        }
        _;
    }

    modifier vatIsAlive() {
        if (s_live != 1) {
            revert Vat__NotLive();
        }
        _;
    }

    ///////////////////////////////////
    //            Functions          //
    ///////////////////////////////////
    constructor() {
        // Grants administrative permissions to msg.sender
        s_wards[msg.sender] = 1;
        // Sets the contract as active.
        s_live = 1;
    }

    ////////////////////////////////////////////
    //            External Functions          //
    ////////////////////////////////////////////
    // Grants administrative permissions the user
    function rely(address user) external auth vatIsAlive {
        s_wards[user] = 1;
    }

    // Revokes administrative permissions to the user
    function deny(address user) external auth {
        if (s_live != 1) {
            revert Vat__NotLive();
        }
        s_wards[user] = 0;
    }

    // msg.sender grats authorization to user
    function hope(address user) external {
        s_can[msg.sender][user] = 1;
    }

    // msg.sender revokes authorization to user
    function nope(address user) external {
        s_can[msg.sender][user] = 0;
    }

    // Initializes the ilk.
    // Ilks not initilized have rate 0.
    // Ilks are initialized to 1e27 (which is 1)
    function init(bytes32 ilk) external auth {
        if (s_ilks[ilk].rate != 0) {
            revert Vat__IlkAlreadyInitialized();
        }
        s_ilks[ilk].rate = 1e27;
    }

    // Sets the total debt ceiling (s_line)
    function file(bytes32 what, uint256 data) external auth vatIsAlive {
        if (what == "Line") {
            s_line = data;
        } else {
            revert Vat__FileUnrecognizedParam();
        }
    }

    // Sets the parameters spot, line and dust for the collateral type ilk
    function file(bytes32 ilk, bytes32 what, uint256 data) external auth vatIsAlive {
        if (what == "spot") {
            s_ilks[ilk].spot = data;
        } else if (what == "line") {
            s_ilks[ilk].line = data;
        } else if (what == "dust") {
            s_ilks[ilk].dust = data;
        } else {
            revert Vat__FileUnrecognizedParam();
        }
    }

    // Shut down the vat
    function cage() external auth {
        s_live = 0;
    }

    // Modify a user's collateral balance.
    function slip(bytes32 ilk, address user, int256 amount) external auth {
        s_gem[ilk][user] = s_gem[ilk][user].add(amount);
    }

    /**
     * @dev Modifies a vault's locked collateral and debt.
     * @param i Collateral type
     * @param u Address of the vault being modified
     * @param v Address supplying or receiving free collateral
     * @param w Address receiving generated Dai or supplying Dai for repayment
     * @param dink Change in locked collateral: positive locks, negative unlocks
     * @param dart Change in normalized debt: positive borrows, negative repays
     */
    function frob(bytes32 i, address u, address v, address w, int256 dink, int256 dart) external vatIsAlive {
        Urn memory urn = s_urns[i][u];
        Ilk memory ilk = s_ilks[i];

        // Require that ilk has been initialized
        if (ilk.rate == 0) {
            revert Vat__IlkNotInit();
        }

        // Update the collateral locked in this vault
        urn.ink = urn.ink.add(dink);
        // Updated the vault’s normalized debt
        urn.art = urn.art.add(dart);
        // Update the total normalized debt across all vaults of this collateral type.
        ilk.art = ilk.art.add(dart);

        // Calculate the change in the Dai debt
        // - dart is the requested change in normalized debt.
        // - ilk.rate is the accumulated debt multiplyier for this collateral type
        int256 dtab = ilk.rate.mul(dart);

        // Calculate the vault's total debt
        // - urn.art: this vault’s normalized debt
        // - ilk.rate is the accumulated debt multiplyier for this collateral type
        uint256 tab = ilk.rate * urn.art;

        // Apply the debt change to the system total
        s_debt = s_debt.add(dtab);

        // When borrowing (dart > 0), rejects debt exceeding either the collateral type’s ceiling (ilk.line)
        // or the global ceiling (s_line).
        if (dart > 0 && (ilk.art * ilk.rate > ilk.line || s_debt > s_line)) {
            revert Vat__CeilingExceeded();
        }

        // When borrowing or unlocking collateral, rejects a vault whose debt (tab) exceeds its collateral’s safety-adjusted value urn.ink * ilk.spot.
        // Adding collateral and/or repaying debt can proceed even if the vault remains unsafe.

        //  - urn.ink: the amount of collateral locked in the vault.
        //  - ilk.spot: the collateral’s price after applying the protocol’s safety margin.
        //  - urn.ink x ilk.spot: gives the safety-adjusted value of the vault’s locked collateral
        if ((dart > 0 || dink < 0) && tab > urn.ink * ilk.spot) {
            revert Vat__NotSafe();
        }

        // Increasing debt or removing collateral requires vault permission.
        if ((dart > 0 || dink < 0) && !_wish(u, msg.sender)) {
            revert Vat__NotAllowedU();
        }

        // Locking collateral requires permission from its source.
        if (dink > 0 && !_wish(v, msg.sender)) {
            revert Vat__NotAllowedV();
        }

        // Repaying debt requires permission from the Dai source.
        if (dart < 0 && !_wish(w, msg.sender)) {
            revert Vat__NotAllowedW();
        }

        // Rejects a nonzero remaining debt below ilk.dust. Fully repaying the debt is allowed.
        if (urn.art != 0 && tab < ilk.dust) {
            revert Vat__Dust();
        }

        // Update the collateral free balance
        // gem[i][v] is address v’s free collateral balance for collateral type i.
        // This collateral is already inside the system but is not locked in a vault.
        // dink is the change in the locked collateral

        // NOTE: Earlier we changed the vault's locked collateral: urn.ink = urn.ink.add(dink);
        //  Now it applies the opposite change to the free balance
        s_gem[i][v] = s_gem[i][v].sub(dink);

        // Credit generated Dai or consume Dai for repayment
        // dai[w] is address w’s internal Dai balance
        // - Borrowing: dtab > 0, so w receives interanl Dai
        // - Repaying: dtab < 0, so interanl Dai is deducted from w
        s_dai[w] = s_dai[w].add(dtab);

        // Save the modified vault (i is the collateral type, u is the vault's address)
        s_urns[i][u] = urn;

        // Save the collateral type's updated total debt
        s_ilks[i] = ilk;
    } 
    
    ////////////////////////////////////////////
    //            Internal Functions          //
    ////////////////////////////////////////////

    // Checks if the user address is authorized by bit.
    // Returns true when bit and user are the same address or
    // the bit address has authorized the user
    function _wish(address bit, address user) internal view returns (bool) {
        return bit == user || s_can[bit][user] == 1;
    }

    //TODO
    //fold


    //////////////////////////////////////////////////////
    //      External & Public View & Pure Functions     //
    //////////////////////////////////////////////////////
    function gem(bytes32 ilk, address user) external view returns (uint256) {
        return s_gem[ilk][user];
    }

    function urns(bytes32 ilk, address user) external view returns (Urn memory) {
        return s_urns[ilk][user];        
    }
}
