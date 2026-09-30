// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

library Math {
    function add(uint256 x, int256 y) internal pure returns (uint256 z) {
        unchecked {
            z = x + uint256(y);
        }
        require(y >= 0 || z <= x);
        require(y <= 0 || z >= x);
    }

    function sub(uint256 x, int256 y) internal pure returns (uint256 z) {
        unchecked {
            z = x - uint256(y);
        }
        require(y <= 0 || z <= x);
        require(y >= 0 || z >= x);
    }

    function mul(uint256 x, int256 y) internal pure returns (int256 z) {
        require(x <= uint256(type(int256).max));
        z = int256(x) * y;
    }
}
