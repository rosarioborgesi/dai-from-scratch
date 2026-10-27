// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @notice Signed adjustments and fixed-point arithmetic shared by the protocol.
library Math {
    error Math__Overflow();
    error Math__Underflow();
    error Math__Int256OutOfRange();

    uint256 public constant RAY = 1e27;

    // Signed/unsigned arithmetic

    /**
     * @notice Adds a signed adjustment to an unsigned value, reverting on overflow or underflow.
     * @param x The unsigned value to adjust.
     * @param y The signed adjustment; negative values decrease x.
     * @return z The adjusted unsigned value.
     */
    function add(uint256 x, int256 y) internal pure returns (uint256 z) {
        // - If y is positive, it increases x: add(7, 5) → 12.
        // - If y is negative, it decreases x: add(7, -5) → 2.
        // - If y is zero, it returns x.

        // Converting a negative y to uint256 preserves its bits.
        // For example, uint256(-1) is type(uint256).max.
        // Inside unchecked, arithmetic wraps around at 2²⁵⁶,
        // so adding that value has the effect of subtracting one.
        unchecked {
            z = x + uint256(y);
        }

        // Underflow

        // add(0, -1) reverts because the result -1 wraps to type(uint256).max
        // So:
        // y < 0: true because y is -1
        // z > x true because is uint256.max and x is 0
        if (y < 0 && z > x) {
            revert Math__Underflow();
        }

        // Overflow

        // add(type(uint256).max, 1) reverts because the result 2²⁵⁶ wraps to 0
        // So:
        // y > 0 true because y is 1
        // z < x true because z is 0 and x is uint256.max
        if (y > 0 && z < x) {
            revert Math__Overflow();
        }
    }

    /**
     * @notice Subtracts a signed adjustment from an unsigned value, reverting on overflow or underflow.
     * @param x The unsigned value to adjust.
     * @param y The signed adjustment to subtract; negative values increase x.
     * @return z The adjusted unsigned value.
     */
    function sub(uint256 x, int256 y) internal pure returns (uint256 z) {
        // sub(7, 5) → 2
        // sub(7, -5) → 12 Subtracting a negative adds
        // sub(7, 0) → 0

        // unchecked allows arithmetic to wrap around at 2²⁵⁶⁶, instead of Solidity reverting automatically.
        // For negative y, converting it to uint256 preserves its bits.
        // For example, uint256(y) when y = -5 becomes 2²⁵⁶ - 5.
        // Therefore:
        // 7 - 5 = 7 - (2²⁵⁶ - 5) = 12 - 2²⁵⁶
        // Wrapping back into the unsigned range gives 12, the intended result.
        unchecked {
            z = x - uint256(y);
        }

        // Underflow

        // sub(0, 1) wraps to uint256.max and reverts.
        // The intended result is -1
        // y > 0 true because y is equal to 1
        // z > x true because z wraps to uint256.max and x = 0
        if (y > 0 && z > x) {
            revert Math__Underflow();
        }

        // Overflow

        // sub(uint256.max, -1) wraps to zero and reverts
        // The intended result is 2²⁵⁶, but exceeds uint256.max = 2²⁵⁶ - 1
        // y < 0 true because y equal to -1
        // z < x true because z = uint256.max - uint256.max = 0 and x = uint256.max so 0 < uint256.max
        if (y < 0 && z < x) {
            revert Math__Overflow();
        }
    }

    /**
     * @notice Multiplies an unsigned value by a signed value, reverting if x or the product cannot fit in int256.
     * @param x The unsigned factor, which must not exceed the maximum int256 value.
     * @param y The signed factor.
     * @return z The signed product.
     */
    function mul(uint256 x, int256 y) internal pure returns (int256 z) {
        // Checks that x fits an int256
        // uint256 can reach 2²⁵⁶ − 1, but the largest positive int256 is 2²⁵⁵ − 1
        if (x > uint256(type(int256).max)) {
            revert Math__Int256OutOfRange();
        }
        // mul(7, 5) → 35
        // mult(7, -5) → -35
        // mul(7, 0) → 0
        z = int256(x) * y;
    }

    // Calculates x - y  allowing a negative result
    function diff(uint256 x, uint256 y) internal pure returns (int256) {
        // Check that both input fits in int256.
        // int256 maximum value is 2²⁵⁵ - 1 and a uint256 can hold larger values (2²⁵⁶ - 1)
        if (x > uint256(type(int256).max) || y > uint256(type(int256).max)) {
            revert Math__Int256OutOfRange();
        }
        // diff(10, 3) → 7
        // diff(3, 10) → -7
        // diff(5, 5) → 0
        return int256(x) - int256(y);
    }

    // Fixed-point arithmetic

    // Multiplies two ray-scaled numbers
    function rmul(uint256 x, uint256 y) internal pure returns (uint256) {
        // Example: rmul(15e26, 2e27)
        //   = (1.5 x 1e27 x 2 x 1e27) / 1e27
        //   = 3 x 1e27 → This represents 3.0
        return (x * y) / RAY;
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

    function rdiv(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x * RAY) / y;
    }

    // Converts uint256 into int256 with an overflow check.
    function toInt(uint256 amount) internal pure returns (int256) {
        if (amount > uint256(type(int256).max)) {
            revert Math__Overflow();
        }
        return int256(amount);
    }

    // Converts wad [10^18] to rad [10^45]
    function toRad(uint256 wad) internal pure returns (uint256) {
        return wad * RAY;
    }

    // Converts wad [10^18] to ray [10^27]
    function toRay(uint256 wad) internal pure returns (uint256) {
        return wad * 1e9;
    }
}
