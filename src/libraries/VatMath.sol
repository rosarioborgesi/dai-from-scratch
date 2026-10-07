// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

// Math library of the Vat contract
library VatMath {
    error VatMath__Overflow();
    error VatMath__Underflow();
    error VatMath__Int256OutOfRange();

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
            revert VatMath__Underflow();
        }

        // Overflow

        // add(type(uint256).max, 1) reverts because the result 2²⁵⁶ wraps to 0
        // So:
        // y > 0 true because y is 1
        // z < x true because z is 0 and x is uint256.max
        if (y > 0 && z < x) {
            revert VatMath__Overflow();
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
            revert VatMath__Underflow();
        }

        // Overflow

        // sub(uint256.max, -1) wraps to zero and reverts
        // The intended result is 2²⁵⁶, but exceeds uint256.max = 2²⁵⁶ - 1
        // y < 0 true because y equal to -1
        // z < x true because z = uint256.max - uint256.max = 0 and x = uint256.max so 0 < uint256.max
        if (y < 0 && z < x) {
            revert VatMath__Overflow();
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
            revert VatMath__Int256OutOfRange();
        }
        // mul(7, 5) → 35
        // mult(7, -5) → -35
        // mul(7, 0) → 0
        z = int256(x) * y;
    }
}
