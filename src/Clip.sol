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
import {Math} from "./libraries/Math.sol";

interface VatLike {
    function move(address, address, uint256) external;
    function flux(bytes32, address, address, uint256) external;
    function ilks(bytes32) external view returns (uint256, uint256, uint256, uint256, uint256);
    function suck(address, address, uint256) external;
}

interface PipLike {
    function peek() external returns (bytes32, bool);
}

interface SpotterLike {
    function par() external view returns (uint256);
    function ilks(bytes32) external view returns (PipLike, uint256);
}

interface DogLike {
    function chop(bytes32) external view returns (uint256);
    function digs(bytes32, uint256) external;
}

interface ClipperCallee {
    function clipperCall(address, uint256, uint256, bytes calldata) external;
}

interface AbacusLike {
    function price(uint256, uint256) external view returns (uint256);
}

/**
 * @title Collateral Dutch auction house
 * @notice Sells liquidated collateral for internal Dai at a price that decreases over time.
 * @dev Each auction tracks a collateral lot and a Dai target that normally includes the liquidation penalty.
 * Amounts use wad (1e18) for collateral and incentive fractions, ray (1e27) for prices and price ratios,
 * and rad (1e45) for internal Dai. Authorized addresses configure parameters, start auctions, and cancel them;
 * anyone can buy collateral, reset eligible auctions, or refresh the minimum remaining Dai target.
 */
