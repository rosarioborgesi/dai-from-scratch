// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {DSSProxy, JugLike, VatLike} from "../../../src/proxy/DssProxy.sol";

contract MockVat is VatLike {
    error MockVat__UnsupportedCall();

    mapping(address urn => uint256 balance) private s_dai;
    mapping(bytes32 ilk => uint256 rate) private s_rates;
    mapping(bytes32 ilk => mapping(address urn => uint256 art)) private s_art;

    function setRate(bytes32 ilk, uint256 rate) external {
        s_rates[ilk] = rate;
    }

    function setArt(bytes32 ilk, address urn, uint256 art) external {
        s_art[ilk][urn] = art;
    }

    function setDai(address urn, uint256 balance) external {
        s_dai[urn] = balance;
    }

    function dai(address urn) external view override returns (uint256) {
        return s_dai[urn];
    }

    // These interface methods are unused by the debt calculation helpers.
    function can(address, address) external pure override returns (uint256) {
        revert MockVat__UnsupportedCall();
    }

    function ilks(bytes32 ilk) external view override returns (uint256, uint256, uint256, uint256, uint256) {
        return (0, s_rates[ilk], 0, 0, 0);
    }

    function urns(bytes32 ilk, address urn) external view override returns (uint256, uint256) {
        return (0, s_art[ilk][urn]);
    }

    function frob(bytes32, address, address, address, int256, int256) external pure override {
        revert MockVat__UnsupportedCall();
    }

    function hope(address) external pure override {
        revert MockVat__UnsupportedCall();
    }

    function move(address, address, uint256) external pure override {
        revert MockVat__UnsupportedCall();
    }

    function flux(bytes32 ilk, address src, address dst, uint256 wad) external pure override {
        revert MockVat__UnsupportedCall();
    }
}

contract MockJug is JugLike {
    mapping(bytes32 ilk => uint256 rate) public rates;

    function setRate(bytes32 ilk, uint256 rate) external {
        rates[ilk] = rate;
    }

    function drip(bytes32 ilk) external override returns (uint256) {
        return rates[ilk];
    }
}

contract DSSProxyHarness is DSSProxy {
    constructor(address vat) DSSProxy(vat) {}

    function getDrawDart(address jug, address urn, bytes32 ilk, uint256 wad) external returns (int256) {
        return _getDrawDart(ilk, jug, urn, wad);
    }

    function getWipeDart(uint256 dai, address urn, bytes32 ilk) external view returns (int256) {
        return _getWipeDart(ilk, dai, urn);
    }

    function getWipeAllWad(bytes32 ilk, address vat, address user, address urn) external view returns (uint256) {
        return _getWipeAllWad(ilk, vat, user, urn);
    }
}

