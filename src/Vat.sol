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
import {Shutdown} from "./Shutdown.sol";

// It is the core accounting system and engine of the DSS protcol.
// It stores free collateral (gem), locked collateral (ink), normalized debt (art), debt (dai) and bad debt (sin).
contract Vat is Shutdown {
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
    error Vat__NotAllowed();
    error Vat__NotSafeSrc();
    error Vat__NotSafeDst();
    error Vat__DustSrc();
    error Vat__DustDst();

    ///////////////////////////////////
    //            Libraries          //
    ///////////////////////////////////
    using Math for uint256;

    ///////////////////////////////////////////
    //            Type Declarations          //
    ///////////////////////////////////////////

    // Data structure for a collateral type
    struct Ilk {
        uint256 Art; // Total Normalized Debt         [wad]
        uint256 rate; // Accumulated Debt Multiplier   [ray]     Actual vault debt = art × rate
        uint256 spot; // Price with Safety Margin      [ray]
        uint256 line; // Debt Ceiling                  [rad]
        uint256 dust; // Urn's Minimum Allowe Debt     [rad]
    }

    // Accounting record for one Vault. Each user has its own vault (urn) -> s_urns[ETH-A][user]
    struct Urn {
        uint256 ink; // [wad] User's locked Collateral
        uint256 art; // [wad] Normalized debt that the user owes. Actual amount owed is debt = urn.art × rate / RAY
    }

    /////////////////////////////////////////
    //            State Variables          //
    /////////////////////////////////////////
    // Records who has permission to act on whose behalf
    // can[owner][operator]
    // - 1: the owner has authorized the operator
    // - 0: the owner has not authorized the operator—the default.
    mapping(address owner => mapping(address operator => uint256 auth)) private s_can;

    // Stores Ilk data for each collateral type (ilk).
    // For example: "ETH-A" → Ilk { Art, rate, spot, line, dust }
    mapping(bytes32 ilk => Ilk data) private s_ilks;

    // Stores For each collateral type (ilk) and for each vault (urn) the vault's data (data)
    mapping(bytes32 ilk => mapping(address urn => Urn data)) private s_urns;

    // Stores free collateral: the collateral is already inside the system but is not locked in a vault.
    // s_gem[i][v] is address v’s free collateral balance for collateral type i.
    // Example: s_gem["ETH-A"][user]
    mapping(bytes32 ilk => mapping(address user => uint256 balance)) private s_gem; // [wad]

    // user’s internal Dai balance available to spend, not their debt..
    // You can use that balance to:
    //  - Repay vault debt through vat.frob.
    //  - Transfer internal Dai to another address through vat.move.
    //  - Convert it into wallet Dai through DaiJoin.exit.
    mapping(address account => uint256 balance) private s_dai; // [rad]

    // Stores unbacked debt assigned to a user. Total system debt assigned to the Vow
    mapping(address user => uint256 balance) private s_sin; // [rad]

    uint256 private s_debt; // Total Dai Issued    [rad]

    uint256 private s_vice; // Total Unbacked Dai  [rad]

    uint256 public s_Line; // Total Debt Ceiling   [rad]

    ///////////////////////////////////
    //            Modifiers          //
    ///////////////////////////////////
    // Check permission. The caller must be source or an address that source authorized through hope
    modifier isCallerAllowed(address source) {
        if (!_wish(source, msg.sender)) {
            revert Vat__NotAllowed();
        }
        _;
    }

    ////////////////////////////////////////////
    //            External Functions          //
    ////////////////////////////////////////////
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
    function file(bytes32 what, uint256 data) external auth isAlive {
        if (what == "Line") {
            s_Line = data;
        } else {
            revert Vat__FileUnrecognizedParam();
        }
    }

    // Sets the parameters spot, line and dust for the collateral type ilk
    function file(bytes32 ilk, bytes32 what, uint256 data) external auth isAlive {
        if (what == "spot") {
            // Price with safety margin
            s_ilks[ilk].spot = data;
        } else if (what == "line") {
            // Debt ceiling
            s_ilks[ilk].line = data;
        } else if (what == "dust") {
            // Debt floor
            s_ilks[ilk].dust = data;
        } else {
            revert Vat__FileUnrecognizedParam();
        }
    }

    // Adds wad to the free collateral balance of user for the ilk collateral type
    function slip(bytes32 ilk, address user, int256 wad) external auth {
        s_gem[ilk][user] = s_gem[ilk][user].add(wad);
    }

    // Subtracts wad amount of free collateral from source's balance
    // Adds wad amount of free collateral to destination's balance
    function flux(bytes32 ilk, address source, address destination, uint256 wad) external isCallerAllowed(source) {
        s_gem[ilk][source] -= wad;
        s_gem[ilk][destination] += wad;
    }

    /**
     * @dev Modifies a vault's locked collateral and debt.
     * @param i Collateral type
     * @param u Address of the vault being modified  -> updates s_urns[i][u]
     * @param v Address supplying or receiving free collateral  -> updates s_gem[i][v]
     * @param w Address receiving generated Dai or supplying Dai for repayment -> updates s_dai[w]
     * @param dink Change in locked collateral: positive locks, negative unlocks
     * @param dart Change in normalized debt: positive borrows, negative repays
     */
    function frob(bytes32 i, address u, address v, address w, int256 dink, int256 dart) external isAlive {
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
        ilk.Art = ilk.Art.add(dart);

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
        if (dart > 0 && (ilk.Art * ilk.rate > ilk.line || s_debt > s_Line)) {
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
        //  Now it applies the opposite change to the free collateral balance
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

    /**
     * @notice Transfers locked collateral and normalized debt between vaults of the same collateral type.
     * @dev Both owners must consent and both resulting vaults must be safe and non-dusty.
     *      Total debt, free collateral and internal Dai balances remain unchanged.
     *      Like the reference Vat, this operation remains available after shutdown.
     * @param ilk Collateral type
     * @param src Source vault address
     * @param dst Destination vault address
     * @param dink Collateral to move [wad]; negative values move from dst to src
     * @param dart Normalized debt to move [wad]; negative values move from dst to src
     */
    function fork(bytes32 ilk, address src, address dst, int256 dink, int256 dart) external {
        Urn storage u = s_urns[ilk][src];
        Urn storage v = s_urns[ilk][dst];
        Ilk storage i = s_ilks[ilk];

        u.ink = u.ink.sub(dink);
        u.art = u.art.sub(dart);
        v.ink = v.ink.add(dink);
        v.art = v.art.add(dart);

        uint256 utab = u.art * i.rate;
        uint256 vtab = v.art * i.rate;

        if (!_wish(src, msg.sender) || !_wish(dst, msg.sender)) {
            revert Vat__NotAllowed();
        }

        if (utab > u.ink * i.spot) {
            revert Vat__NotSafeSrc();
        }
        if (vtab > v.ink * i.spot) {
            revert Vat__NotSafeDst();
        }

        if (u.art != 0 && utab < i.dust) {
            revert Vat__DustSrc();
        }
        if (v.art != 0 && vtab < i.dust) {
            revert Vat__DustDst();
        }
    }

    // Changes the accumuated debt multiplier for a collateral type and
    // accounts for the resulting change in debt
    //
    // The central idea is that fold changes the shared multiplier without rewriting each vault.
    // The vault owes more, its collateral and normalized debt stay unchanged,
    // and the additional internal Dai goes to the recipient u
    //
    // - i: collateral type or ilk
    // - u: the address whose internal Dai balance receives the adjustment
    // - rate: a signed change to the accumulated multiplier, not its new value or an annual interest rate
    function fold(bytes32 i, address u, int256 rate) external auth isAlive {
        // Reading the collateral
        Ilk storage ilk = s_ilks[i];
        // Adds the signed increment to the stored multiplier
        // Changing the shared multiplier changes every vault's debt without
        // updating individual vaults.
        ilk.rate = ilk.rate.add(rate);

        // Update the vault's debt
        // ilk.Art is the total normalized debt for that collateral type
        // Vault's debt = urn.art * ilk.rate
        int256 rad = ilk.Art.mul(rate);

        // Apply the adjustment to u's internal Dai balance
        // - Positive rad: credits Dai to u
        // - Negative rad: removes Dai from u
        s_dai[u] = s_dai[u].add(rad);
        // Update the global total Dai issued by the same amount
        s_debt = s_debt.add(rad);
    }

    // Transfers internal Dai balance from one address to another within the Vat
    // Parameters:
    // - source: the address whose balance is debited
    // - destination: the address whose balance is credited
    // - rad: the amount, using 45 decimal places
    function move(address source, address destination, uint256 rad) external isCallerAllowed(source) {
        // Subtract from the source
        s_dai[source] -= rad;
        // Add to the destination
        s_dai[destination] += rad;
    }

    // This is a privileged confiscation function. In a typical liquidation,
    // it removes collateral and debt from a Vault, credits the collateral to an auction contract,
    // and records the removed debt as system bad debt.
    // Paramenters
    // - i: collateral type
    // - u: address identifying the Vault
    // - v: address whose free collateral balance changes
    // - w: address whose bad debt balance changes, typically the Vow
    // - dink: signed change in the Vault's collateral
    // - dart: signed change in the Vault's normalized debt
    // The key is that liquidation passes negative dink and dart
    function grab(bytes32 i, address u, address v, address w, int256 dink, int256 dart) external auth {
        Urn storage urn = s_urns[i][u];
        Ilk storage ilk = s_ilks[i];

        // Negative dink and dart decrease all 3
        urn.ink = urn.ink.add(dink); // Vault's locked collateral
        urn.art = urn.art.add(dart); // Vault's normalized debt
        ilk.Art = ilk.Art.add(dart); // Collateral's type normalzied debt

        // Dai (debt) = dart (normalzied debt) x rate (accumulated rate)
        int256 dtab = ilk.rate.mul(dart);

        // Subtracting negative values increases these balances
        s_gem[i][v] = s_gem[i][v].sub(dink); // the seized collateral becomes free collateral credited to v inside Vat.
        s_sin[w] = s_sin[w].sub(dtab); // the removed Vault debt becomes bad debt assigned to w
        s_vice = s_vice.sub(dtab); // total system bad debt increases by the same amount
    }

    // Cancels the caller’s unbacked debt using the caller’s internal Dai
    function heal(uint256 rad) external {
        s_sin[msg.sender] -= rad; // Cancel caller's unbacked debt
        s_dai[msg.sender] -= rad; // Consume caller's internal Dai
        s_vice -= rad; // Reduce total unbacked debt
        s_debt -= rad; // Reduce total Dai issued
    }

    // Creates internal Dai without collateral backing
    function suck(address u, address v, uint256 rad) external auth {
        s_sin[u] += rad; // Assign unbacked debt to u
        s_dai[v] += rad; // Give spendable internal Dai to v
        s_vice += rad; // Increase total unbacked debt
        s_debt += rad; // Increase total Dai issued
    }

    ////////////////////////////////////////////
    //            Internal Functions          //
    ////////////////////////////////////////////
    function _revertNotLive() internal pure override {
        revert Vat__NotLive();
    }

    // Check that Vat is not shutdown
    function _beforeRely() internal view override isAlive {}

    function _beforeDeny() internal view override isAlive {}

    function _revertNotAuthorized() internal pure override {
        revert Vat__NotAuthorized();
    }

    // Checks if the user address is authorized by bit.
    // Returns true when bit and user are the same address or
    // the bit address has authorized the user
    function _wish(address bit, address user) internal view returns (bool) {
        return bit == user || s_can[bit][user] == 1;
    }

    //////////////////////////////////////////////////////
    //      External & Public View & Pure Functions     //
    //////////////////////////////////////////////////////
    function gem(bytes32 ilk, address user) external view returns (uint256) {
        return s_gem[ilk][user];
    }

    function urns(bytes32 ilk, address user) external view returns (Urn memory) {
        return s_urns[ilk][user];
    }

    function ilks(bytes32 ilk) external view returns (Ilk memory) {
        return s_ilks[ilk];
    }

    function can(address owner, address operator) external view returns (uint256) {
        return s_can[owner][operator];
    }

    function dai(address account) external view returns (uint256) {
        return s_dai[account];
    }

    function sin(address user) external view returns (uint256) {
        return s_sin[user];
    }

    function debt() external view returns (uint256) {
        return s_debt;
    }

    function vice() external view returns (uint256) {
        return s_vice;
    }
}
