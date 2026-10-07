// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {Vat} from "../../src/Vat.sol";
import {VatMath} from "../../src/libraries/VatMath.sol";

contract VatUnitTest is Test {

    bytes32 constant ILK = "ETH-A";
    uint256 constant RAY = 1e27;
    uint256 constant ART = 10 ether; // Normalized debt
    uint256 constant DEBT_CEILING = 10 ether * RAY; 
    uint256 constant COLLATERAL_DEBT_CEILING = 10 ether * RAY; // Debt ceiling for the speicfic collateral (ilk)
    uint256 constant COLLATERAL_AMOUNT = 10 ether;
    uint256 constant LOCKED_COLLATERAL = 10 ether;
    Vat vat;
    address recipient = makeAddr("recipient");

    function setUp() public {
        vat = new Vat();

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
    }

    /////////////////////////////////////
    //              frob               //
    /////////////////////////////////////

    /////////////////////////////////////
    //              fold               //
    /////////////////////////////////////

    // Positive adjustment
    // Checks that increasing a collateral type's debt multiplier increases the debt owed
    // and credits the resulting Dai to a recipient.

    // Total debt becomes 11 Dai and the recipient receives 1 internal Dai
    function test_Fold_PositiveAdjustment() public {
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
    function test_Fold_NegativeAdjustment() public {
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
