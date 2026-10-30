// SPDX-License-Identifier: AGPL-3.0-or-later
// Based on dss/src/abaci.sol, Copyright (C) 2020-2022 Dai Foundation.
pragma solidity 0.8.35;

import {Auth} from "./Auth.sol";
import {Math} from "./libraries/Math.sol";

interface Abacus {
    /// @param top Initial auction price [ray].
    /// @param dur Seconds elapsed since the auction started.
    /// @return Current auction price [ray].
    function price(uint256 top, uint256 dur) external view returns (uint256);
}

/// @notice Decreases the auction price linearly to zero over tau seconds.
contract LinearDecrease is Auth, Abacus {
    error LinearDecrease__NotAuthorized();
    error LinearDecrease__FileUnrecognizedParam();

    uint256 private s_tau; // Seconds until the price reaches zero.

    event File(bytes32 indexed what, uint256 data);

    constructor() {
        emit Rely(msg.sender);
    }

    function file(bytes32 what, uint256 data) external auth {
        if (what == "tau") {
            s_tau = data;
        } else {
            revert LinearDecrease__FileUnrecognizedParam();
        }
        emit File(what, data);
    }

    function _revertNotAuthorized() internal pure override {
        revert LinearDecrease__NotAuthorized();
    }

    function tau() external view returns (uint256) {
        return s_tau;
    }

    function price(uint256 top, uint256 dur) external view override returns (uint256) {
        // Also handles an unconfigured (zero) tau without dividing by zero.
        if (dur >= s_tau) return 0;
        // Preserve DSS rounding: truncate the ray-scaled fraction before multiplying by top.
        return Math.rmul(top, ((s_tau - dur) * Math.RAY) / s_tau);
    }
}

/// @notice Applies a multiplicative price cut at each completed step.
/// @dev Configure a nonzero step and a cut in [0, RAY] before use.
contract StairstepExponentialDecrease is Auth, Abacus {
    error StairstepExponentialDecrease__NotAuthorized();
    error StairstepExponentialDecrease__FileUnrecognizedParam();
    error StairstepExponentialDecrease__CutGtRay();

    uint256 private s_step; // Seconds between price drops.
    uint256 private s_cut; // Fraction of the price retained per step [ray].

    event File(bytes32 indexed what, uint256 data);

    constructor() {
        emit Rely(msg.sender);
    }

    function file(bytes32 what, uint256 data) external auth {
        if (what == "cut") {
            if (data > Math.RAY) revert StairstepExponentialDecrease__CutGtRay();
            s_cut = data;
        } else if (what == "step") {
            s_step = data;
        } else {
            revert StairstepExponentialDecrease__FileUnrecognizedParam();
        }
        emit File(what, data);
    }

    function _revertNotAuthorized() internal pure override {
        revert StairstepExponentialDecrease__NotAuthorized();
    }

    function step() external view returns (uint256) {
        return s_step;
    }

    function cut() external view returns (uint256) {
        return s_cut;
    }

    function price(uint256 top, uint256 dur) external view override returns (uint256) {
        return Math.rmul(top, Math.rpow(s_cut, dur / s_step, Math.RAY));
    }
}

/// @notice Applies a multiplicative price cut every second.
/// @dev Configure cut in [0, RAY] before use; RAY retains the price unchanged.
contract ExponentialDecrease is Auth, Abacus {
    error ExponentialDecrease__NotAuthorized();
    error ExponentialDecrease__FileUnrecognizedParam();
    error ExponentialDecrease__CutGtRay();

    uint256 private s_cut; // Fraction of the price retained per second [ray].

    event File(bytes32 indexed what, uint256 data);

    constructor() {
        emit Rely(msg.sender);
    }

    function file(bytes32 what, uint256 data) external auth {
        if (what == "cut") {
            if (data > Math.RAY) revert ExponentialDecrease__CutGtRay();
            s_cut = data;
        } else {
            revert ExponentialDecrease__FileUnrecognizedParam();
        }
        emit File(what, data);
    }

    function _revertNotAuthorized() internal pure override {
        revert ExponentialDecrease__NotAuthorized();
    }

    function cut() external view returns (uint256) {
        return s_cut;
    }

    function price(uint256 top, uint256 dur) external view override returns (uint256) {
        return Math.rmul(top, Math.rpow(s_cut, dur, Math.RAY));
    }
}