contract Clipper is Auth {
    ////////////////////////////////
    //            Errors          //
    ////////////////////////////////
    error Clipper__NotAuthorized();
    error Clipper__SystemLocked();
    error Clipper__StoppedIncorrect();
    error Clipper__FileUnrecognizedParam();
    error Clipper__InvalidPrice();
    error Clipper__ZeroTab();
    error Clipper__ZeroLot();
    error Clipper__ZeroUsr();
    error Clipper__ZeroTopPrice();
    error Clipper__NotRunningAuction();
    error Clipper__CannotReset();
    error Clipper__NeedsReset();
    error Clipper__TooExpensive();
    error Clipper__NoPartialPurchase();

    //////////////////////////////////////////
    //           Type declarations          //
    //////////////////////////////////////////
    struct Sale {
        uint256 pos; // Index in active array
        uint256 tab; // Dai to raise       [rad]
        uint256 lot; // collateral to sell [wad]
        address usr; // Liquidated CDP
        uint96 tic; // Auction start time
        uint256 top; // Starting price     [ray]
    }

    ////////////////////////////////////////
    //           State variables          //
    ////////////////////////////////////////
    bytes32 private immutable i_ilk; // Collateral type of this Clipper
    VatLike private immutable i_vat; // Core CDP Engine

    DogLike private s_dog; // Liquidation module
    address private s_vow; // Recipient of dai raised in auctions
    SpotterLike private s_spotter; // Collateral price module
    AbacusLike private s_calc; // Current price calculator

    uint256 private s_buf; // Multiplicative factor to increase starting price                  [ray]
    uint256 private s_tail; // Time elapsed before auction reset                                 [seconds]
    uint256 private s_cusp; // Percentage drop before auction reset                              [ray]
    uint64 private s_chip; // Percentage of tab to suck from vow to incentivize keepers         [wad]
    uint192 private s_tip; // Flat fee to suck from vow to incentivize keepers                  [rad]
    uint256 private s_chost; // Cache the ilk dust times the ilk chop to prevent excessive SLOADs [rad]

    uint256 private s_kicks; // Total auctions
    uint256[] private s_active; // Array of active auction ids

    mapping(uint256 => Sale) private s_sales;

    uint256 private s_locked;

    // Levels for circuit breaker
    // 0: no breaker
    // 1: no new kick()
    // 2: no new kick() or redo()
    // 3: no new kick(), redo(), or take()
    uint256 private s_stopped = 0;

    ///////////////////////////////
    //           Events          //
    ///////////////////////////////
    event File(bytes32 indexed what, uint256 data);
    event File(bytes32 indexed what, address data);

    event Kick(
        uint256 indexed id,
        uint256 top,
        uint256 tab,
        uint256 lot,
        address indexed usr,
        address indexed kpr,
        uint256 coin
    );
    event Take(
        uint256 indexed id, uint256 max, uint256 price, uint256 owe, uint256 tab, uint256 lot, address indexed usr
    );
    event Redo(
        uint256 indexed id,
        uint256 top,
        uint256 tab,
        uint256 lot,
        address indexed usr,
        address indexed kpr,
        uint256 coin
    );

    event Yank(uint256 id);

    //////////////////////////////////
    //           Modifiers          //
    //////////////////////////////////
    /**
     * @dev Prevents reentrant calls to functions using this modifier.
     */
    modifier lock() {
        if (s_locked != 0) {
            revert Clipper__SystemLocked();
        }
        s_locked = 1;
        _;
        s_locked = 0;
    }

    /**
     * @dev Reverts when the circuit breaker reaches or exceeds the operation's stop level.
     * @param level Stop threshold: 1 for kick, 2 for redo, and 3 for take.
     */
    modifier isStopped(uint256 level) {
        if (s_stopped >= level) {
            revert Clipper__StoppedIncorrect();
        }
        _;
    }

    //////////////////////////////////
    //           Functions          //
    //////////////////////////////////
    /**
     * @notice Deploys an auction house for one collateral type with an initial starting-price multiplier of 1 ray.
     * @param vat_ Core ledger holding collateral balances, internal Dai, and system debt.
     * @param spotter_ Module providing the collateral oracle and Dai reference price.
     * @param dog_ Liquidation module tracking debt currently assigned to auctions.
     * @param ilk_ Collateral type handled by this auction house.
     */
    constructor(address vat_, address spotter_, address dog_, bytes32 ilk_) {
        i_vat = VatLike(vat_);
        s_spotter = SpotterLike(spotter_);
        s_dog = DogLike(dog_);
        i_ilk = ilk_;
        s_buf = Math.RAY;
        emit Rely(msg.sender);
    }

    ////////////////////////////////////////////
    //            External Functions          //
    ////////////////////////////////////////////
    /**
     * @notice Updates a numeric auction parameter; callable only by an authorized address.
     * @param what Parameter name: "buf" (ray), "tail" (seconds), "cusp" (ray), "chip" (wad),
     * "tip" (rad), or "stopped" (circuit-breaker level).
     * @param data New value. Levels 0, 1, 2, and 3 enable all operations, disable kick, additionally disable redo,
     * and additionally disable take, respectively. Values for chip and tip are truncated to uint64 and uint192.
     */
    function file(bytes32 what, uint256 data) external auth lock {
        if (what == "buf") {
            s_buf = data;
        } else if (what == "tail") {
            s_tail = data; // Time elapsed before auction reset
        } else if (what == "cusp") {
            s_cusp = data; // Percentage drop before auction reset
        } else if (what == "chip") {
            s_chip = uint64(data); // Percentage of tab to incentivize (max: 2^64 - 1 => 18.xxx WAD = 18xx%)
        } else if (what == "tip") {
            s_tip = uint192(data); // Flat fee to incentivize keepers (max: 2^192 - 1 => 6.277T RAD)
        } else if (what == "stopped") {
            s_stopped = data; // Set breaker (0, 1, 2, or 3)
        } else {
            revert Clipper__FileUnrecognizedParam();
        }
        emit File(what, data);
    }

    /**
     * @notice Updates a module address; callable only by an authorized address.
     * @param what Module name: "spotter", "dog", "vow", or "calc".
     * @param data New address of the price module, liquidation module, Dai recipient, or price calculator.
     */
    function file(bytes32 what, address data) external auth lock {
        if (what == "spotter") {
            s_spotter = SpotterLike(data);
        } else if (what == "dog") {
            s_dog = DogLike(data);
        } else if (what == "vow") {
            s_vow = data;
        } else if (what == "calc") {
            s_calc = AbacusLike(data);
        } else {
            revert Clipper__FileUnrecognizedParam();
        }
        emit File(what, data);
    }

    /**
     * @notice Starts an auction and pays the configured keeper incentive; requires authorization and a stop level below 1.
     * @dev The caller must arrange for the collateral to be held by this contract in the Vat.
     * The starting price is the oracle price divided by par, then multiplied by buf.
     * Keeper incentives create internal Dai for kpr and matching unbacked debt for the Vow.
     * @param tab Internal Dai target, normally including the liquidation penalty [rad].
     * @param lot Collateral available to sell [wad].
     * @param usr Recipient of collateral left over after the Dai target is met; must be nonzero.
     * @param kpr Recipient of the fixed and proportional auction-start incentive.
     * @return id Newly allocated auction identifier.
     */
    function kick(
        uint256 tab, // Debt: Dai the auction aims to raise, normally including the liquidation penalty.   [rad]
        uint256 lot, // Amount of collateral available to sell.                                            [wad]
        address usr, // Address that will receive any leftover collateral
        address kpr // Address that will receive incentives
    )
        external
        auth
        lock // prevents reentrancy
        isStopped(1) // blocks new auctions whenever the circuit breaker is enabled
        returns (uint256 id)
    {
        // 1. Input validation
        if (tab == 0) {
            revert Clipper__ZeroTab();
        }
        if (lot == 0) {
            revert Clipper__ZeroLot();
        }
        if (usr == address(0)) {
            revert Clipper__ZeroUsr();
        }
        // 2. Creates the auction record.
        // It increments s_kicks to obtain a new auction ID
        id = ++s_kicks;
        // Adds that ID to s_active
        s_active.push(id);

        s_sales[id].pos = s_active.length - 1; // Stores the index in the active auctions array

        s_sales[id].tab = tab;
        s_sales[id].lot = lot;
        s_sales[id].usr = usr;
        s_sales[id].tic = uint96(block.timestamp); // the current timestamp, from which price decay is measured.

        // 3. Sets the starting price, top.
        uint256 top;
        // feedPrice = oracle collateral price / Dai reference price (par)
        // top  = feedPrice × starting-price multiplier (buf)
        top = Math.rmul(getFeedPrice(), s_buf);
        if (top == 0) {
            revert Clipper__ZeroTopPrice();
        }
        s_sales[id].top = top;

        // incentive to kick auction
        uint256 _tip = s_tip; // tip is a fixed reward
        uint256 _chip = s_chip; // chip is a percentage of the auction’s Dai target.
        uint256 coin;
        // 4. Optionally pays the keeper.
        if (_tip > 0 || _chip > 0) {
            coin = _tip + tab * _chip / Math.WAD;
            // Creates internal Dai for kpr and records matching unbacked debt against Vow.
            i_vat.suck(s_vow, kpr, coin);
        }

        emit Kick(id, top, tab, lot, usr, kpr, coin);
    }

    /**
     * @notice Restarts an eligible auction using the current oracle price and pays an eligible keeper incentive.
     * @dev Requires a stop level below 2 and an auction whose elapsed time exceeds tail or whose price ratio is below cusp.
     * Resets the start time and buffered starting price. An incentive is paid only when both the remaining Dai target
     * and the remaining collateral's oracle value are at least chost.
     * @param id Identifier of the active auction to reset.
     * @param kpr Recipient of any reset incentive.
     */
    function redo(
        uint256 id, // id of the auction to reset
        address kpr // Address that will receive incentives
    )
        external
        lock
        isStopped(2)
    {
        // Read auction data
        address usr = s_sales[id].usr;
        uint96 tic = s_sales[id].tic;
        uint256 top = s_sales[id].top;

        if (usr == address(0)) {
            revert Clipper__NotRunningAuction();
        }

        // Check that auction needs reset
        // and compute current price [ray]
        (bool done,) = status(tic, top);
        if (!done) {
            revert Clipper__CannotReset();
        }

        uint256 tab = s_sales[id].tab;
        uint256 lot = s_sales[id].lot;
        s_sales[id].tic = uint96(block.timestamp);

        uint256 feedPrice = getFeedPrice();
        top = Math.rmul(feedPrice, s_buf);
        if (top == 0) {
            revert Clipper__ZeroTopPrice();
        }
        s_sales[id].top = top;

        // incentive to redo auction
        uint256 _tip = s_tip;
        uint256 _chip = s_chip;
        uint256 coin;
        if (_tip > 0 || _chip > 0) {
            uint256 _chost = s_chost;
            if (tab >= _chost && lot * feedPrice >= _chost) {
                coin = _tip + tab * _chip / Math.WAD;
                i_vat.suck(s_vow, kpr, coin);
            }
        }

        emit Redo(id, top, tab, lot, usr, kpr, coin);
    }

    /**
     * @notice Buys up to amt collateral at the current auction price, paying internal Dai from the caller.
     * @dev Requires a stop level below 3 and an active auction that does not need a reset.
     * Caps payment at the remaining Dai target and reduces partial purchases when necessary to leave at least chost.
     * If the target is at most chost, a purchase must exhaust the collateral or meet the Dai target.
     * Transfers collateral before an optional callback, then moves the caller's internal Dai to the Vow and updates Dog.
     * Closes the auction when its collateral or Dai target is exhausted, returning surplus collateral to usr.
     * @param id Identifier of the active auction to buy from.
     * @param amt Maximum collateral amount to purchase [wad].
     * @param max Highest acceptable price in Dai per collateral unit [ray].
     * @param who Collateral recipient and optional callback target. Callbacks to Vat and Dog are skipped.
     * @param data Callback data passed to who.clipperCall together with the caller, Dai owed [rad], and collateral
     * purchased [wad]. Empty data skips the callback.
     */
    function take(
        uint256 id, // Auction id
        uint256 amt, // Upper limit on amount of collateral to buy  [wad]
        uint256 max, // Maximum acceptable price (DAI / collateral) [ray]
        address who, // Receiver of collateral and external call address
        bytes calldata data // Data to pass in external call; if length 0, no call is done
    )
        external
        lock
        isStopped(3)
    {
        address usr = s_sales[id].usr;
        uint96 tic = s_sales[id].tic;

        if (usr == address(0)) {
            revert Clipper__NotRunningAuction();
        }

        uint256 price;
        {
            bool done;
            (done, price) = status(tic, s_sales[id].top);

            // Check that auction doesn't need reset
            if (done) {
                revert Clipper__NeedsReset();
            }
        }

        // Ensure price is acceptable to buyer
        if (max < price) {
            revert Clipper__TooExpensive();
        }

        uint256 lot = s_sales[id].lot;
        uint256 tab = s_sales[id].tab;
        uint256 owe;

        {
            // Purchase as much as possible, up to amt
            uint256 slice = Math.min(lot, amt); // slice <= lot

            // DAI needed to buy a slice of this sale
            owe = slice * price;

            // Don't collect more than tab of DAI
            if (owe > tab) {
                // Total debt will be paid
                owe = tab; // owe' <= owe
                // Adjust slice
                slice = owe / price; // slice' = owe' / price <= owe / price == slice <= lot
            } else if (owe < tab && slice < lot) {
                // If slice == lot => auction completed => dust doesn't matter
                uint256 _chost = s_chost;
                if (tab - owe < _chost) {
                    // safe as owe < tab
                    // If tab <= chost, buyers have to take the entire lot.
                    if (tab <= _chost) {
                        revert Clipper__NoPartialPurchase();
                    }
                    // Adjust amount to pay
                    owe = tab - _chost; // owe' <= owe
                    // Adjust slice
                    slice = owe / price; // slice' = owe' / price < owe / price == slice < lot
                }
            }

            // Calculate remaining tab after operation
            tab = tab - owe; // safe since owe <= tab
            // Calculate remaining lot after operation
            lot = lot - slice;

            // Send collateral to who
            i_vat.flux(i_ilk, address(this), who, slice);

            // Do external call (if data is defined) but to be
            // extremely careful we don't allow to do it to the two
            // contracts which the Clipper needs to be authorized
            DogLike dog_ = s_dog;
            if (data.length > 0 && who != address(i_vat) && who != address(dog_)) {
                ClipperCallee(who).clipperCall(msg.sender, owe, slice, data);
            }

            // Get DAI from caller
            i_vat.move(msg.sender, s_vow, owe);

            // Removes Dai out for liquidation from accumulator
            dog_.digs(i_ilk, lot == 0 ? tab + owe : owe);
        }

        if (lot == 0) {
            _remove(id);
        } else if (tab == 0) {
            i_vat.flux(i_ilk, address(this), usr, lot);
            _remove(id);
        } else {
            s_sales[id].tab = tab;
            s_sales[id].lot = lot;
        }

        emit Take(id, max, price, owe, tab, lot, usr);
    }

    /**
     * @notice Refreshes the cached minimum Dai target used to limit partial purchases.
     * @dev Anyone may call. Sets chost to the Vat dust limit [rad] multiplied by Dog's liquidation penalty [wad],
     * divided by WAD; later changes to either input require another refresh.
     */
    function upchost() external {
        (,,,, uint256 _dust) = VatLike(i_vat).ilks(i_ilk);
        s_chost = _dust * s_dog.chop(i_ilk) / Math.WAD;
    }

    /**
     * @notice Cancels an active auction and transfers its remaining collateral to the authorized caller.
     * @dev Removes the remaining Dai target from Dog's liquidation accumulator and deletes the auction.
     * @param id Identifier of the active auction to cancel.
     */
    function yank(uint256 id) external auth lock {
        if (s_sales[id].usr == address(0)) {
            revert Clipper__NotRunningAuction();
        }
        s_dog.digs(i_ilk, s_sales[id].tab);
        i_vat.flux(i_ilk, address(this), msg.sender, s_sales[id].lot);
        _remove(id);
        emit Yank(id);
    }

    ////////////////////////////////////////////
    //            Internal Functions          //
    ////////////////////////////////////////////
    /**
     *
     * @dev Reverts with the Clipper-specific authorization error when Auth rejects a caller.
     */
    function _revertNotAuthorized() internal pure override {
        revert Clipper__NotAuthorized();
    }

    /**
     * @dev Reads the collateral oracle directly, requires a valid quote, and divides it by the Dai reference price.
     * Using the oracle avoids relying on a Vat spot value that may reflect an older liquidation ratio.
     * @return feedPrice Collateral price in Dai per collateral unit [ray].
     */
    function getFeedPrice() internal returns (uint256 feedPrice) {
        (PipLike pip,) = s_spotter.ilks(i_ilk);
        (bytes32 val, bool has) = pip.peek();
        if (!has) {
            revert Clipper__InvalidPrice();
        }
        feedPrice = Math.rdiv(Math.toRay(uint256(val)), s_spotter.par());
    }

    /**
     * @dev Deletes an auction and removes its ID from the active array by moving the last entry into its slot.
     * Assumes id identifies an active auction; active auction ordering is not preserved.
     * @param id Identifier of the auction to remove.
     */
    function _remove(uint256 id) internal {
        uint256 _move = s_active[s_active.length - 1];
        if (id != _move) {
            uint256 _index = s_sales[id].pos;
            s_active[_index] = _move;
            s_sales[_move].pos = _index;
        }
        s_active.pop();
        delete s_sales[id];
    }

    //////////////////////////////////////////////////////////////////
    //            Internal & private view & pure functions          //
    //////////////////////////////////////////////////////////////////
    /**
     *
     * @dev Computes the decayed price and whether the elapsed-time or relative-price reset threshold is crossed.
     * @param tic Timestamp of the auction's latest start or reset [seconds since Unix epoch].
     * @param top Starting price from the latest start or reset [ray]; expected to be nonzero.
     * @return done True when elapsed time exceeds tail or current price divided by top is below cusp.
     * @return price Current collateral price returned by the configured calculator [ray].
     */
    function status(uint96 tic, uint256 top) internal view returns (bool done, uint256 price) {
        price = s_calc.price(top, block.timestamp - tic);
        done = (block.timestamp - tic > s_tail || Math.rdiv(price, top) < s_cusp);
    }

    /////////////////////////////////////////////////////////////////
    //            External & public view & pure functions          //
    /////////////////////////////////////////////////////////////////
    /**
     * @notice Returns the number of currently active auctions.
     * @return Number of active auction IDs.
     */
    function count() external view returns (uint256) {
        return s_active.length;
    }

    /**
     * @notice Returns all currently active auction IDs.
     * @dev Ordering may change when an auction is removed.
     * @return Array of active auction identifiers.
     */
    function list() external view returns (uint256[] memory) {
        return s_active;
    }

    /**
     * @notice Returns whether an auction needs a reset, its current price, and its remaining amounts.
     * @dev Calls the price calculator even for inactive IDs; querying an inactive ID may revert.
     * @param id Identifier of the auction to inspect.
     * @return needsRedo True if the auction is active and meets a reset condition.
     * @return price Current collateral price [ray].
     * @return lot Collateral remaining for sale [wad].
     * @return tab Internal Dai still to raise [rad].
     */
    function getStatus(uint256 id) external view returns (bool needsRedo, uint256 price, uint256 lot, uint256 tab) {
        // Read auction data
        address usr = s_sales[id].usr;
        uint96 tic = s_sales[id].tic;

        bool done;
        (done, price) = status(tic, s_sales[id].top);

        needsRedo = usr != address(0) && done;
        lot = s_sales[id].lot;
        tab = s_sales[id].tab;
    }

    // --- Getters ---
    /**
     * @notice Returns the collateral type handled by this auction house.
     * @return Collateral type identifier.
     */
    function ilk() external view returns (bytes32) {
        return i_ilk;
    }

    /**
     * @notice Returns the core ledger.
     * @return Vat contract holding collateral, internal Dai, and debt.
     */
    function vat() external view returns (VatLike) {
        return i_vat;
    }

    /**
     * @notice Returns the liquidation module.
     * @return Dog contract tracking debt assigned to auctions.
     */
    function dog() external view returns (DogLike) {
        return s_dog;
    }

    /**
     * @notice Returns the recipient of auction proceeds.
     * @return Vow address receiving internal Dai.
     */
    function vow() external view returns (address) {
        return s_vow;
    }

    /**
     * @notice Returns the collateral price module.
     * @return Spotter contract providing the oracle and Dai reference price.
     */
    function spotter() external view returns (SpotterLike) {
        return s_spotter;
    }

    /**
     * @notice Returns the auction price calculator.
     * @return Calculator used to decay each auction starting price.
     */
    function calc() external view returns (AbacusLike) {
        return s_calc;
    }

    /**
     * @notice Returns the starting-price multiplier.
     * @return Multiplier applied to the oracle-derived Dai price [ray].
     */
    function buf() external view returns (uint256) {
        return s_buf;
    }

    /**
     * @notice Returns the auction duration threshold for resets.
     * @return Elapsed seconds above which an auction requires a reset.
     */
    function tail() external view returns (uint256) {
        return s_tail;
    }

    /**
     * @notice Returns the relative-price threshold for resets.
     * @return Price-to-starting-price ratio below which an auction requires a reset [ray].
     */
    function cusp() external view returns (uint256) {
        return s_cusp;
    }

    /**
     * @notice Returns the proportional keeper incentive.
     * @return Fraction of the remaining Dai target paid as a keeper incentive [wad].
     */
    function chip() external view returns (uint64) {
        return s_chip;
    }

    /**
     * @notice Returns the fixed keeper incentive.
     * @return Flat internal Dai reward paid to eligible keepers [rad].
     */
    function tip() external view returns (uint192) {
        return s_tip;
    }

    /**
     * @notice Returns the cached minimum remaining Dai target.
     * @return Cached dust multiplied by the liquidation penalty, used to limit partial purchases [rad].
     */
    function chost() external view returns (uint256) {
        return s_chost;
    }

    /**
     * @notice Returns the total number of auctions started.
     * @return Cumulative auction count, also the latest allocated auction ID.
     */
    function kicks() external view returns (uint256) {
        return s_kicks;
    }

    /**
     * @notice Returns the current circuit-breaker level.
     * @return Level: 0 enables all operations, 1 stops kick, 2 also stops redo, and 3 or higher also stops take.
     */
    function stopped() external view returns (uint256) {
        return s_stopped;
    }

    /**
     * @notice Returns the active auction ID at a given array index.
     * @param index Zero-based position in the active array; must be less than count().
     * @return Auction identifier at index. Positions may change when auctions are removed.
     */
    function active(uint256 index) external view returns (uint256) {
        return s_active[index];
    }

    /**
     * @notice Returns the stored auction record; an inactive ID has a zeroed record.
     * @param id Identifier of the auction to inspect.
     * @return pos Position in the active auction array.
     * @return tab Internal Dai still to raise [rad].
     * @return lot Collateral remaining for sale [wad].
     * @return usr Recipient of surplus collateral after the Dai target is met.
     * @return tic Timestamp of the latest start or reset [seconds since Unix epoch].
     * @return top Starting collateral price from the latest start or reset [ray].
     */
    function sales(uint256 id)
        external
        view
        returns (uint256 pos, uint256 tab, uint256 lot, address usr, uint96 tic, uint256 top)
    {
        Sale storage sale = s_sales[id];
        return (sale.pos, sale.tab, sale.lot, sale.usr, sale.tic, sale.top);
    }
}
