// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {JugMath} from "../../src/libraries/JugMath.sol";

contract JugMathHarness {
    function diff(uint256 x, uint256 y) public pure returns (int256) {
        return JugMath.diff(x, y);
    }

    function rmul(uint256 x, uint256 y) public pure returns (uint256) {
        return JugMath.rmul(x, y);
    }

    function rpow(uint256 x, uint256 n, uint256 b) public pure returns (uint256) {
        return JugMath.rpow(x, n, b);
    }
}

contract JugMathUnitTest is Test {
    uint256 internal constant RAY = 1e27;
    uint256 internal constant INT_MAX = uint256(type(int256).max);

    JugMathHarness internal harness;

    function setUp() public {
        harness = new JugMathHarness();
    }

    /////////////////////////////////////
    //              diff               //
    /////////////////////////////////////
    function test_Diff_PositiveResult() public view {
        assertEq(harness.diff(10, 3), 7); // 10 - 3 = 7
    }

    function test_Diff_NegativeResult() public view {
        assertEq(harness.diff(3, 10), -7); // 3 - 10 = -7
    }

    function test_Diff_EqualOperands() public view {
        assertEq(harness.diff(5, 5), 0); // 5 - 5 = 0
        assertEq(harness.diff(INT_MAX, INT_MAX), 0); // int256.max - int256.max = 0
    }

    function test_Diff_ZeroOperands() public view {
        assertEq(harness.diff(0, 0), 0); // 0 - 0 = 0
        assertEq(harness.diff(5, 0), 5); // 5 - 0 = 0
        assertEq(harness.diff(0, 5), -5); // 0 - 5 = -5
    }

    function test_Diff_SignedResultBoundaries() public view {
        assertEq(harness.diff(INT_MAX, 0), type(int256).max); // int256.max - 0 = int256.max
        assertEq(harness.diff(0, INT_MAX), -type(int256).max); // 0 - int256.max = - int256.max
    }

    function test_Diff_RevertOnFirstOperandOutOfRange() public {
        vm.expectRevert(JugMath.JugMath__Int256OutOfRange.selector);
        harness.diff(INT_MAX + 1, 0);
    }

    function test_Diff_RevertOnSecondOperandOutOfRange() public {
        vm.expectRevert(JugMath.JugMath__Int256OutOfRange.selector);
        harness.diff(0, INT_MAX + 1);
    }

    function test_Diff_RevertOnEqualOutOfRangeOperands() public {
        vm.expectRevert(JugMath.JugMath__Int256OutOfRange.selector);
        harness.diff(type(uint256).max, type(uint256).max);
    }

    /////////////////////////////////////
    //              rmul               //
    /////////////////////////////////////
    function test_Rmul_RayScaledProduct() public view {
        assertEq(harness.rmul(15e26, 2e27), 3e27); // 1.5 x 2 = 3
        assertEq(harness.rmul(15e26, 15e26), 225e25); // 1.5 x 1.5 = 2.25
    }

    function test_Rmul_RayIdentity() public view {
        assertEq(harness.rmul(RAY, RAY), RAY); // 1.0 x 1.0 = 1
        assertEq(harness.rmul(123, RAY), 123); // 123 x 1.0 = 123
        assertEq(harness.rmul(RAY, 123), 123); // 1.0 x 123 = 123
    }

    function test_Rmul_ZeroOperands() public view {
        assertEq(harness.rmul(0, 0), 0); // 0 x 0 = 0
        assertEq(harness.rmul(0, type(uint256).max), 0); // 0 x uint256.max = 0
        assertEq(harness.rmul(type(uint256).max, 0), 0); // uint256.max x 0 = 0
    }

    function test_Rmul_TruncatesFractionalResult() public view {
        // 1.5 raw units rounds down even when the remainder is half a ray.
        assertEq(harness.rmul(3, RAY / 2), 1); // 3 x 0.5 = 1 (It should be 1.5)
        assertEq(harness.rmul(RAY / 2, 3), 1); // 0.5 x 3 = 1 (It should be 1.5)
    }

    function test_Rmul_ProductBelowRay() public view {
        assertEq(harness.rmul(RAY - 1, 1), 0); // 0.999999999999999999999999999 x 0.000000000000000000000000001 = 0
        assertEq(harness.rmul(1, 1), 0); // 0.000000000000000000000000001 x 0.000000000000000000000000001 = 0
    }

    function test_Rmul_ExactUintMaxProduct() public view {
        assertEq(harness.rmul(type(uint256).max, 1), type(uint256).max / RAY);
        assertEq(harness.rmul(1, type(uint256).max), type(uint256).max / RAY);
    }

    function test_Rmul_RevertOnProductOverflow() public {
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", uint256(0x11)));
        harness.rmul(type(uint256).max, 2);
    }

    function test_Rmul_RevertOnOverflowBeforeScaling() public {
        // The scaled result would fit, but the intermediate product does not.
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", uint256(0x11)));
        harness.rmul(type(uint256).max / RAY + 1, RAY);
    }

    /////////////////////////////////////
    //              rpow               //
    /////////////////////////////////////
    function test_Rpow_ZeroBase() public view {
        assertEq(harness.rpow(0, 0, RAY), RAY); // 0^0 = 1
        assertEq(harness.rpow(0, 1, RAY), 0); // 0^1 = 0
        assertEq(harness.rpow(0, type(uint256).max, RAY), 0); // 0^uint256.max = 1
    }

    function test_Rpow_ZeroExponent() public view {
        assertEq(harness.rpow(15e26, 0, RAY), RAY); // 1.5^0 = 1
        assertEq(harness.rpow(type(uint256).max, 0, RAY), RAY); // uint256.max^0 = 1
    }

    function test_Rpow_ExponentOne() public view {
        assertEq(harness.rpow(15e26, 1, RAY), 15e26); // 1.5^1 = 1.5
        assertEq(harness.rpow(type(uint256).max, 1, RAY), type(uint256).max); // uint256^1 = uint256
    }

    function test_Rpow_RayIdentity() public view {
        assertEq(harness.rpow(RAY, 2, RAY), RAY); // 1^2 = 1
        assertEq(harness.rpow(RAY, type(uint256).max, RAY), RAY); // 1^ uint256.max = 1
    }

    function test_Rpow_RayScaledPowers() public view {
        assertEq(harness.rpow(15e26, 2, RAY), 225e25); // 1.5 squared = 2.25
        assertEq(harness.rpow(15e26, 3, RAY), 3375e24); // 1.5 cubed = 3.375
        assertEq(harness.rpow(2 * RAY, 10, RAY), 1024 * RAY); // 2 ^ 10 = 1024
        assertEq(harness.rpow(RAY / 2, 3, RAY), 125e24); // 0.5^3 = 0.125
    }

    function test_Rpow_CustomScale() public view {
        // With scale 1000, the stored value 1100 represents 1.1.
        // Since 1.1^3 = 1.331, the result is stored as 1.331 x 1000 = 1331
        assertEq(harness.rpow(1100, 3, 1000), 1331);

        // With scale 1, the stored values are ordinary integers. The calculation is simply 2^8 = 256
        assertEq(harness.rpow(2, 8, 1), 256);
    }

    // Each call uses exponent 2 and scale 10.
    // The input x represents x / 10, and the returned integer represents the result multiplied by 10
    function test_Rpow_SquareRounding() public view {
        assertEq(harness.rpow(4, 2, 10), 2); // 0.4^2 = 1.6 -> rounded result 2
        assertEq(harness.rpow(3, 2, 10), 1); // 0.3^2 = 0.9 -> rounded result = 1
        assertEq(harness.rpow(2, 2, 10), 0); // 0.2^2 = 0.4 -> rounded result = 0
        assertEq(harness.rpow(5, 2, 10), 3); // 0.5^2 = 2.5 -> rounded result = 3
    }

    function test_Rpow_AccumulatorRounding() public view {
        assertEq(harness.rpow(5, 3, 10), 2); // Square (0.5^2) rounds to 0.3; 0.5 * 0.3 rounds to 0.2 (stored as 2) -> The expected result is 0.125
        // Increasing the scale reduces rounding error because it preserves more decimal places.
        // For instance
        // harness.rpow(500, 3, 1000) returns 125, representing 0.125

        assertEq(harness.rpow(6, 3, 10), 2); // Square (0.6^2) rounds to 0.4; 0.6 * 0.4 rounds to 0.2 (stored as 2) -> The expected result is 0.216
    }

    function test_Rpow_OddScaleRounding() public view {
        // (x / b)² × b = x² / b
        assertEq(harness.rpow(2, 2, 3), 1); // 4 / 3 ≈ 1.333 -> rounds down to 1
        assertEq(harness.rpow(4, 2, 3), 5); // 16 / 3 ≈ 5.333 -> rounds down to 5
        assertEq(harness.rpow(5, 2, 3), 8); // 25 / 3 ≈ 8.333 -> rounds down to 8
        assertEq(harness.rpow(2, 2, 5), 1); // 4 / 5 = 0.8 -> rounds up to 1
    }

    function test_Rpow_ZeroScale() public view {
        assertEq(harness.rpow(0, 0, 0), 0);
        assertEq(harness.rpow(2, 0, 0), 0);
        assertEq(harness.rpow(2, 1, 0), 2);
        assertEq(harness.rpow(2, 2, 0), 0);
        assertEq(harness.rpow(2, 3, 0), 0);
    }

    function test_Rpow_LargestBaseWithSafeSquare() public view {
        uint256 x = type(uint128).max;
        assertEq(harness.rpow(x, 2, 1), x * x);
    }
}
