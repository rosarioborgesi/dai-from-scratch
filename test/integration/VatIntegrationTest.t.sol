// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {Vat} from "../../src/Vat.sol";
import {GemJoin} from "../../src/Join.sol";
import {DSSProxy} from "../proxy/DssProxy.sol";
import {MockWETH} from "../mocks/MockWETH.sol";

contract DepositIntegrationTest is Test {
    bytes32 internal constant WETH_A = "WETH-A";

    Vat internal vat;
    MockWETH internal weth;
    GemJoin internal gemJoin;
    DSSProxy internal proxy;
    address internal user;

    function setUp() public {
        user = makeAddr("user");
        vat = new Vat();
        weth = new MockWETH();
        gemJoin = new GemJoin(address(vat), WETH_A, address(weth));
        proxy = new DSSProxy(address(vat));

        vat.init(WETH_A);
        // Gives the adapter permission to credit collateral balances inside the Vat
        vat.rely(address(gemJoin));
    }

    // DEPOSIT - frob function

    // User can wrap 1 ETH into WETH and lock it as vault collateral without borrowing any Dai
    // Similar to testLockGem in https://github.com/sky-ecosystem/dss-proxy-actions/blob/master/src/DssProxyActions.t.sol
    function test_UserDepositsAndLocksWethWithoutDebt() public {
        uint256 AMOUNT = 1 ether;
        // Give the user ETH
        vm.deal(user, AMOUNT);
        // Convert ETH into WETH
        vm.startPrank(user);
        weth.deposit{value: AMOUNT}();
        // Allow the proxy to transfer that WETH
        weth.approve(address(proxy), AMOUNT);

        // Deposit and lock the collateral
        proxy.lockGem(address(gemJoin), WETH_A, user, AMOUNT, true);
        vm.stopPrank();

        assertEq(weth.balanceOf(address(gemJoin)), AMOUNT);
        assertEq(weth.balanceOf(user), 0);
        assertEq(weth.balanceOf(address(proxy)), 0);

        Vat.Urn memory urn = vat.urns(WETH_A, user);
        // User's collateral locked in the vault
        assertEq(urn.ink, AMOUNT);
        // User's vault normalized debt
        assertEq(urn.art, 0);
        // Proxy’s free collateral in Vat
        assertEq(vat.gem(WETH_A, address(proxy)), 0);
        // User’s free collateral in Vat
        assertEq(vat.gem(WETH_A, user), 0);
    }
}
