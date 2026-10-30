// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {Vat} from "../../src/Vat.sol";
import {Spotter} from "../../src/Spot.sol";
import {Dog} from "../../src/Dog.sol";
import {Clipper} from "../../src/Clip.sol";
import {LinearDecrease} from "../../src/Abaci.sol";
import {Vow} from "../../src/Vow.sol";
import {Dai} from "../../src/Dai.sol";
import {GemJoin} from "../../src/join/GemJoin.sol";
import {DaiJoin} from "../../src/join/DaiJoin.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {MockOracle} from "../mocks/MockOracle.sol";

/// @notice Run with `forge test --match-contract LiquidationIntegrationTest -vv`.
///         Use -vvvv instead to see the calls between the protocol contracts.
contract LiquidationIntegrationTest is Test {
    bytes32 internal constant WETH_A = "WETH-A";
    uint256 internal constant RAY = 1e27;
    uint256 internal constant ALICE_DEBT = 1_000 ether;
    uint256 internal constant BUYER_DEBT = 2_000 ether;
    uint256 internal constant AUCTION_TARGET = 1_100 ether * RAY;

    Vat internal vat;
    Spotter internal spotter;
    Dog internal dog;
    Clipper internal clip;
    LinearDecrease internal calc;
    Vow internal vow;
    Dai internal dai;
    GemJoin internal gemJoin;
    DaiJoin internal daiJoin;
    MockWETH internal weth;
    MockOracle internal oracle;

    address internal alice;
    address internal keeper;
    address internal buyer;

    function setUp() public {
        alice = makeAddr("alice");
        keeper = makeAddr("keeper");
        buyer = makeAddr("buyer");

        vat = new Vat();
        spotter = new Spotter(address(vat));
        dog = new Dog(address(vat));
        clip = new Clipper(address(vat), address(spotter), address(dog), WETH_A);
        calc = new LinearDecrease();
        // This scenario never starts surplus/debt auctions or shuts down Vow,
        // so their contracts are deliberately left unconfigured.
        vow = new Vow(address(vat), address(0), address(0));
        dai = new Dai();
        weth = new MockWETH();
        gemJoin = new GemJoin(address(vat), WETH_A, address(weth));
        daiJoin = new DaiJoin(address(vat), address(dai));
        oracle = new MockOracle();

        vat.init(WETH_A);
        vat.rely(address(gemJoin)); // Credit/debit collateral through the adapter.
        vat.rely(address(spotter)); // Update the safety-adjusted price.
        vat.rely(address(dog)); // Confiscate collateral and debt with grab().
        vow.rely(address(dog)); // Queue the confiscated debt with fess().
        clip.rely(address(dog)); // Start auctions with kick().
        dog.rely(address(clip)); // Release liquidation capacity with digs().
        dai.rely(address(daiJoin));

        vat.file("Line", 10_000 ether * RAY);
        vat.file(WETH_A, "line", 10_000 ether * RAY);
        vat.file(WETH_A, "dust", 100 ether * RAY);
        spotter.file(WETH_A, "pip", address(oracle));
        spotter.file(WETH_A, "mat", 15e26); // 150% collateralization.
        oracle.setVal(bytes32(uint256(3_000 ether)));
        spotter.poke(WETH_A);

        dog.file("vow", address(vow));
        dog.file("Hole", 10_000 ether * RAY);
        dog.file(WETH_A, "clip", address(clip));
        dog.file(WETH_A, "chop", 11e17); // Debt plus a 10% liquidation penalty.
        dog.file(WETH_A, "hole", 10_000 ether * RAY);

        clip.file("vow", address(vow));
        clip.file("calc", address(calc));
        clip.file("buf", RAY); // Start at the oracle price for this example.
        clip.file("tail", 1 hours);
        clip.file("cusp", 5e26); // Reset below 50% of the starting price.
        calc.file("tau", 2 hours);
        clip.upchost(); // Cache dust * chop = 110 Dai.
        vow.file("wait", 1 hours);
        // Keeper incentives (tip/chip) stay zero to isolate the debt and penalty.
        // The rate stays at 1 RAY: no stability fees accrue in this example.
    }

    function test_LiquidateUnsafeVault_BuyCollateralAndSettleDebt() public {
        // Internal Dai/debt uses rad (Dai amount * RAY); WETH uses wei.

        // 1. Alice locks 1 WETH worth $3,000 and receives 1,000 Dai.
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        weth.deposit{value: 1 ether}(); // Wrapping 1 ETH into WETH
        weth.approve(address(gemJoin), 1 ether);
        gemJoin.join(alice, 1 ether); // Deposit 1 WETH into gemJoin
        vat.frob(WETH_A, alice, alice, alice, int256(1 ether), int256(ALICE_DEBT)); // Lock 1 Weth and borrow 1,000 DAI. (ERC-20 DAI not transferred yet) 
        vat.hope(address(daiJoin)); // Authorize DaiJoin
        daiJoin.exit(alice, ALICE_DEBT); // 1,000 Dai are minted to Alice's wallet
        vm.stopPrank();

        assertEq(vat.urns(WETH_A, alice).ink, 1 ether); // Locked collateral 1 ETH
        assertEq(vat.urns(WETH_A, alice).art, ALICE_DEBT); // Normalized debt = 1,000 Dai
        assertEq(dai.balanceOf(alice), ALICE_DEBT);

        // The buyer funds the purchase by borrowing 2,000 internal Dai.
        // Their separate vault has 3 WETH and stays safe after the price drop.
        vm.deal(buyer, 3 ether);
        vm.startPrank(buyer);
        weth.deposit{value: 3 ether}();
        weth.approve(address(gemJoin), 3 ether);
        gemJoin.join(buyer, 3 ether);
        vat.frob(WETH_A, buyer, buyer, buyer, int256(3 ether), int256(BUYER_DEBT));
        vm.stopPrank();

        assertEq(vat.dai(buyer), BUYER_DEBT * RAY);

        // 2. WETH falls to $1,200. At 150% collateralization, Alice's
        //    collateral now supports only 800 Dai, below her 1,000 Dai debt.
        oracle.setVal(bytes32(uint256(1_200 ether)));
        vm.prank(keeper);
        spotter.poke(WETH_A);

        assertEq(vat.ilks(WETH_A).spot, 800 * RAY);

        // 3. Liquidation seizes Alice's collateral and debt, starting an
        //    auction for 1,000 Dai of debt plus a 100 Dai penalty.
        uint256 liquidationTime = block.timestamp;
        vm.prank(keeper);
        uint256 id = dog.bark(WETH_A, alice, keeper);

        assertEq(vat.urns(WETH_A, alice).ink, 0);
        assertEq(vat.urns(WETH_A, alice).art, 0);
        assertEq(vat.sin(address(vow)), ALICE_DEBT * RAY);

        (, uint256 price, uint256 lot, uint256 tab) = clip.getStatus(id);
        // where:
        // - price: Current auction price per WETH
        // - lot: Collateral remaining for sale
        // - tab: the internal Dai the auction still needs to collect to cover the liquidated debt plus the liquidation penalty.
        assertEq(lot, 1 ether);
        assertEq(tab, AUCTION_TARGET);

        // 4. The buyer authorizes Clipper and buys at the starting $1,200 price.
        //    Payment is capped at 1,100 Dai; leftover collateral goes to Alice.
        vm.startPrank(buyer);
        vat.hope(address(clip));
        clip.take(id, 1 ether, price, buyer, "");
        vm.stopPrank();

        uint256 bought = AUCTION_TARGET / price; // About 0.916667 WETH, rounded down.
        uint256 returned = 1 ether - bought; // About 0.083333 WETH.
        assertEq(vat.gem(WETH_A, buyer), bought);
        assertEq(vat.gem(WETH_A, alice), returned);
        assertEq(vat.dai(buyer), 900 ether * RAY);
        assertEq(vat.dai(address(vow)), AUCTION_TARGET);
        assertEq(clip.count(), 0);
        assertEq(vat.sin(address(vow)), ALICE_DEBT * RAY);

        // 5. Both withdraw their internal collateral as wallet WETH.
        vm.prank(buyer);
        gemJoin.exit(buyer, bought);
        vm.prank(alice);
        gemJoin.exit(alice, returned);

        assertEq(weth.balanceOf(buyer), bought);
        assertEq(weth.balanceOf(alice), returned);

        // 6. After the waiting period, release the queued debt and settle
        //    the 1,000 Dai principal using the auction proceeds.
        // This is the final accounting step of Alice’s liquidation: use 1,000 Dai of the auction’s 1,100 Dai proceeds to cancel her liquidated debt, leaving 100 Dai as protocol surplus.
        vm.warp(liquidationTime + vow.wait());
        vm.startPrank(keeper);
        vow.flog(liquidationTime); // removes that liquidation’s debt from the Vow’s waiting queue, making it eligible for settlement.
        vow.heal(ALICE_DEBT * RAY); // cancels 1,000 Dai of the Vow’s bad debt against 1,000 Dai of its internal Dai balance.
        vm.stopPrank();

        // The accounting is:
        // Vow balance	            Before settlement	After settlement
        // Bad debt (vat.sin)	        1,000 Dai	            0
        // Internal Dai (vat.dai)	    1,100 Dai	        100 Dai

        assertEq(vat.sin(address(vow)), 0);
        assertEq(vat.dai(address(vow)), 100 ether * RAY);
        assertEq(vat.debt(), BUYER_DEBT * RAY);
        assertEq(dai.balanceOf(alice), ALICE_DEBT);
    }
}
