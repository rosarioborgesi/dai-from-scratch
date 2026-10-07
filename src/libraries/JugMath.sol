// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

library JugMath {
    error JugMath__Int256OutOfRange();
    error RpowOverflow();

    uint256 private constant ONE = 1e27; // represents 1.0

    // Calculates x - y  allowing a negative result
    function diff(uint256 x, uint256 y) internal pure returns (int256) {
        // Check that both input fits in int256.
        // int256 maximum value is 2²⁵⁵ - 1 and a uint256 can hold larger values (2²⁵⁶ - 1)
        if (x > uint256(type(int256).max) || y > uint256(type(int256).max)) {
            revert JugMath__Int256OutOfRange();
        }
        // diff(10, 3) → 7
        // diff(3, 10) → -7
        // diff(5, 5) → 0
        return int256(x) - int256(y);
    }

    // Multiplies two ray-scaled numbers
    function rmul(uint256 x, uint256 y) internal pure returns (uint256) {
        // Example: rmul(15e26, 2e27)
        //   = (1.5 x 1e27 x 2 x 1e27) / 1e27
        //   = 3 x 1e27 → This represents 3.0
        return (x * y) / ONE;
    }

    // Calculates the compound growth factor
    // Its Arguments are:
    // x: the scaled number.
    // n: the exponent
    // b: the scale. For ray numbers, this is 1e27.
    // It computes z ≈ (x / b)ⁿ × b ≈ xⁿ / b⁽ⁿ⁻¹⁾
    // For instance in the case of square: (x / b)² × b = x² / b

    // For example with b = 1000, x = 1100 represents 1.1:
    // rpow(1100, 3, 1000) → 1331 represents 1.331 = 1.1³

    // Furthermore harness.rpow(5, 3, 10) which is 0.5^3 rounds to 0.2 (the expected result is 0.125)
    // Increasing the scale reduces rounding error because it preserves more decimal places.
    // For instance
    // harness.rpow(500, 3, 1000) returns 125, representing 0.125
    function rpow(uint256 x, uint256 n, uint256 b) internal pure returns (uint256 z) {
        assembly {
            switch x
            case 0 {
                switch n
                case 0 { z := b }
                default { z := 0 }
            }
            default {
                switch mod(n, 2)
                case 0 { z := b }
                default { z := x }

                let half := div(b, 2) // For rounding.
                for { n := div(n, 2) } n { n := div(n, 2) } {
                    let xx := mul(x, x)
                    if iszero(eq(div(xx, x), x)) { revert(0, 0) }

                    let xxRound := add(xx, half)
                    if lt(xxRound, xx) { revert(0, 0) }

                    x := div(xxRound, b)

                    if mod(n, 2) {
                        let zx := mul(z, x)
                        if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) {
                            revert(0, 0)
                        }

                        let zxRound := add(zx, half)
                        if lt(zxRound, zx) { revert(0, 0) }

                        z := div(zxRound, b)
                    }
                }
            }
        }
    }
}
