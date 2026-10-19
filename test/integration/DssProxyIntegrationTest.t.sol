// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test, console} from "forge-std/Test.sol";
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

        // Initialize the WETH_A collateral
        vat.init(WETH_A);
        // Gives the adapter permission to credit collateral balances inside the Vat
        vat.rely(address(gemJoin));
        vat.rely(address(jug));
        dai.rely(address(daiJoin));
        jug.init(WETH_A);

        // One WETH supports up to 2,000 Dai after the safety margin.
        vat.file(WETH_A, "spot", 2_000 * RAY); // Price with Safety Margin
        vat.file(WETH_A, "line", 10_000 ether * RAY); // Debt ceiling
        vat.file("Line", 10_000 ether * RAY); // Total Debt Ceiling
    }

    //////////////////////////////////////////////////
    //      lockETH - Depositing ETH collateral     //
    //////////////////////////////////////////////////

    // The helper wraps native ETH and locks it in the caller's vault without Vat approval.
    function test_UserLocksEth() public {
        uint256 collateral = 1 ether;
        vm.deal(user, collateral);

        vm.prank(user);
        proxy.lockETH{value: collateral}(WETH_A, address(gemJoin));

        // For a deposit of 1 ETH

        // Vat balance	                                                After join	   After frob
        // Proxy’s free collateral (s_gem[WETH_A][address(proxy)])	    1 WETH	       0
        // User’s free collateral (s_gem[WETH_A][user])	                0	           0
        // User’s locked collateral (urn.ink)	                        0	           1 WETH

        assertEq(vat.can(user, address(proxy)), 0);
        assertEq(user.balance, 0);
        assertEq(address(proxy).balance, 0);
        assertEq(address(weth).balance, collateral);
        assertEq(weth.balanceOf(address(gemJoin)), collateral);
        assertEq(weth.balanceOf(user), 0);
        assertEq(weth.balanceOf(address(proxy)), 0);
        assertEq(vat.gem(WETH_A, user), 0); // User’s free collateral in Vat
        assertEq(vat.gem(WETH_A, address(proxy)), 0); // Proxy’s free collateral in Vat

        Vat.Urn memory urn = vat.urns(WETH_A, user);
        assertEq(urn.ink, collateral); // Vault's locked collateral
        assertEq(urn.art, 0); // User's vault normalized debt
        assertEq(vat.urns(WETH_A, address(proxy)).ink, 0);
        assertEq(vat.urns(WETH_A, address(proxy)).art, 0);
    }

    // The user locks 2 ETH from a 5 ETH balance and keeps the remaining 3 ETH.
    // Similar to testLockETH in https://github.com/sky-ecosystem/dss-proxy-actions/blob/master/src/DssProxyActions.t.sol
    function test_UserLocksPartOfEthBalance() public {
        uint256 initialBalance = 5 ether;
        uint256 collateral = 2 ether;
        vm.deal(user, initialBalance);

        assertEq(user.balance, initialBalance);
        assertEq(vat.urns(WETH_A, user).ink, 0);

        vm.prank(user);
        proxy.lockETH{value: collateral}(WETH_A, address(gemJoin));

        Vat.Urn memory urn = vat.urns(WETH_A, user);
        assertEq(urn.ink, collateral); // User's collateral locked in the vault
        assertEq(urn.art, 0);
        assertEq(user.balance, initialBalance - collateral);
        assertEq(address(proxy).balance, 0);
        assertEq(address(weth).balance, collateral);
        assertEq(weth.balanceOf(address(gemJoin)), collateral);
        assertEq(weth.balanceOf(user), 0);
        assertEq(weth.balanceOf(address(proxy)), 0);
        assertEq(vat.gem(WETH_A, address(proxy)), 0);
        assertEq(vat.gem(WETH_A, user), 0);
    }

    /////////////////////////////////////////////////////
    //      lockGem - Depositing ERC-20 collateral     //
    /////////////////////////////////////////////////////

    // User can wrap 1 ETH into WETH and lock it as vault collateral without borrowing any Dai
    function test_UserDepositsAndLocksWeth() public {
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

        // For a deposit of 1 WETH

        // Vat balance	                                                After join	   After frob
        // Proxy’s free collateral (s_gem[WETH_A][address(proxy)])	    1 WETH	       0
        // User’s free collateral (s_gem[WETH_A][user])	                0	           0
        // User’s locked collateral (urn.ink)	                        0	           1 WETH

        assertEq(weth.balanceOf(address(gemJoin)), AMOUNT);
        assertEq(weth.balanceOf(user), 0);
        assertEq(weth.balanceOf(address(proxy)), 0);

        Vat.Urn memory urn = vat.urns(WETH_A, user);
        assertEq(urn.ink, AMOUNT); // User's collateral locked in the vault
        assertEq(urn.art, 0); // User's vault normalized debt
        assertEq(vat.gem(WETH_A, address(proxy)), 0); // Proxy’s free collateral in Vat
        assertEq(vat.gem(WETH_A, user), 0); // User’s free collateral in Vat
    }

    // The user locks 2 WETH from a 5 WETH balance and keeps the remaining 3 WETH.
    // Similar to testLockGem in https://github.com/sky-ecosystem/dss-proxy-actions/blob/master/src/DssProxyActions.t.sol
    function test_UserLocksPartOfWethBalance() public {
        uint256 initialBalance = 5 ether;
        uint256 collateral = 2 ether;
        vm.deal(user, initialBalance);

        vm.startPrank(user);
        weth.deposit{value: initialBalance}();
        weth.approve(address(proxy), collateral);

        assertEq(weth.balanceOf(user), initialBalance);
        assertEq(vat.urns(WETH_A, user).ink, 0);

        proxy.lockGem(address(gemJoin), WETH_A, collateral, true);
        vm.stopPrank();

        Vat.Urn memory urn = vat.urns(WETH_A, user);
        assertEq(urn.ink, collateral); // User's collateral locked in the vault
        assertEq(urn.art, 0);
        assertEq(weth.balanceOf(user), initialBalance - collateral);
        assertEq(weth.balanceOf(address(gemJoin)), collateral);
        assertEq(weth.balanceOf(address(proxy)), 0);
        assertEq(vat.gem(WETH_A, address(proxy)), 0);
        assertEq(vat.gem(WETH_A, user), 0);
    }

    ////////////////////////////////
    //      draw - Borrow DAI     //
    ////////////////////////////////
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

    // The user deposits and locks 1 WETH and receives 100 Dai.
    function test_UserLocksWethAndDrawsDai() public {
        uint256 collateral = 1 ether;
        uint256 borrowed = 100 ether;
        vm.deal(user, collateral);

        vm.startPrank(user);
        weth.deposit{value: collateral}();
        weth.approve(address(proxy), collateral);
        // Vat sees the proxy as its caller when it locks collateral and draws Dai.
        vat.hope(address(proxy));

        proxy.lockGemAndDraw(WETH_A, address(jug), address(gemJoin), address(daiJoin), collateral, borrowed, true);
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

    // Updates the rate before any borrowing.
    // Verifies borrowing at an updated rate.
    // Similar to testDrawAfterDrip in https://github.com/sky-ecosystem/dss-proxy-actions/blob/master/src/DssProxyActions.t.sol
    function testDrawAfterDrip() public {
        uint256 collateral = 2 ether;
        uint256 borrowed = 300 ether;
        uint256 duty = 105 * RAY / 100;
        uint256 initalTimestamp = block.timestamp;

        // Set the fee multiplier at 5% per second.
        jug.file(WETH_A, "duty", duty);
        assertEq(vat.ilks(WETH_A).rate, RAY); // rate is not updated because we haven't called drip

        // Advance time by 1 second
        vm.warp(initalTimestamp + 1);

        assertEq(vat.ilks(WETH_A).rate, RAY); // rate is not updated because we haven't called drip yet
        assertEq(jug.drip(WETH_A), duty); // Drip returns the new rate 1.05 * RAY
        assertEq(vat.ilks(WETH_A).rate, duty); // After calling drip the rate is updated to 1.05 * RAY
        assertEq(jug.ilks(WETH_A).rho, initalTimestamp + 1); // rho is updated inside drip

        // There is no outstanding debt yet, so this changes the multiplier without generating fees on an existing loan.

        vm.deal(user, collateral);
        vm.startPrank(user);
        // Locks 2 ether of collateral
        proxy.lockETH{value: collateral}(WETH_A, address(gemJoin));
        // Authorize borrowing
        vat.hope(address(proxy));
        assertEq(dai.balanceOf(user), 0);

        // Borrow 300 Dai
        // Inside draw the proxy calculates the required normalized debt, creates internal Dai, and
        // uses DaiJoin to mint ERC-20 Dai to the user
        // draw calls drip again, but no additional time has elapsed so the rate remains 1.05
        proxy.draw(WETH_A, address(jug), address(daiJoin), borrowed);
        vm.stopPrank();

        assertEq(vat.ilks(WETH_A).rate, duty); // no additional time has elapsed so the rate remains 1.05

        // normalized debt (art) = actual debt / rate = 300 / 1.05 ≈ 285.714285714285714286
        uint256 expectedArt = borrowed * RAY / duty + 1;

        Vat.Urn memory urn = vat.urns(WETH_A, user);
        assertEq(urn.ink, collateral); // User's collateral in the vault 2 ether
        assertEq(urn.art, expectedArt); // User's vault normalized debt 285.71
        assertEq(vat.ilks(WETH_A).art, expectedArt);
        assertEq(dai.balanceOf(user), borrowed); // User's Dai balance: 300 Dai
        assertEq(dai.totalSupply(), borrowed); // Dai's total supply: 300 Dai

        // vat.debt() consists of 300 Dai withdrawn by the user plus 0.0000000000000000003 Dai left in their internal Vat balance from rounding.
        // So it ends up with:
        // 300000000000000000000300000000000000000000000000 / 10^45 = 300.0000000000000000003 Dai
        assertEq(vat.debt(), expectedArt * duty);

        // Rounding up debt leaves less than one unit of normalized debt in internal Dai.
        uint256 remainder = expectedArt * duty - borrowed * RAY; // 300000000000000000000000000 / 10^45 = 0.0000000000000000003 Dai = 3 x 10^-19 Dai

        assertEq(vat.dai(user), remainder); // 0.0000000000000000003 Dai
        assertEq(vat.dai(address(daiJoin)), borrowed * RAY); // 300 ether * RAY
        assertEq(vat.dai(address(proxy)), 0);
    }

    // Updates the rate after borrowing.
    // verifies borrowing at an updated rate and verifies interest accrual on an outstanding loan.
    // The user locks 2 ETH and then borrows 100 Dai when the rate is still 1
    // Then borrows other 300 Dai when the rate is 1.05
    function test_DrawAccruesFeesOnExistingDebt() public {
        uint256 collateral = 2 ether;
        uint256 initialBorrowed = 100 ether;
        uint256 additionalBorrowed = 300 ether;
        address feeRecipient = makeAddr("vow");
        uint256 initalTimestamp = block.timestamp;
        jug.file("vow", feeRecipient);
        jug.file(WETH_A, "duty", 105 * RAY / 100); // 5 % per-second stability fee

        vm.deal(user, collateral);
        vm.startPrank(user);
        // The user locks 2 ETH
        proxy.lockETH{value: collateral}(WETH_A, address(gemJoin));
        // The user authorizes the proxy
        vat.hope(address(proxy));
        // The user borrows 100 Dai
        proxy.draw(WETH_A, address(jug), address(daiJoin), initialBorrowed);
        vm.stopPrank();
        assertEq(vat.ilks(WETH_A).rate, RAY); // No time has elapsed yet so debt multiplier remains RAY
        assertEq(vat.urns(WETH_A, user).art, initialBorrowed); // Vault normalized debt is 100 ether
        assertEq(vat.dai(feeRecipient), 0); // Fee recipient receives nothing

        // Advance time by 2 seconds
        vm.warp(initalTimestamp + 2);
        assertEq(vat.ilks(WETH_A).rate, RAY); // Stored rate still equals RAY, fees are applied when drip executes

        vm.prank(user);
        // The user borrows another 300 DAI
        // proxy.draw calls _getDrawDart which calls drip before claculating additional debt
        proxy.draw(WETH_A, address(jug), address(daiJoin), additionalBorrowed);

        uint256 expectedRate = 11025 * RAY / 10000; // 1.05² = 1.1025.

        // Since actual debt = normalized debt (art) x rate
        // Normalized debt (art) = actual debt / rate
        //
        // The first 100 Dai (initialBorrowed) wqas borrowed when the rate was 1, so the normalized debt is still 100 Dai
        // additionalBorrowed * RAY / expectedRate converts the new 300 Dai borrowing into normalized debt.
        // Multiplying by RAY compensates for the rate's 1e27 scaling
        // The + 1 is to compensate Solidity's integer division rounding down.
        // additionalBorrowed * RAY / expectedRate = 300 / 1.1025 ≈ 272.108843537 normalized debt

        // Total normalized debt = 100 + 272.108843537 = 372.108843537
        uint256 expectedArt = initialBorrowed + additionalBorrowed * RAY / expectedRate + 1;

        uint256 accruedFees = initialBorrowed * (expectedRate - RAY); // 100 x 0.1025 = 10.25 Dai
        assertEq(vat.ilks(WETH_A).rate, expectedRate); // Debt multiplier 1.1025
        assertEq(jug.ilks(WETH_A).rho, initalTimestamp + 2); // last accrual time rho
        assertEq(vat.urns(WETH_A, user).ink, collateral); // User's locked collateral in the Vault: 2 WETH
        assertEq(vat.urns(WETH_A, user).art, expectedArt); // User's normalized debt in the vault 372.108843537 Dai
        assertEq(vat.ilks(WETH_A).art, expectedArt); // Total normalized debt for the collateral WETH-A
        assertEq(vat.dai(feeRecipient), accruedFees);
        assertEq(vat.debt(), expectedArt * expectedRate); // Total Dai issued = 372.108843537 × 1.1025 ≈ 410.25 Dai
        assertEq(dai.balanceOf(user), initialBorrowed + additionalBorrowed); // User receives 400 Dai
        assertEq(dai.totalSupply(), initialBorrowed + additionalBorrowed); // DAI's Total supply is 400
        assertEq(vat.dai(user), expectedArt * expectedRate - accruedFees - (initialBorrowed + additionalBorrowed) * RAY);
        assertEq(vat.dai(address(daiJoin)), (initialBorrowed + additionalBorrowed) * RAY);
        assertEq(vat.dai(address(proxy)), 0);

        // The actual debt consists of 100 Dai originally borrowed + 10.25 Dai accrued fees + 300 Dai newly borrowed, plus a tiny rounding surplus.
    }
}
