// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {PipLike} from "../../src/Spot.sol";

contract MockOracle is PipLike {
    bool private s_has;
    bytes32 private s_val;

    function setVal(bytes32 val) external {
        s_val = val;
        s_has = true;
    }

    function void() external {
        // unset the value
        s_has = false;
    }

    function peek() external view override returns (bytes32, bool) {
        return (s_val, s_has);
    }
}
