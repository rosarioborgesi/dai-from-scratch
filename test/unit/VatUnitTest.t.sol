// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {Vat} from "../../src/Vat.sol";
import {VatMath} from "../../src/libraries/VatMath.sol";

contract VatUnitTest is Test {
    bytes32 constant ILK = "ETH-A";
    uint256 constant RAY = 1e27;
    uint256 constant ART = 10 ether; // Normalized debt

    Vat vat;
    address recipient = makeAddr("recipient");
    address u = makeAddr("vaultOwner");
    address v = makeAddr("collateralOwner");
    address w = makeAddr("daiOwner");
    address operator = makeAddr("operator");
    bytes32 constant SECOND_ILK = "BTC-A";

    function setUp() public {
        vat = new Vat();
    }

    /////////////////////////////////////
    //              frob               //
    /////////////////////////////////////

    // The fixture initializes the collateral type with rate = RAY, representing 1.0 (init),
    // supplies v with 20 collateral units (slip)
    // and sets generous safety (spot) and debt limits (Line and line)
    modifier withFrobConfig() {
        vat.init(ILK);
        vat.file("Line", 100 ether * RAY);
        vat.file(ILK, "line", 100 ether * RAY);
        vat.file(ILK, "spot", 2 * RAY);
        vat.slip(ILK, v, int256(20 ether));
        _;
    }

    // Checks that locking 10 collateral units and borrowing 5 Dai updates the correct accounts.
    function test_Frob_LockAndBorrow() public withFrobConfig {
        // It uses 4 distinct addresses
        // - u: owns the vault and takes on the debt
        // - v: supplies the collateral
        // - w: receives the generated internal Dai
        // - operator: calls frob

        // v starts with 20 collateral units

        // u authorizes operator
        vm.prank(u);
        vat.hope(operator);

        // v authorizes operator
        vm.prank(v);
        vat.hope(operator);

        // The operator locks 10 units of v's collateral in u's vault.
        // u's vault takes on 5 units of normalized debt, generating 5 internal Dai for w.
        int256 dink = 10 ether; // Increase in locked collateral [wad]
        int256 dart = 5 ether; // Increase in normalized debt [wad]
        vm.prank(operator);
        vat.frob(ILK, u, v, w, dink, dart);

        assertEq(vat.urns(ILK, u).ink, 10 ether); // Locked collateral in u's vault
        assertEq(vat.urns(ILK, u).art, 5 ether); // Normalized debt in u's vault
        assertEq(vat.ilks(ILK).art, 5 ether); // Total normalized debt for the ilk
        assertEq(vat.gem(ILK, v), 10 ether); // Remaining free collateral belonging to v
        assertEq(vat.dai(w), 5 ether * RAY); // w's internal Dai balance [rad]
        assertEq(vat.debt(), 5 ether * RAY); // Total system debt [rad]

        // Assert Unrelated Balances
        assertEq(vat.gem(ILK, u), 0);
        assertEq(vat.gem(ILK, w), 0);
        assertEq(vat.gem(ILK, operator), 0);
        assertEq(vat.gem(ILK, recipient), 0);
        assertEq(vat.dai(u), 0);
        assertEq(vat.dai(v), 0);
        assertEq(vat.dai(operator), 0);
        assertEq(vat.dai(recipient), 0);
        assertEq(vat.urns(ILK, v).ink, 0);
        assertEq(vat.urns(ILK, v).art, 0);
        assertEq(vat.urns(ILK, w).ink, 0);
        assertEq(vat.urns(ILK, w).art, 0);
    }

    /////////////////////////////////////
    //              fold               //
    /////////////////////////////////////
    modifier withFoldPosition() {
        uint256 DEBT_CEILING = 10 ether * RAY;
        uint256 COLLATERAL_DEBT_CEILING = 10 ether * RAY; // Debt ceiling for the speicfic collateral (ilk)
        uint256 COLLATERAL_AMOUNT = 10 ether;
        uint256 LOCKED_COLLATERAL = 10 ether;

        // Initializes the rate of the collateral to 1
        vat.init(ILK);
        vat.file("Line", DEBT_CEILING); // Total Debt ceiling
        vat.file(ILK, "line", COLLATERAL_DEBT_CEILING); // Collateral debt ceiling
        vat.file(ILK, "spot", RAY); // Price with Safety Margin

        // Credits the test contract with 10 units of collateral
        vat.slip(ILK, address(this), int256(COLLATERAL_AMOUNT));

        // Uses frob() to lock the collateral (10 tokens) and borrow 10 Dai.
        vat.frob(ILK, address(this), address(this), address(this), int256(LOCKED_COLLATERAL), int256(ART));

        // The vault starts with 10 units of locked collateral and 10 units of normalized debt.
        // The test contract holds the borrowed Dai.
        // The recipient starts with zero.
        _;
    }

    // Positive adjustment
    // Checks that increasing a collateral type's debt multiplier increases the debt owed
    // and credits the resulting Dai to a recipient.

    // Total debt becomes 11 Dai and the recipient receives 1 internal Dai
    function test_Fold_PositiveAdjustment() public withFoldPosition {
        uint256 LOCKED_COLLATERAL = 10 ether;
        // The setup creates one ETH-A vault with 10 collateral units and 10 Dai of debt.
        // Its initial multiplier rate is RAY, representing 1.0

        // Adds RAY/10 (0.1) to the multiplier, raising it from 1.0 to 1.1
        // fold calculates:
        // additional debt = total normalized debt x multiplier increment
        //     = 10 x 0.1
        //     = 1 Dai
        uint256 delta = RAY / 10;
        vat.fold(ILK, recipient, int256(delta));

        assertEq(vat.ilks(ILK).rate, RAY + delta); // The debt multiplier is now 1.1
        assertEq(vat.dai(recipient), ART * delta); // The recipient receives 1 internal Dai
        assertEq(vat.debt(), ART * (RAY + delta)); // Global debt increases to 11 Dai
        assertEq(vat.ilks(ILK).art, ART); // Total normalized debt remains 10
        assertEq(vat.urns(ILK, address(this)).art, ART); // The vault's normalized debt remains 10
        assertEq(vat.urns(ILK, address(this)).ink, LOCKED_COLLATERAL); // Locked collateral remains 10 units
        assertEq(vat.dai(address(this)), ART * RAY); // The borrower still holds the original 10 internal Dai

        // fold can accrue debt above the configured ceilings.
        assertGt(vat.debt(), vat.s_line());
    }

    // A negative adjustment lowers the multiplier and removes internal Dai from the recipient.
    function test_Fold_NegativeAdjustment() public withFoldPosition {
        uint256 LOCKED_COLLATERAL = 10 ether;
        // The setup creates one ETH-A vault with 10 collateral units and 10 Dai of debt.
        // Its initial multiplier rate is RAY, representing 1.0.

        // Subtracts RAY/10 (0.1) from the multiplier, lowering it from 1.0 to 0.9.
        // fold calculates:
        // debt adjustment = total normalized debt x signed multiplier adjustment
        //     = 10 x (-0.1)
        //     = -1 Dai
        uint256 delta = RAY / 10;
        uint256 adjustment = ART * delta;

        // Apply the reduction to the borrower, which already holds 10 internal Dai.
        vat.fold(ILK, address(this), -int256(delta));

        assertEq(vat.ilks(ILK).rate, RAY - delta); // The debt multiplier is now 0.9
        assertEq(vat.dai(recipient), 0); // The other address remains unfunded
        assertEq(vat.debt(), ART * (RAY - delta)); // Global debt decreases to 9 Dai
        assertEq(vat.ilks(ILK).art, ART); // Total normalized debt remains 10
        assertEq(vat.urns(ILK, address(this)).art, ART); // The vault's normalized debt remains 10
        assertEq(vat.urns(ILK, address(this)).ink, LOCKED_COLLATERAL); // Locked collateral remains 10 units
        assertEq(vat.dai(address(this)), ART * RAY - adjustment); // 1 internal Dai is removed from the borrower
    }
}