contract DSSProxyUnitTest is Test {
    uint256 constant RAY = 1e27;
    bytes32 constant ILK = "ETH-A";

    DSSProxyHarness internal proxy;
    MockVat vat;
    MockJug jug;
    address urn;

    function setUp() public {
        vat = new MockVat();
        jug = new MockJug();
        urn = makeAddr("urn");
        proxy = new DSSProxyHarness(address(vat));
    }

    ////////////////////////////
    //      _getDrawDart      //
    ////////////////////////////

    // The user requests 100 DAI and the vault already holds 20 internal DAI,
    // so the system must generate another 80 DAI.
    // 80 DAI at a rate of 1.25 which correspond to 64 units of normalized debt
    function test_GetDrawDart_AccountsForExistingDaiAndRate() public {
        // Internal DAI uses rad (45 decimals); rate uses ray (27 decimals).
        vat.setDai(urn, 20 ether * RAY);
        jug.setRate(ILK, 125e25); // Debt multiplier: 1.25

        int256 dart = proxy.getDrawDart(address(jug), urn, ILK, 100 ether);

        // (100 - 20) / 1.25 = 64 units of normalized debt, stored as wad.
        assertEq(dart, int256(64 ether + 1));
    }

    // The user requests 100 DAI, and the vault already holds 100 internal DAI in the Vat.
    // No additional normalized debt is needed, so dart returns zero.
    function test_GetDrawDart_ReturnsZeroWhenExistingDaiCoversWithdrawal() public {
        // At equality, dai < wad * RAY is false, so no new debt is needed.
        vat.setDai(urn, 100 ether * RAY);
        jug.setRate(ILK, 125e25); // Debt multiplier: 1.25

        int256 dart = proxy.getDrawDart(address(jug), urn, ILK, 100 ether);

        assertEq(dart, int256(0));
    }

    ////////////////////////////
    //      _getWipeDart      //
    ////////////////////////////

    // With art = 100 and rate = 1.05, the vault owes 105 DAI.
    // Supplying 42 DAI covers 40 normalized debt, leaving 60 art and 63 DAI owed.
    function test_GetWipeDart_PartialRepaymentAtUpdatedRate() public {
        uint256 art = 100 ether; // Normalized debt uses wad (18 decimals).
        uint256 rate = 105e25; // 1.05 in ray (27 decimals).
        uint256 suppliedDai = 42 ether * RAY; // Internal DAI uses rad (45 decimals).
        vat.setArt(ILK, urn, art);
        vat.setRate(ILK, rate);
        assertEq(art * rate, 105 ether * RAY);

        int256 dart = proxy.getWipeDart(suppliedDai, urn, ILK);

        assertEq(dart, -int256(40 ether));

        // The helper only calculates dart; these are the results frob would apply.
        uint256 remainingArt = uint256(int256(art) + dart);
        uint256 remainingDai = suppliedDai - uint256(-dart) * rate;
        assertEq(remainingArt, 60 ether);
        assertEq(remainingArt * rate, 63 ether * RAY);
        assertEq(remainingDai, 0);
    }

    // With art = 100 and rate = 1.05, the vault owes 105 DAI.
    // Supplying 120 DAI for the 105 DAI debt caps repayment at 100 art.
    // The vault would owe nothing, with 15 DAI left in the funding Vat balance.
    function test_GetWipeDart_CapsRepaymentAtOutstandingDebt() public {
        uint256 art = 100 ether;
        uint256 rate = 105e25;
        uint256 suppliedDai = 120 ether * RAY;
        vat.setArt(ILK, urn, art);
        vat.setRate(ILK, rate);
        assertEq(art * rate, 105 ether * RAY);

        int256 dart = proxy.getWipeDart(suppliedDai, urn, ILK);

        assertEq(dart, -int256(100 ether));

        // The helper only calculates dart; these are the results frob would apply.
        uint256 remainingArt = uint256(int256(art) + dart);
        uint256 remainingDai = suppliedDai - uint256(-dart) * rate;
        assertEq(remainingArt, 0);
        assertEq(remainingArt * rate, 0);
        assertEq(remainingDai, 15 ether * RAY);
    }

    ////////////////////////////
    //      _getWipeAllWad    //
    ////////////////////////////

    function test_GetWipeAllWad_AccountsForExistingDaiAndRate() public {
        // The vault owes 100 art * 1.05 = 105 DAI.
        vat.setArt(ILK, urn, 100 ether);
        vat.setRate(ILK, 105e25);

        vat.setDai(urn, 30 ether * RAY);

        uint256 wad = proxy.getWipeAllWad(ILK, address(vat), urn, urn);

        // Only 75 additional ERC-20 DAI are needed: 105 - 30 = 75.
        assertEq(wad, 75 ether);
    }

    function test_GetWipeAllWad_RoundsUpToCoverRadRemainder() public {
        vat.setArt(ILK, urn, 100 ether);
        vat.setRate(ILK, RAY); // The vault owes exactly 100 DAI.
        // One rad less than 30 DAI leaves 70 DAI plus one rad to repay.
        vat.setDai(urn, 30 ether * RAY - 1);

        uint256 wad = proxy.getWipeAllWad(ILK, address(vat), urn, urn);

        // A rad is smaller than an ERC-20 DAI wei, so round up by one wei.
        assertEq(wad, 70 ether + 1);
    }
}
