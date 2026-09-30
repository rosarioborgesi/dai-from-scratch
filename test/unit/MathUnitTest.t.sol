// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {Math} from "../../src/libraries/Math.sol";

contract MathHarness {
    function add(uint256 x, int256 y) public pure returns (uint256) {
        return Math.add(x, y);
    }

    function sub(uint256 x, int256 y) public pure returns (uint256) {
        return Math.sub(x, y);
    }

    function mul(uint256 x, int256 y) public pure returns (int256) {
        return Math.mul(x, y);
    }
}

contract MathUnitTest is Test {
    MathHarness internal harness;

    function setUp() public {
        harness = new MathHarness();
    }

    function test_Add_PositiveOperand() public view {
        assertEq(harness.add(7, 5), 12);
    }

    function test_Add_NegativeOperand() public view {
        assertEq(harness.add(7, -5), 2);
    }

    function test_Add_ZeroOperands() public view {
        assertEq(harness.add(0, 0), 0);
        assertEq(harness.add(0, 5), 5);
        assertEq(harness.add(type(uint256).max, 0), type(uint256).max);
    }

    function test_Add_ExactZero() public view {
        assertEq(harness.add(5, -5), 0);
    }

    function test_Add_ExactUintMax() public view {
        assertEq(harness.add(type(uint256).max - 1, 1), type(uint256).max);
    }

    function test_Sub_PositiveOperand() public view {
        assertEq(harness.sub(7, 5), 2);
    }

    function test_Sub_NegativeOperand() public view {
        assertEq(harness.sub(7, -5), 12);
    }

    function test_Sub_ZeroOperands() public view {
        assertEq(harness.sub(0, 0), 0);
        assertEq(harness.sub(0, -5), 5);
        assertEq(harness.sub(type(uint256).max, 0), type(uint256).max);
    }

    function test_Sub_ExactZero() public view {
        assertEq(harness.sub(5, 5), 0);
        assertEq(harness.sub(uint256(type(int256).max), type(int256).max), 0);
    }

    function test_Sub_ExactUintMax() public view {
        assertEq(harness.sub(type(uint256).max - 1, -1), type(uint256).max);
    }

    function test_Sub_IntMinOperand() public view {
        assertEq(harness.sub(uint256(type(int256).max), type(int256).min), type(uint256).max);
    }

    function test_Mul_PositiveProduct() public view {
        assertEq(harness.mul(7, 5), 35);
    }

    function test_Mul_NegativeProduct() public view {
        assertEq(harness.mul(7, -5), -35);
    }

    function test_Mul_ZeroOperands() public view {
        assertEq(harness.mul(0, 0), 0);
        assertEq(harness.mul(0, type(int256).max), 0);
        assertEq(harness.mul(0, type(int256).min), 0);
        assertEq(harness.mul(uint256(type(int256).max), 0), 0);
    }

    function test_Mul_ExactIntMax() public view {
        assertEq(harness.mul(1, type(int256).max), type(int256).max);
        assertEq(harness.mul(uint256(type(int256).max), 1), type(int256).max);
    }

    function test_Mul_ExactIntMin() public view {
        assertEq(harness.mul(1, type(int256).min), type(int256).min);
    }

    function test_Add_RevertOnOverflow() public {
        vm.expectRevert();
        harness.add(type(uint256).max, 1);
    }

    function test_Add_RevertOnUnderflow() public {
        vm.expectRevert();
        harness.add(0, -1);
    }

    function test_Sub_RevertOnUnderflow() public {
        vm.expectRevert();
        harness.sub(0, 1);
    }

    function test_Sub_RevertOnOverflow() public {
        vm.expectRevert();
        harness.sub(type(uint256).max, -1);
    }

    function test_Mul_RevertOnUintMaxInput() public {
        vm.expectRevert();
        harness.mul(type(uint256).max, -1);
    }

    function test_Mul_RevertOnPositiveOverflow() public {
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", uint256(0x11)));
        harness.mul(2, type(int256).max);
    }

    function test_Mul_RevertOnNegativeOverflow() public {
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", uint256(0x11)));
        harness.mul(2, type(int256).min);
    }
}
