// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {DSSProxy, JugLike, VatLike} from "../../proxy/DssProxy.sol";

contract MockVat is VatLike {
    error MockVat__UnsupportedCall();

    mapping(address urn => uint256 balance) private s_dai;

    function setDai(address urn, uint256 balance) external {
        s_dai[urn] = balance;
    }

    function dai(address urn) external view override returns (uint256) {
        return s_dai[urn];
    }

    // These interface methods are unused by _getDrawDart.
    function can(address, address) external pure override returns (uint256) {
        revert MockVat__UnsupportedCall();
    }

    function ilks(bytes32) external pure override returns (uint256, uint256, uint256, uint256, uint256) {
        revert MockVat__UnsupportedCall();
    }

    function urns(bytes32, address) external pure override returns (uint256, uint256) {
        revert MockVat__UnsupportedCall();
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
        return _getDrawDart(jug, urn, ilk, wad);
    }
}

contract DSSProxyUnitTest is Test {
    uint256 internal constant RAY = 1e27;
    bytes32 internal constant ILK = "ETH-A";

    DSSProxyHarness internal proxy;
    MockVat internal vat;
    MockJug internal jug;
    address internal urn;

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
}
