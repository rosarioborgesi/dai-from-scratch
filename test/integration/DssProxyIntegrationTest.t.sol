// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test, console} from "forge-std/Test.sol";
import {Vat} from "../../src/Vat.sol";
import {GemJoin} from "../../src/join/GemJoin.sol";
import {DaiJoin} from "../../src/join/DaiJoin.sol";
import {Dai} from "../../src/Dai.sol";
import {Jug} from "../../src/Jug.sol";
import {Spotter} from "../../src/Spot.sol";
import {DSSProxy} from "../../src/proxy/DssProxy.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {MockOracle} from "../mocks/MockOracle.sol";

// Some tests similar to https://github.com/sky-ecosystem/dss-proxy-actions/blob/master/src/DssProxyActions.t.sol
contract DssProxyIntegrationTest is Test {
    bytes32 internal constant WETH_A = "WETH-A";
    uint256 internal constant RAY = 1e27;

    Vat internal vat;
    MockWETH internal weth;
    GemJoin internal gemJoin;
    Dai internal dai;
    DaiJoin internal daiJoin;
    Jug internal jug;
    Spotter internal spotter;
    MockOracle internal oracle;
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
        spotter = new Spotter(address(vat));
        oracle = new MockOracle();

        // Initialize the WETH_A collateral
        vat.init(WETH_A);
        // Gives the adapter permission to credit collateral balances inside the Vat
        vat.rely(address(gemJoin));
        vat.rely(address(jug));
        vat.rely(address(spotter));
        dai.rely(address(daiJoin));
        jug.init(WETH_A);

        // A $3,000 WETH price and 150% collateralization support 2,000 Dai per WETH.
        oracle.setVal(bytes32(uint256(3_000 ether))); // Oracle price in wad.

        // Configure WETH_A collateral in the spotter
        spotter.file(WETH_A, "pip", address(oracle));
        spotter.file(WETH_A, "mat", 15e26); // Liquidation ratio in ray.
        spotter.poke(WETH_A);

        vat.file(WETH_A, "line", 10_000 ether * RAY); // Debt ceiling
        vat.file("Line", 10_000 ether * RAY); // Total Debt Ceiling
    }

    /////////////////////////////////////////////////////////////
    //      ethJoin_join - Deposit ETH as free collateral      //
    /////////////////////////////////////////////////////////////
    // Checks that a user can deposit 2 ETH as free collateral in the Vat,
    // while keeping the remaining 3 ETH in their wallet.
    // It does not lock collateral in a vault or borrow Dai.
    function test_UserJoinsEth() public {
        uint256 initialBalance = 5 ether;
        uint256 deposited = 2 ether;
        vm.deal(user, initialBalance);

        vm.prank(user);
        // The user deposits 2 ether and credits the Vat collateral to himself.
        // Inside ethJoin_join, the proxy:
        //  - Wraps the 2 ETH into 2 WETH, initally held by the proxy
        //  - GemJoin.join credits the user's free collateral balance
        //      and transfers the WETH from the proxy into the adapter
        proxy.ethJoin_join{value: deposited}(address(gemJoin), user);

        // The adapter holds the wrapped ETH and the recipient receives free Vat collateral.
        assertEq(user.balance, initialBalance - deposited);
        assertEq(weth.balanceOf(address(gemJoin)), deposited);
        assertEq(weth.totalSupply(), deposited);
        assertEq(address(weth).balance, deposited);
        assertEq(vat.gem(WETH_A, user), deposited);
        assertEq(vat.gem(WETH_A, address(proxy)), 0);

        // Joining leaves vault collateral and debt at zero, with no funds left in the proxy.
        assertEq(vat.urns(WETH_A, user).ink, 0);
        assertEq(vat.urns(WETH_A, user).art, 0);
        assertEq(weth.balanceOf(user), 0);
        assertEq(weth.balanceOf(address(proxy)), 0);
        assertEq(address(proxy).balance, 0);
    }

    ///////////////////////////////////////////////////////
    //      daiJoin_join - Deposit Dai into the Vat       //
    ///////////////////////////////////////////////////////
    // Verifies that a user can convert 40 wallet Dai into an internal Vat balance,
    // while keeping their vault debt unchanged.
    function test_UserJoinsDai() public {
        // The test distinguishes two forms of Dai:
        //   - ERC-20 Dai: wallet tokens, tracked by dai.balanceOf [wad]
        //   - Internal Dai: accounting balances inside the Vat, tracked by vat.dai [rad]
        uint256 collateral = 1 ether;
        uint256 initialDaiBalance = 100 ether;
        uint256 depositedDai = 40 ether;
        vm.deal(user, collateral);

        vm.startPrank(user);

        // Authorize the proxy to operate on the user's Vat account.
        vat.hope(address(proxy));

        // Lock 1 ETH and borrow 100 Dai.
        proxy.lockETHAndDraw{value: collateral}(
            WETH_A, address(jug), address(gemJoin), address(daiJoin), initialDaiBalance
        );

        // At this point the user holds 100 ERC-20 Dai and DaiJoin holds 100 internal Dai
        assertEq(dai.balanceOf(user), initialDaiBalance);
        assertEq(vat.dai(user), 0);
        assertEq(vat.dai(address(daiJoin)), initialDaiBalance * RAY);

        // The user joins 40 Dai:
        // The daiJoin_join performs three steps:
        //  1. Transfers 40 ERC-20 Dai from the user to the proxy.
        //  2. DaiJoin.join the adapter transfers 40 internal Dai from its own Vat balance and burns 40 proxy's ERC-20 Dai
        dai.approve(address(proxy), depositedDai);
        proxy.daiJoin_join(address(daiJoin), user, depositedDai);
        vm.stopPrank();

        // Balance or debt	         Before joining	  After joining
        // User’s wallet Dai	          100	           60
        // ERC-20 Dai total supply	      100	           60
        // User’s internal Dai	           0	           40
        // DaiJoin’s internal Dai	      100	           60
        // User’s vault debt	          100	           100
        // Locked collateral	          1 WETH	       1 WETH

        // Joining burns ERC-20 Dai and moves its internal backing to the user.
        assertEq(dai.balanceOf(user), initialDaiBalance - depositedDai); // User's wallet Dai 60
        assertEq(dai.totalSupply(), initialDaiBalance - depositedDai); // Dai's total supply 60
        assertEq(vat.dai(user), depositedDai * RAY); // User's internal Dai 40
        assertEq(vat.dai(address(daiJoin)), (initialDaiBalance - depositedDai) * RAY); // DaiJoin's internal Dai 60
        assertEq(dai.balanceOf(address(daiJoin)), 0);
        assertEq(dai.balanceOf(address(proxy)), 0);
        assertEq(vat.dai(address(proxy)), 0);
        assertEq(address(proxy).balance, 0);

        // Joining creates an internal balance; it does not repay the vault's debt.
        assertEq(vat.urns(WETH_A, user).art, initialDaiBalance); // User's vault normalized debt: 100
        assertEq(vat.ilks(WETH_A).Art, initialDaiBalance);
        assertEq(vat.debt(), initialDaiBalance * RAY);
        assertEq(vat.urns(WETH_A, user).ink, collateral); // Locked collateral 1 WETH
        assertEq(weth.balanceOf(address(gemJoin)), collateral);
        assertEq(vat.gem(WETH_A, user), 0);
        assertEq(vat.gem(WETH_A, address(proxy)), 0);
    }

    //////////////////////////////////////////////////
    //      lockETH - Depositing ETH collateral     //
    //////////////////////////////////////////////////
    // The user locks 2 ETH from a 5 ETH balance and keeps the remaining 3 ETH.
    // Similar to testLockETH in https://github.com/sky-ecosystem/dss-proxy-actions/blob/master/src/DssProxyActions.t.sol
    function test_UserLocksPartOfEthBalance() public {
        uint256 initialBalance = 5 ether;
        uint256 collateral = 2 ether;
        vm.deal(user, initialBalance);

        assertEq(user.balance, initialBalance);
        assertEq(vat.urns(WETH_A, user).ink, 0);

        vm.prank(user);
        // User deposits and locks 5 ether
        proxy.lockETH{value: collateral}(WETH_A, address(gemJoin));

        Vat.Urn memory urn = vat.urns(WETH_A, user);
        assertEq(urn.ink, collateral); // User's collateral locked in the vault
        assertEq(urn.art, 0); // Normalized debt 0
        assertEq(user.balance, initialBalance - collateral);
        assertEq(address(proxy).balance, 0);
        assertEq(address(weth).balance, collateral);
        assertEq(weth.balanceOf(address(gemJoin)), collateral);
        assertEq(weth.balanceOf(user), 0);
        assertEq(weth.balanceOf(address(proxy)), 0);
        assertEq(vat.gem(WETH_A, address(proxy)), 0); // Proxy's free collateral 0
        assertEq(vat.gem(WETH_A, user), 0); // User's free collateral 0
    }

    ///////////////////////////////////////////////////////////////////
    //      freeETH - Withdraws ETH previously locked in a Vault     //
    ///////////////////////////////////////////////////////////////////

    // Verifies that a user can withdraw 1 ETH from a vault holding 2 ETH.
    function test_UserFreesPartOfEthCollateral() public {
        // The user receives 2 ETH
        vm.deal(user, 2 ether);

        vm.startPrank(user);
        // The user locks 2 ETH as a collateral
        proxy.lockETH{value: 2 ether}(WETH_A, address(gemJoin));
        // The user authorizes the proxy
        vat.hope(address(proxy));

        // The user withdraws 1 ETH
        proxy.freeETH(WETH_A, address(gemJoin), 1 ether);
        vm.stopPrank();

        assertEq(user.balance, 1 ether);
        assertEq(vat.urns(WETH_A, user).ink, 1 ether);
        assertEq(weth.balanceOf(address(gemJoin)), 1 ether);
        assertEq(address(weth).balance, 1 ether);
        assertEq(vat.gem(WETH_A, user), 0); // The user has no free collateral
        assertEq(vat.gem(WETH_A, address(proxy)), 0);
        assertEq(weth.balanceOf(address(proxy)), 0);
        assertEq(weth.balanceOf(user), 0);
        assertEq(address(proxy).balance, 0);
    }

    /////////////////////////////////////////////////////
    //      exitETH - Withdraw unlocked collateral    //
    /////////////////////////////////////////////////////

    // Checks that a user can withdraw some collateral that is already unlocked,
    // receiving native ETH while leaving the remaining collateral in the system.
    function test_UserExitsPartOfUnlockedEthCollateral() public {
        uint256 collateral = 3 ether;
        uint256 unlocked = 2 ether;
        uint256 withdrawn = 1 ether;
        vm.deal(user, collateral);

        vm.startPrank(user);
        // Wraps 3 ETH into WETH, deposits it through GemJoin and locks it in the user's vault
        proxy.lockETH{value: collateral}(WETH_A, address(gemJoin));
        vat.hope(address(proxy));

        // Unlock collateral into the user's free Vat balance without withdrawing WETH from GemJoin.
        // -int256(unlocked) (dink): reduces locked collateral by 2.
        // 0 (dart): leaves normalized debt unchanged.
        vat.frob(WETH_A, user, user, user, -int256(unlocked), 0);
        // Unlocking only changes Vat accounting.
        // GemJoin still holds all 3 WETH, and the user still has zero native ETH.
        assertEq(vat.urns(WETH_A, user).ink, collateral - unlocked);
        assertEq(vat.gem(WETH_A, user), unlocked);
        assertEq(weth.balanceOf(address(gemJoin)), collateral);
        assertEq(user.balance, 0);

        // Sends the ETH to the user.
        // Unlike freeETH, exitETH does not unlock collateral itself; it consumes an existing free balance.
        proxy.exitETH(WETH_A, address(gemJoin), withdrawn);
        vm.stopPrank();

        // Only the free collateral is debited; the vault's locked collateralstay unchanged.
        Vat.Urn memory urn = vat.urns(WETH_A, user);
        assertEq(urn.ink, collateral - unlocked);
        assertEq(vat.gem(WETH_A, user), unlocked - withdrawn);
        assertEq(vat.gem(WETH_A, address(proxy)), 0);

        // GemJoin releases WETH, which the proxy unwraps and sends to the user as native ETH.
        assertEq(user.balance, withdrawn);
        assertEq(weth.balanceOf(address(gemJoin)), collateral - withdrawn);
        assertEq(weth.totalSupply(), collateral - withdrawn);
        assertEq(address(weth).balance, collateral - withdrawn);
        assertEq(weth.balanceOf(user), 0);
        assertEq(weth.balanceOf(address(proxy)), 0);
        assertEq(address(proxy).balance, 0);
    }

    /////////////////////////////////////////////////////
    //      lockGem - Depositing ERC-20 collateral     //
    /////////////////////////////////////////////////////
    // The user locks 2 WETH from a 5 WETH balance and keeps the remaining 3 WETH.
    // Similar to testLockGem in https://github.com/sky-ecosystem/dss-proxy-actions/blob/master/src/DssProxyActions.t.sol
    function test_UserLocksPartOfWethBalance() public {
        uint256 initialBalance = 5 ether;
        uint256 collateral = 2 ether;
        vm.deal(user, initialBalance);

        vm.startPrank(user);
        // User wraps 5 ETH into WETH
        weth.deposit{value: initialBalance}();
        weth.approve(address(proxy), collateral);

        assertEq(weth.balanceOf(user), initialBalance);
        assertEq(vat.urns(WETH_A, user).ink, 0);

        // User deposits 2 ether and lcoks them in the vault
        proxy.lockGem(WETH_A, address(gemJoin), collateral, true);
        vm.stopPrank();

        Vat.Urn memory urn = vat.urns(WETH_A, user);
        assertEq(urn.ink, collateral); // User's collateral locked in the vault
        assertEq(urn.art, 0); // User's normalzied debt in the urn
        assertEq(weth.balanceOf(user), initialBalance - collateral);
        assertEq(weth.balanceOf(address(gemJoin)), collateral);
        assertEq(weth.balanceOf(address(proxy)), 0);
        assertEq(vat.gem(WETH_A, address(proxy)), 0); // Proxy's free collateral
        assertEq(vat.gem(WETH_A, user), 0); // User's free collateral
    }

    /////////////////////////////////////////////////////
    //      freeGem - Withdraw ERC-20 collateral      //
    /////////////////////////////////////////////////////
    // The user locks 2 WETH and withdraws 1 WETH without borrowing any Dai.
    function test_UserFreesPartOfWethCollateral() public {
        uint256 collateral = 2 ether;
        uint256 withdrawn = 1 ether;
        uint256 remaining = collateral - withdrawn;
        vm.deal(user, collateral);

        vm.startPrank(user);
        // User wraps ETH into WETH
        weth.deposit{value: collateral}();
        weth.approve(address(proxy), collateral);
        // The proxy pulls the WETH from the user's wallet.
        // The tokens end up in GemJoin adapter, while the Vat records 2 WETH as locked collateral
        // in the user's vault (urn.ink)
        proxy.lockGem(WETH_A, address(gemJoin), collateral, true);

        assertEq(vat.urns(WETH_A, user).ink, collateral);
        assertEq(weth.balanceOf(user), 0);

        // Authorize the withdrawal
        vat.hope(address(proxy));
        // Withdraw 1 WETH
        // It reduces the user's locked collateral by 1 WETH and
        // transfer 1 WETH from the adapter to the user.
        proxy.freeGem(WETH_A, address(gemJoin), withdrawn);
        vm.stopPrank();

        Vat.Urn memory urn = vat.urns(WETH_A, user);
        assertEq(urn.ink, remaining); // Locked collateral is 2 - 1 WETH
        assertEq(urn.art, 0);
        assertEq(weth.balanceOf(user), withdrawn); // The user receives 1 WETH
        assertEq(weth.balanceOf(address(gemJoin)), remaining);
        assertEq(weth.balanceOf(address(proxy)), 0);
        assertEq(vat.gem(WETH_A, user), 0);
        assertEq(vat.gem(WETH_A, address(proxy)), 0);

        // freeGem returns WETH tokens without unwrapping them into ETH.
        assertEq(user.balance, 0);
        assertEq(address(proxy).balance, 0);
        assertEq(address(weth).balance, collateral); // WETH balance is unchanged
        assertEq(weth.totalSupply(), collateral); // Weth total supply is unchanged
    }

    /////////////////////////////////////////////////////////////
    //      exitGem - Withdraw unlocked ERC-20 collateral      //
    /////////////////////////////////////////////////////////////
    // Withdraws part of the user's free Vat collateral as WETH without unwrapping it.
    function test_UserExitsPartOfUnlockedWethCollateral() public {
        uint256 collateral = 3 ether;
        uint256 unlocked = 2 ether;
        uint256 withdrawn = 1 ether;
        vm.deal(user, collateral);

        vm.startPrank(user);
        // User wraps 3 ETH into WETH
        weth.deposit{value: collateral}();
        weth.approve(address(proxy), collateral);

        // The user deposits and locks 3 WETH. GemJoin holds the tokens
        // while the Vat records 3 WETH locked in the user's vault.
        proxy.lockGem(WETH_A, address(gemJoin), collateral, true);
        vat.hope(address(proxy));

        // Unlock collateral into the user's free Vat balance, leaving the tokens in GemJoin.
        vat.frob(WETH_A, user, user, user, -int256(unlocked), 0);
        assertEq(vat.urns(WETH_A, user).ink, collateral - unlocked);
        assertEq(vat.gem(WETH_A, user), unlocked);
        assertEq(weth.balanceOf(address(gemJoin)), collateral);
        assertEq(weth.balanceOf(user), 0);

        // Withdraw 1 WETH
        proxy.exitGem(WETH_A, address(gemJoin), withdrawn);
        vm.stopPrank();

        // Only free collateral is spent; locked collateral and debt stay unchanged.
        Vat.Urn memory urn = vat.urns(WETH_A, user);
        assertEq(urn.ink, collateral - unlocked);
        assertEq(vat.gem(WETH_A, user), unlocked - withdrawn);
        assertEq(vat.gem(WETH_A, address(proxy)), 0);

        // The user receives ERC-20 WETH; its supply and ETH backing stay unchanged.
        assertEq(weth.balanceOf(user), withdrawn);
        assertEq(weth.balanceOf(address(gemJoin)), collateral - withdrawn);
        assertEq(weth.balanceOf(address(proxy)), 0);
        assertEq(weth.totalSupply(), collateral);
        assertEq(address(weth).balance, collateral);
        assertEq(user.balance, 0);
        assertEq(address(proxy).balance, 0);
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
        proxy.lockGem(WETH_A, address(gemJoin), collateral, true);

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
    //      lockETHAndDraw - Deposit ETH and borrow DAI            //
    /////////////////////////////////////////////////////////////////
    // The user locks 1 ETH from a 5 ETH balance and receives 100 Dai.
    function test_UserLocksEthAndDrawsDai() public {
        uint256 initialBalance = 5 ether;
        uint256 collateral = 1 ether;
        uint256 borrowed = 100 ether;
        vm.deal(user, initialBalance);

        vm.startPrank(user);
        // Authorize the proxy to lock collateral and draw Dai from the user's Vat account.
        vat.hope(address(proxy));
        // The user deposits and locks 1 ETH and borrows 100 Dai.
        proxy.lockETHAndDraw{value: collateral}(WETH_A, address(jug), address(gemJoin), address(daiJoin), borrowed);
        vm.stopPrank();

        // The deposited ETH is wrapped, held by GemJoin, and locked in the user's vault.
        assertEq(user.balance, initialBalance - collateral);
        assertEq(address(proxy).balance, 0);
        assertEq(address(weth).balance, collateral);
        assertEq(weth.totalSupply(), collateral);
        assertEq(weth.balanceOf(address(gemJoin)), collateral);
        assertEq(weth.balanceOf(user), 0);
        assertEq(weth.balanceOf(address(proxy)), 0);
        assertEq(vat.gem(WETH_A, user), 0);
        assertEq(vat.gem(WETH_A, address(proxy)), 0);

        Vat.Urn memory urn = vat.urns(WETH_A, user);
        assertEq(urn.ink, collateral);
        assertEq(vat.urns(WETH_A, address(proxy)).ink, 0);
        assertEq(vat.urns(WETH_A, address(proxy)).art, 0);

        // With rate = RAY, normalized debt equals the requested Dai amount.
        assertEq(vat.ilks(WETH_A).rate, RAY);
        assertEq(urn.art, borrowed);
        assertEq(vat.ilks(WETH_A).Art, borrowed);
        assertEq(vat.debt(), borrowed * RAY);
        assertEq(dai.balanceOf(user), borrowed);
        assertEq(dai.totalSupply(), borrowed);
        assertEq(dai.balanceOf(address(proxy)), 0);

        // DaiJoin receives the internal Dai and mints ERC-20 Dai to the user.
        assertEq(vat.dai(user), 0);
        assertEq(vat.dai(address(proxy)), 0);
        assertEq(vat.dai(address(daiJoin)), borrowed * RAY);
        assertEq(vat.can(address(proxy), address(daiJoin)), 1);
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
        assertEq(vat.ilks(WETH_A).Art, borrowed); // Total normalized debt for WETH_A collateral
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
        assertEq(vat.ilks(WETH_A).Art, expectedArt);
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
        assertEq(vat.ilks(WETH_A).Art, expectedArt); // Total normalized debt for the collateral WETH-A
        assertEq(vat.dai(feeRecipient), accruedFees);
        assertEq(vat.debt(), expectedArt * expectedRate); // Total Dai issued = 372.108843537 × 1.1025 ≈ 410.25 Dai
        assertEq(dai.balanceOf(user), initialBorrowed + additionalBorrowed); // User receives 400 Dai
        assertEq(dai.totalSupply(), initialBorrowed + additionalBorrowed); // DAI's Total supply is 400
        assertEq(vat.dai(user), expectedArt * expectedRate - accruedFees - (initialBorrowed + additionalBorrowed) * RAY);
        assertEq(vat.dai(address(daiJoin)), (initialBorrowed + additionalBorrowed) * RAY);
        assertEq(vat.dai(address(proxy)), 0);

        // The actual debt consists of 100 Dai originally borrowed + 10.25 Dai accrued fees + 300 Dai newly borrowed, plus a tiny rounding surplus.
    }

    ///////////////////////////////
    //      wipe - Repay DAI     //
    ///////////////////////////////
    // The user borrows 100 DAI, then repays 40 DAI while keeping all collateral locked.
    function test_UserPartiallyRepaysDaiWithWipe() public {
        uint256 collateral = 1 ether;
        uint256 borrowed = 100 ether;
        uint256 repaid = 40 ether;
        uint256 remaining = borrowed - repaid;
        vm.deal(user, collateral);

        vm.startPrank(user);
        // User locks 1 eth of collateral
        proxy.lockETH{value: collateral}(WETH_A, address(gemJoin));
        // Authorize the proxy to borrow and later spend the user's internal DAI.
        vat.hope(address(proxy));

        // User borrows 100 DAI
        proxy.draw(WETH_A, address(jug), address(daiJoin), borrowed);

        // Allow wipe to pull 40 ERC-20 DAI from the user's wallet.
        dai.approve(address(proxy), repaid);
        proxy.wipe(WETH_A, address(daiJoin), repaid);
        vm.stopPrank();

        // At rate = RAY, repaying 40 DAI reduces normalized debt from 100 to 60.
        Vat.Urn memory urn = vat.urns(WETH_A, user);
        assertEq(urn.art, remaining); // Urn's Normalized debt: borrowed - repaid = 100 ether - 40 ether = 60 ether
        assertEq(vat.ilks(WETH_A).Art, remaining); // Vat's Normalized debt: borrowed - repaid = 100 ether - 40 ether = 60 ether
        assertEq(urn.art * vat.ilks(WETH_A).rate, remaining * RAY); // Actual debt (Dai) = normalized debt x rate =  60 ether x RAY
        assertEq(vat.debt(), remaining * RAY); // Actual debt (Dai) = normalized debt x rate =  60 ether x RAY

        // DaiJoin burns the repayment; its internal DAI funds the debt reduction.
        assertEq(dai.balanceOf(user), remaining); // DAI balance = borrowed - repaid = 100 ether - 40 ether = 60 ether
        assertEq(dai.totalSupply(), remaining); // borrowed - repaid = 100 ether - 40 ether = 60 ether
        assertEq(dai.balanceOf(address(proxy)), 0);
        assertEq(dai.balanceOf(address(daiJoin)), 0);
        assertEq(vat.dai(address(daiJoin)), remaining * RAY);
        assertEq(vat.dai(user), 0);
        assertEq(vat.dai(address(proxy)), 0);

        // Repayment leaves the user's collateral locked.
        assertEq(urn.ink, collateral);
        assertEq(weth.balanceOf(address(gemJoin)), collateral);
    }

    //////////////////////////////////////
    //      wipeAll - Repay all DAI     //
    //////////////////////////////////////
    // Verifies that wipeAll uses the user's existing internal DAI and
    // pulls only the additional ERC-20 DAI needed to clear the debt,
    // while leaving collateral locked.
    function test_UserFullyRepaysDaiWithWipeAll() public {
        // There are two Dai balances involved:
        // - ERC-20 Dai: tokens in the user's wallet [wad]
        // - internal Dai: the user's balance in the Vat [rad]

        uint256 collateral = 1 ether;
        uint256 borrowed = 100 ether;
        uint256 internalDai = 20 ether;
        uint256 remaining = borrowed - internalDai;
        vm.deal(user, collateral);

        vm.startPrank(user);
        // User deposits and lock 1 ether in Vat
        proxy.lockETH{value: collateral}(WETH_A, address(gemJoin));

        // User gives authorization to proxy to borrow and spend user's internal Dai
        vat.hope(address(proxy));
        // The user borrows 100 DAI: the user holds 100 ERC-20 DAI and owes 100 DAI
        // Since the rate is RAY, the normalized debt (art) = DAI / rate = 100 ether
        proxy.draw(WETH_A, address(jug), address(daiJoin), borrowed);

        // Convert 20 ERC-20 DAI into internal DAI.
        // join burns 20 wallet DAI and credits the user with 20 internal Dai in the Vat
        // This does not reapy debt yet: the vault still owes 100 DAI.
        dai.approve(address(daiJoin), internalDai);
        daiJoin.join(user, internalDai);
        assertEq(vat.dai(user), internalDai * RAY);
        assertEq(vat.urns(WETH_A, user).art, borrowed);
        assertEq(dai.balanceOf(user), borrowed - internalDai);

        // Repay the whole debt
        // Required ERC-20 DAI = art x rate - internal DAI = 100 - 20 = 80 DAI
        // The proxy pulls those 80 tokens and joins them, bringing the user's internal balance to 100 DAI.
        // Then it consumes all 100 internal DAI
        dai.approve(address(proxy), remaining);
        proxy.wipeAll(WETH_A, address(daiJoin));
        vm.stopPrank();

        //  Point in test      Wallet DAI     User's internal DAI     Vault debt
        //  After borrowing       100                  0                  100
        //  After joining 20       80                 20                  100
        //  After wipeAll           0                  0                    0

        // where:
        // - user's internal DAI: vat.dai(user) [rad]
        // - Vault debt: vat.urns(WETH_A, user).art * vat.ilks(WETH_A).rate

        Vat.Urn memory urn = vat.urns(WETH_A, user);
        assertEq(urn.art, 0); // Vault's normalized debt 0
        assertEq(vat.ilks(WETH_A).Art, 0); // Collateral's debt 0
        assertEq(vat.debt(), 0); // Total debt 0

        // All borrowed DAI has been burned and all internal DAI consumed.
        assertEq(dai.balanceOf(user), 0);
        assertEq(dai.totalSupply(), 0);
        assertEq(dai.balanceOf(address(proxy)), 0);
        assertEq(dai.balanceOf(address(daiJoin)), 0);
        assertEq(vat.dai(user), 0);
        assertEq(vat.dai(address(proxy)), 0);
        assertEq(vat.dai(address(daiJoin)), 0);

        // Full repayment leaves the collateral locked in the user's vault.
        assertEq(urn.ink, collateral);
        assertEq(weth.balanceOf(address(gemJoin)), collateral);
    }

    ////////////////////////////////////////////////////////////////////////
    //      wipeAndFreeETH - Repay DAI and withdraw ETH collateral        //
    ////////////////////////////////////////////////////////////////////////
    // - collateral: locked ETH collateral
    // - borrowed: borrowed Dai
    function _withLockedETHAndBorrowedDai(address user, uint256 collateral, uint256 borrowed) internal {
        vm.deal(user, collateral);
        vm.startPrank(user);
        vat.hope(address(proxy));
        proxy.lockETHAndDraw{value: collateral}(WETH_A, address(jug), address(gemJoin), address(daiJoin), borrowed);
        dai.approve(address(proxy), type(uint256).max);
        vm.stopPrank();
    }

    // Veryfies that a user can partially repay the debt and withdraw his collateral.
    function test_UserPartiallyRepaysDaiAndFreesEth() public {
        uint256 collateral = 2 ether;
        uint256 borrowed = 3_000 ether;
        uint256 repaid = 1_500 ether;
        uint256 withdrawn = 1 ether;
        uint256 remainingDebt = borrowed - repaid;
        uint256 remainingCollateral = collateral - withdrawn;
        // The user locks 2 ETH of collateral and borrows 3000 DAI
        _withLockedETHAndBorrowedDai(user, collateral, borrowed);

        vm.startPrank(user);
        // The user repays 1,500 Dai and withdraws 1 ETH
        proxy.wipeAndFreeETH(WETH_A, address(gemJoin), address(daiJoin), withdrawn, repaid);
        vm.stopPrank();

        // At rate = RAY, burning 1,500 Dai reduces normalized and actual debt equally.
        Vat.Urn memory urn = vat.urns(WETH_A, user);
        assertEq(urn.ink, remainingCollateral); // Locked collateral: 2 ether - 1 ether = 1 ether
        assertEq(urn.art, remainingDebt); // User's normalized debt: 3_000 ether - 1_500 ether = 1_500 ether
        assertEq(vat.ilks(WETH_A).Art, remainingDebt); // Collateral's type normalized debt: 3_000 ether - 1_500 ether = 1_500 ether
        assertEq(vat.debt(), remainingDebt * RAY);
        assertEq(dai.balanceOf(user), remainingDebt); // User's dai = 3_000 ether - 1_500 ether
        assertEq(dai.totalSupply(), remainingDebt);
        assertEq(vat.dai(address(daiJoin)), remainingDebt * RAY);
        assertEq(vat.dai(user), 0);
        assertEq(vat.dai(address(proxy)), 0);
        assertEq(dai.balanceOf(address(proxy)), 0);
        assertEq(dai.balanceOf(address(daiJoin)), 0);

        // Withdrawn WETH is unwrapped and returned as native ETH.
        assertEq(user.balance, withdrawn);
        assertEq(weth.balanceOf(address(gemJoin)), remainingCollateral);
        assertEq(weth.totalSupply(), remainingCollateral);
        assertEq(address(weth).balance, remainingCollateral);
        assertEq(vat.gem(WETH_A, user), 0);
        assertEq(vat.gem(WETH_A, address(proxy)), 0);
        assertEq(weth.balanceOf(user), 0);
        assertEq(weth.balanceOf(address(proxy)), 0);
        assertEq(address(proxy).balance, 0);

        // Balance	                                    Before repayment	After repayment
        // Locked collateral (urn.ink)	                    2 ETH	            1 ETH
        // Vault debt (urn.art)	                            3,000 Dai	        1,500 Dai
        // User’s wallet Dai (dai.balanceOf(user))	        3,000 Dai	        1,500 Dai
        // User’s wallet ETH (user.balance)	                0 ETH	            1 ETH
    }

    /////////////////////////////////////////////////////////////////////////////////////////////
    //      wipeAllAndFreeETH - Repay all DAI and withdraw the requested ETH collateral        //
    /////////////////////////////////////////////////////////////////////////////////////////////

    // Checks that wipeAllAndFreeETH repays all debt while withdrawing only the requested collateral.
    function test_WipeAllAndFreeEth_RepaysAllDebtAndWithdrawsPartialCollateral() public {
        // User locks 2 ETH and borrows 100 Dai
        _withLockedETHAndBorrowedDai(user, 2 ether, 100 ether);

        assertEq(vat.urns(WETH_A, user).ink, 2 ether); // User's locked collateral
        assertEq(vat.urns(WETH_A, user).art, 100 ether); // User's normalzied debt
        assertEq(dai.balanceOf(user), 100 ether);
        assertEq(vat.dai(user), 0); // User's internal dai credit

        vm.startPrank(user);
        dai.approve(address(proxy), 100 ether);
        // The user repays all debt and withdraws 1 ETH
        proxy.wipeAllAndFreeETH(WETH_A, address(gemJoin), address(daiJoin), 1 ether);
        vm.stopPrank();

        // All debt is repaid, while one ETH remains locked in the vault.
        assertEq(vat.urns(WETH_A, user).art, 0);
        assertEq(vat.urns(WETH_A, user).ink, 1 ether);
        assertEq(vat.ilks(WETH_A).Art, 0);
        assertEq(vat.debt(), 0);
        assertEq(dai.balanceOf(user), 0);
        assertEq(dai.totalSupply(), 0);
        assertEq(vat.dai(user), 0);
        assertEq(vat.dai(address(daiJoin)), 0);

        // The withdrawn collateral reaches the user as native ETH.
        assertEq(user.balance, 1 ether);
        assertEq(weth.balanceOf(address(gemJoin)), 1 ether);
        assertEq(weth.totalSupply(), 1 ether);
        assertEq(address(weth).balance, 1 ether);
        assertEq(weth.balanceOf(user), 0);
        assertEq(vat.gem(WETH_A, address(proxy)), 0);
        assertEq(dai.balanceOf(address(proxy)), 0);
        assertEq(vat.dai(address(proxy)), 0);
        assertEq(weth.balanceOf(address(proxy)), 0);
        assertEq(address(proxy).balance, 0);
    }

    ///////////////////////////////////////////////////////////////////////////////
    //      wipeAndFreeGem - Repay DAI and withdraw the ERC-20 collateral        //
    ///////////////////////////////////////////////////////////////////////////////
    // Checks that a user can repay part of their DAI debt and withdraw collateral in the same call.
    function test_UserPartiallyRepaysDaiAndFreesGem() public {
        // The user locks 2 WETH and borrows 3,000 DAI
        _withLockedETHAndBorrowedDai(user, 2 ether, 3_000 ether);

        // The user repays 1_500 Dai and withdraws 1 WETH
        vm.prank(user);
        proxy.wipeAndFreeGem(WETH_A, address(gemJoin), address(daiJoin), 1 ether, 1_500 ether);

        assertEq(vat.urns(WETH_A, user).ink, 1 ether);
        assertEq(vat.urns(WETH_A, user).art, 1_500 ether);
        assertEq(vat.ilks(WETH_A).Art, 1_500 ether);
        assertEq(vat.debt(), 1_500 ether * RAY);
        assertEq(dai.balanceOf(user), 1_500 ether);
        assertEq(dai.totalSupply(), 1_500 ether);
        assertEq(vat.dai(user), 0);
        assertEq(vat.dai(address(daiJoin)), 1_500 ether * RAY);

        // WETH is returned as an ERC-20 token, preserving its supply and backing.
        assertEq(weth.balanceOf(user), 1 ether);
        assertEq(weth.balanceOf(address(gemJoin)), 1 ether);
        assertEq(weth.totalSupply(), 2 ether);
        assertEq(address(weth).balance, 2 ether);
        assertEq(user.balance, 0);
        assertEq(vat.gem(WETH_A, address(proxy)), 0);
        assertEq(vat.gem(WETH_A, user), 0);
        assertEq(weth.balanceOf(address(proxy)), 0);
        assertEq(dai.balanceOf(address(proxy)), 0);
        assertEq(vat.dai(address(proxy)), 0);

        // Balance	                Before	        After
        // Locked collateral	    2 WETH	        1 WETH
        // Vault debt	            3,000 DAI	    1,500 DAI
        // User’s wallet DAI	    3,000 DAI	    1,500 DAI
        // User’s wallet WETH	    0 WETH	        1 WETH
    }

    /////////////////////////////////////////////////////////////////////////////////////////////////
    //      wipeAllAndFreeGem - Repays all DAI and withdraw the requested ERC-20 collateral        //
    /////////////////////////////////////////////////////////////////////////////////////////////////
    function _withLockedWETHAndBorrowedDai(address user, uint256 collateral, uint256 borrowed) internal {
        vm.deal(user, collateral);

        vm.startPrank(user);
        weth.deposit{value: collateral}();
        weth.approve(address(proxy), collateral);
        vat.hope(address(proxy));
        proxy.lockGemAndDraw(WETH_A, address(jug), address(gemJoin), address(daiJoin), collateral, borrowed, true);
        dai.approve(address(proxy), type(uint256).max);
        vm.stopPrank();
    }

    // The user repays all 3,000 DAI and withdraws 1 of the 2 WETH locked in their vault.
    function test_WipeAllAndFreeGem_RepaysAllDebtAndWithdrawsPartialCollateral() public {
        uint256 collateral = 2 ether;
        uint256 borrowed = 3_000 ether;
        uint256 withdrawn = 1 ether;
        uint256 remainingCollateral = collateral - withdrawn;

        // The user locks 2 WETH and borrows 3_000 Dai
        _withLockedWETHAndBorrowedDai(user, collateral, borrowed);

        assertEq(vat.urns(WETH_A, user).ink, collateral);
        assertEq(vat.urns(WETH_A, user).art, borrowed);
        assertEq(dai.balanceOf(user), borrowed);
        assertEq(weth.balanceOf(user), 0);
        assertEq(vat.dai(user), 0);

        vm.startPrank(user);
        // The user repays the whole debt and withdraws 1 WETH
        proxy.wipeAllAndFreeGem(WETH_A, address(gemJoin), address(daiJoin), withdrawn);
        vm.stopPrank();

        // All debt and borrowed DAI are cleared; only the requested collateral is unlocked.
        Vat.Urn memory urn = vat.urns(WETH_A, user);
        assertEq(urn.art, 0);
        assertEq(urn.ink, remainingCollateral);
        assertEq(vat.ilks(WETH_A).Art, 0);
        assertEq(vat.debt(), 0);
        assertEq(dai.balanceOf(user), 0);
        assertEq(dai.totalSupply(), 0);
        assertEq(vat.dai(user), 0);
        assertEq(vat.dai(address(daiJoin)), 0);
        assertEq(dai.balanceOf(address(daiJoin)), 0);

        // The user receives ERC-20 WETH, preserving its supply and ETH backing.
        assertEq(weth.balanceOf(user), withdrawn);
        assertEq(weth.balanceOf(address(gemJoin)), remainingCollateral);
        assertEq(weth.totalSupply(), collateral);
        assertEq(address(weth).balance, collateral);
        assertEq(user.balance, 0);
        assertEq(vat.gem(WETH_A, user), 0);
        assertEq(vat.gem(WETH_A, address(proxy)), 0);
        assertEq(weth.balanceOf(address(proxy)), 0);
        assertEq(dai.balanceOf(address(proxy)), 0);
        assertEq(vat.dai(address(proxy)), 0);
        assertEq(address(proxy).balance, 0);
    }
}
