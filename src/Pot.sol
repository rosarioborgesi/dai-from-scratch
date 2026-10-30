// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2018 Rain <rainbreak@riseup.net>
pragma solidity 0.8.35;

import {Shutdown} from "./Shutdown.sol";
import {Math} from "./libraries/Math.sol";

/**
 * @notice Internal Dai accounting operations used by the savings module.
 */
interface VatLike {
    /**
     * @notice Transfers internal Dai between Vat accounts.
     * @param source Account supplying Dai; the caller must have its permission.
     * @param destination Account receiving Dai.
     * @param rad Internal Dai amount [rad].
     */
    function move(address source, address destination, uint256 rad) external;

    /**
     * @notice Creates internal Dai and matching unbacked debt; requires Vat authorization.
     * @param debtor Account receiving unbacked debt.
     * @param recipient Account receiving internal Dai.
     * @param rad Internal Dai and debt amount [rad].
     */
    function suck(address debtor, address recipient, uint256 rad) external;
}

/**
 * @title Pot
 * @notice Accepts internal Dai deposits and accrues the Dai Savings Rate.
 * @dev Savings shares (pie) use wad precision, their Dai value (chi) uses ray
 *      precision, and Vat balances use rad precision: Dai = pie * chi.
 *      Shares are not transferable tokens. Pot must be authorized in Vat to
 *      fund interest, and depositors must grant Pot permission through Vat.hope.
 */
contract Pot is Shutdown {
    error Pot__NotAuthorized();
    error Pot__NotLive();
    error Pot__RhoNotUpdated();
    error Pot__FileUnrecognizedParam();
    error Pot__InvalidTimestamp();

    using Math for uint256;

    mapping(address user => uint256 shares) private s_pie;

    uint256 private s_Pie; // Total normalized savings shares [wad].
    uint256 private s_dsr; // Per-second Dai Savings Rate [ray].
    uint256 private s_chi; // Accumulated internal Dai value per share [ray].
    VatLike private immutable i_vat;
    address private s_vow; // Account charged with the debt funding interest.
    uint256 private s_rho; // Timestamp of the last interest accrual [unix seconds].

    /**
     * @notice Initializes savings with a neutral rate and one Dai per share.
     * @param vatAddress Address of the Vat accounting engine.
     */
    constructor(address vatAddress) {
        i_vat = VatLike(vatAddress);
        s_dsr = Math.RAY;
        s_chi = Math.RAY;
        s_rho = block.timestamp;
    }

    /**
     * @notice Sets the per-second savings rate after interest has been accrued.
     * @dev Requires a live Pot and rho equal to the current timestamp.
     *      As in the reference contract, rates below one ray can be configured,
     *      but drip reverts if they would decrease chi.
     * @param what Parameter name; must be "dsr".
     * @param data New per-second savings rate [ray].
     */
    function file(bytes32 what, uint256 data) external auth isAlive {
        if (block.timestamp != s_rho) {
            revert Pot__RhoNotUpdated();
        }
        if (what == "dsr") {
            s_dsr = data;
        } else {
            revert Pot__FileUnrecognizedParam();
        }
    }

    /**
     * @notice Sets the account charged with debt when savings interest is funded.
     * @dev Remains available after shutdown, matching the reference contract.
     * @param what Parameter name; must be "vow".
     * @param data Debt engine address.
     */
    function file(bytes32 what, address data) external auth {
        if (what == "vow") {
            s_vow = data;
        } else {
            revert Pot__FileUnrecognizedParam();
        }
    }

    /**
     * @notice Compounds savings interest through the current timestamp.
     * @dev Creates internal Dai in Vat for the increase in total savings value
     *      and assigns the matching unbacked debt to vow. Reverts on a backwards
     *      timestamp, a decrease in chi, or arithmetic overflow.
     * @return updatedChi Accumulated internal Dai value per share [ray].
     */
    function drip() external returns (uint256 updatedChi) {
        if (block.timestamp < s_rho) {
            revert Pot__InvalidTimestamp();
        }
        updatedChi = Math.rpow(s_dsr, block.timestamp - s_rho, Math.RAY).rmul(s_chi);
        uint256 deltaChi = updatedChi - s_chi;
        s_chi = updatedChi;
        s_rho = block.timestamp;
        i_vat.suck(s_vow, address(this), s_Pie * deltaChi);
    }

    /**
     * @notice Deposits internal Dai in exchange for normalized savings shares.
     * @dev Requires an up-to-date chi and Vat permission from the caller.
     *      Deposits remain available after shutdown, as in the reference Pot.
     * @param wad Savings shares to credit [wad]; costs wad * chi internal Dai [rad].
     */
    function join(uint256 wad) external {
        if (block.timestamp != s_rho) {
            revert Pot__RhoNotUpdated();
        }
        s_pie[msg.sender] += wad;
        s_Pie += wad;
        i_vat.move(msg.sender, address(this), s_chi * wad);
    }

    /**
     * @notice Redeems normalized savings shares for internal Dai.
     * @dev Uses the stored chi without requiring drip; unaccrued interest is
     *      excluded from the payout. Withdrawals remain available after shutdown.
     * @param wad Savings shares to redeem [wad]; returns wad * chi internal Dai [rad].
     */
    function exit(uint256 wad) external {
        s_pie[msg.sender] -= wad;
        s_Pie -= wad;
        i_vat.move(address(this), msg.sender, s_chi * wad);
    }

    /**
     * @notice Shuts down Pot and resets the savings rate to one ray.
     * @dev Called by the inherited authorized cage function. Does not accrue
     *      pending interest or change chi or rho, matching the reference Pot.
     */
    function _cage() internal override {
        super._cage();
        s_dsr = Math.RAY;
    }

    /**
     * @dev Supplies Pot's authorization error to the shared auth modifier.
     */
    function _revertNotAuthorized() internal pure override {
        revert Pot__NotAuthorized();
    }

    /**
     * @dev Supplies Pot's shutdown error to the shared isAlive modifier.
     */
    function _revertNotLive() internal pure override {
        revert Pot__NotLive();
    }

    /**
     * @notice Returns an account's normalized savings shares [wad].
     * @param user Account holding shares.
     * @return shares Account's savings shares.
     */
    function pie(address user) external view returns (uint256 shares) {
        return s_pie[user];
    }

    /**
     * @notice Returns the total normalized savings shares [wad].
     * @return shares Total outstanding savings shares.
     */
    function Pie() external view returns (uint256 shares) {
        return s_Pie;
    }

    /**
     * @notice Returns the per-second Dai Savings Rate [ray].
     * @return rate Configured savings rate.
     */
    function dsr() external view returns (uint256 rate) {
        return s_dsr;
    }

    /**
     * @notice Returns the accumulated internal Dai value per share [ray].
     * @return accumulator Stored savings accumulator.
     */
    function chi() external view returns (uint256 accumulator) {
        return s_chi;
    }

    /**
     * @notice Returns the Vat accounting engine.
     * @return engine Vat used for deposits, withdrawals, and interest funding.
     */
    function vat() external view returns (VatLike engine) {
        return i_vat;
    }

    /**
     * @notice Returns the debt engine address.
     * @return debtor Account charged with debt when interest is funded.
     */
    function vow() external view returns (address debtor) {
        return s_vow;
    }

    /**
     * @notice Returns the timestamp of the last interest accrual [unix seconds].
     * @return timestamp Last accrual timestamp.
     */
    function rho() external view returns (uint256 timestamp) {
        return s_rho;
    }
}
