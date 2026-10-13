// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {Vat} from "../../src/Vat.sol";
import {GemJoin, DaiJoin} from "../../src/Join.sol";
import {Dai} from "../../src/Dai.sol";
import {Jug} from "../../src/Jug.sol";
import {DSSProxy} from "../proxy/DssProxy.sol";
import {MockWETH} from "../mocks/MockWETH.sol";

// Similar to tests in https://github.com/sky-ecosystem/dss-proxy-actions/blob/master/src/DssProxyActions.t.sol
contract DssProxyIntegrationTest is Test {
    bytes32 internal constant WETH_A = "WETH-A";
    uint256 internal constant RAY = 1e27;

    Vat internal vat;
    MockWETH internal weth;
    GemJoin internal gemJoin;
    Dai internal dai;
    DaiJoin internal daiJoin;
    Jug internal jug;
    DSSProxy internal proxy;
    address internal user;

    function setUp() public {
        user = makeAddr("user");
        vat = new Vat();
        weth = new MockWETH();
        gemJoin = new GemJoin(address(vat), WETH_A, address(weth));
        proxy = new DSSProxy(address(vat));
        dai = new Dai();
        daiJoin = new DaiJoin(address(vat), address(dai));
        jug = new Jug(address(vat));

        vat.init(WETH_A);
        // Gives the adapter permission to credit collateral balances inside the Vat
        vat.rely(address(gemJoin));
        vat.rely(address(jug));
        dai.rely(address(daiJoin));
        jug.init(WETH_A);

        // One WETH supports up to 2,000 Dai after the safety margin.
        vat.file(WETH_A, "spot", 2_000 * RAY);
        vat.file(WETH_A, "line", 10_000 ether * RAY);
        vat.file("Line", 10_000 ether * RAY);
    }

    //////////////////////////////////////////////
    //      lockGem - Depositing collateral     //
    //////////////////////////////////////////////

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

        // Deposit and lock the collateral.
        proxy.lockGem(address(gemJoin), WETH_A, AMOUNT, true);
        vm.stopPrank();

        assertEq(weth.balanceOf(address(gemJoin)), AMOUNT);
        assertEq(weth.balanceOf(user), 0);
        assertEq(weth.balanceOf(address(proxy)), 0);

        Vat.Urn memory urn = vat.urns(WETH_A, user);        
        assertEq(urn.ink, AMOUNT); // User's collateral locked in the vault        
        assertEq(urn.art, 0); // User's vault normalized debt        
        assertEq(vat.gem(WETH_A, address(proxy)), 0); // Proxy’s free collateral in Vat        
        assertEq(vat.gem(WETH_A, user), 0); // User’s free collateral in Vat
    }

    /////////////////////////////////////////////////////////////////
    //      draw - Borrow DAI     //
    /////////////////////////////////////////////////////////////////
    // It locks 1 WETH, authorizes the proxy, and borrows 100 Dai.
    function test_UserBorrowsDaiAfterLockingWeth() public {
        uint256 collateral = 1 ether;
        uint256 borrowed = 100 ether;
        vm.deal(user, collateral);

        vm.startPrank(user);
        weth.deposit{value: collateral}();
        weth.approve(address(proxy), collateral);
        // Deposit collateral
        proxy.lockGem(address(gemJoin), WETH_A, collateral, true);

        // Locking alone creates no debt and issues no Dai.
        assertEq(vat.urns(WETH_A, user).art, 0);
        assertEq(dai.balanceOf(user), 0);

        // Vat sees the proxy as its caller, so the user must authorize it.
        vat.hope(address(proxy));
        // Borrow Dai
        proxy.draw(WETH_A, address(jug), address(daiJoin), borrowed);
        vm.stopPrank();

        Vat.Urn memory urn = vat.urns(WETH_A, user);
        assertEq(urn.ink, collateral); // Locked collateral in the urn
        // With no accrued fees, the rate is RAY and normalized debt equals borrowed Dai.
        assertEq(vat.ilks(WETH_A).rate, RAY);
        assertEq(urn.art, borrowed); // Normalized debt in the urn
        assertEq(vat.debt(), borrowed * RAY); // Total Dai issued
        assertEq(dai.balanceOf(user), borrowed); 
        assertEq(dai.totalSupply(), borrowed);
        assertEq(dai.balanceOf(address(proxy)), 0);

        // All generated internal Dai was moved through the proxy into DaiJoin.
        assertEq(vat.dai(user), 0);
        assertEq(vat.dai(address(proxy)), 0);
        assertEq(vat.dai(address(daiJoin)), borrowed * RAY);        
        assertEq(weth.balanceOf(address(gemJoin)), collateral);
    }

    /////////////////////////////////////////////////////////////////
    //      lockGemAndDraw - Deposit collateral and borrow DAI     //
    /////////////////////////////////////////////////////////////////

    // The user deposits and locks 1 WETH and receives 100 Dai in one call.
    function test_UserLocksWethAndDrawsDaiInOneCall() public {
        uint256 collateral = 1 ether;
        uint256 borrowed = 100 ether;
        vm.deal(user, collateral);

        vm.startPrank(user);
        weth.deposit{value: collateral}();
        weth.approve(address(proxy), collateral);
        // Vat sees the proxy as its caller when it locks collateral and draws Dai.
        vat.hope(address(proxy));

        proxy.lockGemAndDraw(
            WETH_A, address(jug), address(gemJoin), address(daiJoin), collateral, borrowed, true
        );
        vm.stopPrank();

        // All deposited WETH is held by GemJoin and locked in the user's vault.
        assertEq(weth.balanceOf(user), 0);
        assertEq(weth.balanceOf(address(proxy)), 0);
        assertEq(weth.balanceOf(address(gemJoin)), collateral);
        assertEq(vat.gem(WETH_A, user), 0);
        assertEq(vat.gem(WETH_A, address(proxy)), 0);

        Vat.Urn memory urn = vat.urns(WETH_A, user);
        assertEq(urn.ink, collateral); // User's locked collateral in the vault
        assertEq(vat.urns(WETH_A, address(proxy)).ink, 0);
        assertEq(vat.urns(WETH_A, address(proxy)).art, 0);

        // With rate = RAY, normalized debt equals the requested Dai amount.
        assertEq(vat.ilks(WETH_A).rate, RAY);
        assertEq(urn.art, borrowed); // User's normalized debt in the vault
        assertEq(vat.ilks(WETH_A).art, borrowed); // Total normalized debt for WETH_A collateral
        assertEq(vat.debt(), borrowed * RAY); // Total Dai Issued 
        assertEq(dai.balanceOf(user), borrowed);
        assertEq(dai.totalSupply(), borrowed);
        assertEq(dai.balanceOf(address(proxy)), 0);

        // DaiJoin receives the internal Dai and mints ERC-20 Dai to the user.
        assertEq(vat.dai(user), 0);
        assertEq(vat.dai(address(proxy)), 0);
        assertEq(vat.dai(address(daiJoin)), borrowed * RAY);
        assertEq(vat.can(address(proxy), address(daiJoin)), 1);
    }
}