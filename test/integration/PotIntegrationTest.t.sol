// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {Pot} from "../../src/Pot.sol";
import {Vat} from "../../src/Vat.sol";
import {Dai} from "../../src/Dai.sol";
import {DaiJoin} from "../../src/join/DaiJoin.sol";

contract PotIntegrationTest is Test {
    uint256 internal constant RAY = 1e27;

    Vat internal vat;
    Dai internal dai;
    DaiJoin internal daiJoin;
    Pot internal pot;
    address internal alice;
    address internal vow;

    function setUp() public {
        alice = makeAddr("alice");
        vow = makeAddr("vow");
        vat = new Vat();
        dai = new Dai();
        daiJoin = new DaiJoin(address(vat), address(dai));
        pot = new Pot(address(vat));

        dai.rely(address(daiJoin)); // Allow the adapter to mint wallet Dai.
        vat.rely(address(pot)); // Allow Pot to create internal Dai for interest.
        pot.file("vow", vow); // Interest creates matching unbacked debt here.
        // Deliberately exaggerated: 10% per second makes compounding easy to follow.
        pot.file("dsr", 11 * RAY / 10);

        // Give Alice 100 Dai
        // This creates 100 internal Dai for Alice and records 100 unbacked debt against the test contract.
        vat.suck(address(this), alice, 100 ether * RAY);

        vm.startPrank(alice);
        vat.hope(address(daiJoin));
        vat.hope(address(pot));
        daiJoin.exit(alice, 100 ether); // Alice's 100 internal Dai move to DaiJoin adapter and the adapters mints Alice 100 ERC-20 Dai
        dai.approve(address(daiJoin), 100 ether);
        vm.stopPrank();
    }

    // verifies the complete savings flow: Alice deposits 100 Dai, earns 21 Dai in interest, and withdraws 121 Dai.
    function test_DepositAccrueInterestAndWithdraw() public {
        // 1. Convert wallet Dai into internal Dai.
        vm.startPrank(alice);
        daiJoin.join(alice, 100 ether);
        assertEq(dai.balanceOf(alice), 0);
        assertEq(vat.dai(alice), 100 ether * RAY);

        // 2. Deposit into savings (Pot)
        // pot.join moves that internal Dai into the Pot and gives Alice 100 savings shares (pie). Initially, each share is worth 1 Dai (chi).
        pot.join(100 ether);
        vm.stopPrank();
        assertEq(pot.pie(alice), 100 ether);
        assertEq(vat.dai(alice), 0);
        assertEq(vat.dai(address(pot)), 100 ether * RAY);

        // 3. Accrue interest.
        // drip compounds two seconds: chi = 1.1 * 1.1 = 1.21.
        // 100 shares × 1.21 Dai per share = 121 Dai
        // Interest earned = 121 − 100 = 21 Dai
        vm.warp(block.timestamp + 2 seconds);
        pot.drip();
        assertEq(pot.chi(), 121 * RAY / 100);
        assertEq(pot.pie(alice), 100 ether);
        assertEq(vat.dai(address(pot)), 121 ether * RAY);
        assertEq(vat.sin(vow), 21 ether * RAY);

        // 4. Withdraw.
        // Redeem all 100 shares for 121 internal Dai
        // exit takes shares, not the Dai amount to withdraw.
        vm.startPrank(alice);
        pot.exit(100 ether);
        assertEq(pot.pie(alice), 0);
        assertEq(vat.dai(alice), 121 ether * RAY);

        // 5. Alice converts internal Dai into wallet Dai
        // Her 121 internal Dai moves to DaiJoin, which mints 121 wallet Dai for her.
        daiJoin.exit(alice, 121 ether);
        vm.stopPrank();
        assertEq(dai.balanceOf(alice), 121 ether);
    }
}
