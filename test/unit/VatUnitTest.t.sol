// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {Vat} from "../../src/Vat.sol";
import {Math} from "../../src/libraries/Math.sol";

contract VatUnitTest is Test {
    bytes32 constant ILK = "ETH-A";
    bytes32 constant SECOND_ILK = "BTC-A";

    uint256 constant RAY = 1e27;
    uint256 constant ART = 10 ether; // Normalized debt

    Vat vat;

    address bob = makeAddr("bob"); // Bob is a separate vault owner.
    address alice = makeAddr("alice"); // Alice supplies collateral and usually owns the vault;
    address feeRecipient = makeAddr("feeRecipient");
    address daiRecipient = makeAddr("daiRecipient");
    address operator = makeAddr("operator");

    function setUp() public {
        vat = new Vat();
    }

    /////////////////////////////////////
    //              frob               //
    /////////////////////////////////////

    // Initializes the collateral type (rate = RAY)
    // Sets total debt ceiling (Line)
    // Sets collateral's debt sceiling (line)
    // Sets the price with Safety margin (spot)
    modifier withVat(bytes32 ilk, uint256 Line, uint256 line, uint256 spot) {
        vat.init(ilk);
        vat.file("Line", Line);
        vat.file(ilk, "line", line);
        vat.file(ilk, "spot", spot); // Price with Safety Margin
        _;
    }

    // Adds amount of free collateral (ilk) to _address
    modifier withFreeCollateral(bytes32 ilk, address _address, int256 amount) {
        vat.slip(ilk, _address, amount);
        _;
    }

    // A single safe vault owned by Alice: 10 collateral, 5 normalized debt, 5 internal Dai.
    modifier withAliceVault() {
        vm.prank(alice);
        // Frob arguments:
        // - ILK -> the collateral
        // - alice (u) -> the vault that take on the debt
        // - alice (v) -> The collateral source (unused because dink = 0)
        // - daiRecipient (w) -> receives the generated internal Dai
        // - 10 (dink) -> Locks 10 units of  collateral
        // - 5 ether (dart) -> adds 5 unit of normalized debt
        vat.frob(ILK, alice, alice, alice, 10 ether, 5 ether);
        _;
    }

    // Verifies the happy path of locking 10 collateral units and borrow 5 Dai
    function test_Frob_LockAndBorrow()
        public
        withVat(ILK, 100 ether * RAY, 100 ether * RAY, 2 * RAY)
        withFreeCollateral(ILK, alice, int256(20 ether))
    {
        // Alice locks 10 units of collateral ad takes 5 units of normalized debt
        // Since rate is 1 normalized debt == generated Dai
        vm.prank(alice);
        vat.frob(ILK, alice, alice, alice, 10 ether, 5 ether);

        assertEq(vat.urns(ILK, alice).ink, 10 ether); // Locked collateral in alice's vault
        assertEq(vat.urns(ILK, alice).art, 5 ether); // Normalized debt in alice's vault
        assertEq(vat.ilks(ILK).Art, 5 ether); // Total normalized debt for the ilk
        assertEq(vat.gem(ILK, alice), 10 ether); // Remaining free collateral belonging to alice
        assertEq(vat.dai(alice), 5 ether * RAY); // alice's internal Dai balance [rad]
        assertEq(vat.debt(), 5 ether * RAY); // Total system debt [rad]
    }

    // A safe borrow succeeds, but borrowing beyond the collateral's safety-adjusted value reverts.
    // After borrowing, the vault's total debt must satisfy:
    // art × rate ≤ ink × spot
    function test_Frob_RevertWhenBorrowingExceedsCollateralValue()
        public
        withVat(ILK, 100 ether * RAY, 100 ether * RAY, RAY)
        withFreeCollateral(ILK, alice, int256(20 ether))
    {
        // Since: art × rate ≤ ink × spot
        // and:
        // - ink = 10 ether  -> The vault has 10 locked collateral units
        // - spot = 1 -> each collateral unit supports 1 Dai of debt after safe margin
        // - rate = 1 -> each unit of normalized debt represents 1 Dai owed
        //
        // The vault can safely owe at most 10 Dai

        // We are Locking 10 collateral units and borrowing 5 internal Dai (because rate = 1)
        vm.prank(alice);
        vat.frob(ILK, alice, alice, alice, 10 ether, 5 ether);

        // Another 6 Dai would bring total debt to 11 Dai with only 10 collateral.
        // Since the maximum we can borrow is 10 Dai, it has to revert.
        vm.expectRevert(Vat.Vat__NotSafe.selector);
        vm.prank(alice);
        vat.frob(ILK, alice, alice, alice, 0, 6 ether);
    }

    // This test verifies that borrowing at exactly up to a collateral type's debt ceiling succeeds,
    // but exceeding it by even the smallest amount reverts
    function test_Frob_CollateralDebtCeilingBoundary()
        public
        withVat(ILK, 100 ether * RAY, 10 ether * RAY, 2 * RAY)
        withFreeCollateral(ILK, alice, int256(20 ether))
    {
        // Vat configuration:
        // - Global debt ceiling: 100 Dai across the system.
        // - Collateral debt ceiling: 10 Dai across all ETH-A vaults
        // - Safety-adjusted collateral price: 2 Dai per collateral unit
        // - Debt rate: RAY, so one normalized debt unit represents one Dai

        // Alice has 20 units of free collateral

        // First Alice locks 10 collateral units and borrows 10 Dai
        // This succeds because the debt equals the collateral type's 10 Dai ceiling.
        // Her collateral also supports 20 Dai, so the vault is safe.
        vm.prank(alice);
        vat.frob(ILK, alice, alice, alice, 10 ether, 10 ether);

        // Second Alice tries to borrow 1 wei more of Dai
        // This conditions becomes true:
        //  ilk.art * ilk.rate > ilk.line
        // - ilk.art = 10 ether + 1
        // - ilk.rate = RAY
        // - ilk.line = 10 ether * RAY
        // So:
        // 10 + 1 wei > 10
        // so it reverts
        vm.expectRevert(Vat.Vat__CeilingExceeded.selector);
        vm.prank(alice);
        vat.frob(ILK, alice, alice, alice, 0, 1);
    }

    // Proves that the global debt ceiling applies to the combined debt across all collateral types
    function test_Frob_GlobalDebtCeilingBoundaryAcrossIlks()
        public
        withVat(ILK, 10 ether * RAY, 100 ether * RAY, 2 * RAY)
        withFreeCollateral(ILK, alice, int256(20 ether))
    {
        // withVat initilizes the collateral ILK

        // Here we are initializing the collateral SECOND_ILK
        vat.init(SECOND_ILK);
        vat.file(SECOND_ILK, "line", 100 ether * RAY);
        vat.file(SECOND_ILK, "spot", 2 * RAY);

        // We are giving 10 ether of SECOND_ILK free collateral to Alice
        vat.slip(SECOND_ILK, alice, 10 ether);

        // Global celining (Line) -> 10 Dai

        // ILK
        // Individual debt ceiling (line) -> 100 Dai
        // Alice's initial free collateral -> 20 units
        // Safety-adjusted price (spot) -> 2 Dai/uint
        // Debt multiplier = RAY so 1 normalized debt unit = 1 Dai

        // SECOND_ILK
        // Individual debt ceiling (line) -> 100 Dai
        // Alice's initial free collateral -> 10 units
        // Safety-adjusted price (spot) -> 2 Dai/unit
        // Debt multiplier = RAY so 1 normalized debt unit = 1 Dai

        vm.startPrank(alice);
        // 1. Alice borrows 5 Dai against ILK
        // Frob arguments:
        // - ILK -> the collateral
        // - alice (u) -> modify Alice's vault
        // - alice (v) -> Send the unlocked collateral to the Alice's free collateral balance
        // - alice (w) -> Alice receives internal Dai
        // - 10 ether (dink) -> Locks 10 collateral units
        // - 5 ether (dart) -> Adds 5 normalized debt units -> because rate is 1.0, generates 5 internal Dai
        vat.frob(ILK, alice, alice, alice, 10 ether, 5 ether);
        // Combined debt reaches exactly 10 Dai; each ilk remains below its own ceiling.

        // 2. Alice borrows another 5 Dai against SECOND_ILK
        // Frob arguments:
        // - SECOND_ILK -> the collateral
        // - alice (u) -> modify Alice's vault
        // - alice (v) -> Send the unlocked collateral to the Alice's free collateral balance
        // - alice (w) -> Alice receives internal Dai
        // - 10 ether (dink) -> Locks 10 collateral units
        // - 5 ether (dart) -> Adds 5 normalized debt units -> because rate is 1.0, generates 5 internal Dai

        // Combined debt reaches exactly 10 Dai, so this succeeds.
        vat.frob(SECOND_ILK, alice, alice, alice, 10 ether, 5 ether);

        // 3. Alice tries to borrow one more smallest unit of normalized debt.
        // Frob arguments:
        // - SECOND_ILK -> the collateral
        // - alice (u) -> modify Alice's vault
        // - alice (v) -> Send the unlocked collateral to the Alice's free collateral balance
        // - alice (w) -> Alice receives internal Dai
        // - 0 (dink) -> collateral units locked unchanged
        // - 1 ether (dart) -> Adds 1 wei normalized debt units -> because rate is 1.0, generates 1 wei of internal Dai

        // Combined debt would exceed the global 10 Dai ceiling, so the call reverts.
        // This becomes true:  s_debt > s_Line
        // Because 10 ether + 1 > 10 ether
        vm.expectRevert(Vat.Vat__CeilingExceeded.selector);
        vat.frob(SECOND_ILK, alice, alice, alice, 0, 1);
        vm.stopPrank();
    }

    // Verifies that borrowing exactly up to the collateral's safety limits succeeds,
    // while borrowing one unit more reverts.
    function test_Frob_BorrowAtCollateralSafetyBoundary()
        public
        withVat(ILK, 100 ether * RAY, 100 ether * RAY, RAY)
        withFreeCollateral(ILK, alice, int256(20 ether))
    {
        // Vat configuration:
        // - Global debt ceiling: 100 Dai across the system.
        // - Collateral debt ceiling: 100 Dai across all ETH-A vaults
        // - Safety-adjusted collateral price: 1 Dai per collateral unit
        // - Debt rate: RAY, so one normalized debt unit represents one Dai

        // Alice receives 20 units of free collateral.

        // Borrow at the exact limit
        // Frob arguments:
        // - ILK -> the collateral
        // - alice (u) -> modify Alice's vault
        // - alice (v) -> Send the unlocked collateral to the Alice's free collateral balance
        // - alice (w) -> Alice receives internal Dai
        // - 10 ether (dink) -> Locks 10 collateral units
        // - 10 ether (dart) -> Adds 10 normalized debt units -> because rate is 1.0, generates 10 internal Dai
        vm.prank(alice);
        vat.frob(ILK, alice, alice, alice, 10 ether, 10 ether);

        // Borrowing one wei of Dai more reverts.
        //
        // - debt multiplier (ilk.rate) = RAY
        // - normalized debt (urn.art) = (10 ether + 1)
        // - collateral locked (urn.ink) = 10 ether
        // - Price with Safety Margin (ilk.spot) = RAY
        // So:
        // urn.art * ilk.rate > urn.ink * ilk.spot
        // (10 ether + 1) x RAY > 10 ether × RAY
        vm.expectRevert(Vat.Vat__NotSafe.selector);
        vm.prank(alice);
        vat.frob(ILK, alice, alice, alice, 0, 1);
    }

    // Checks that Alice can unlock collateral exactly up to the vault’s safety limit,
    // but cannot unlock even one smallest unit beyond it.
    function test_Frob_UnlockAtCollateralSafetyBoundary()
        public
        withVat(ILK, 100 ether * RAY, 100 ether * RAY, RAY)
        withFreeCollateral(ILK, alice, int256(20 ether))
        withAliceVault
    {
        // The modifiers set up:
        // - 20 collateral units belonging to Alice.
        // - A vault with 10 units collateral locked and 5 Dai of debt.
        // - spot = RAY: each collateral unit has a safety-adjusted value of 1 Dai.
        // - rate = RAY: each normalized debt unit represents 1 Dai.

        // Alice unlocks 5 collateral units into Alice’s free collateral balance; (dink = -5 ether)
        // Alice leaves her debt unchanged. (dart = 0)
        vm.prank(alice);
        vat.frob(ILK, alice, alice, alice, -5 ether, 0);

        // Alice's vault now sits exactly at the safety boundary:
        // Locked collateral value = 5 Dai
        // Debt                    = 5 Dai

        // The second call tries to unlock one smallest collateral unit (10⁻¹⁸ of a collateral unit) (dink = -1)
        // That would leave slightly less than 5 Dai of collateral value backing 5 Dai of debt, triggering
        // ilk.rate * urn.art > urn.ink * ilk.spot
        // RAY * (5 ether)    > (5 ether - 1) * RAY
        // This is true and it reverts

        //  Where
        // - urn.art: this vault’s normalized debt
        // - ilk.rate is the accumulated debt multiplyier for this collateral type
        // - urn.ink: the amount of collateral locked in the vault.
        // - ilk.spot: the collateral’s price after applying the protocol’s safety margin.
        vm.expectRevert(Vat.Vat__NotSafe.selector);
        vm.prank(alice);
        vat.frob(ILK, alice, alice, alice, -1, 0);
    }

    // Verifies the happy path of repaying 2 Dai
    function test_Frob_RepayDebt()
        public
        withVat(ILK, 100 ether * RAY, 100 ether * RAY, 2 * RAY)
        withFreeCollateral(ILK, alice, int256(20 ether))
        withAliceVault
    {
        // The modifiers prepare the starting state:
        // - withVat(...) initializes ETH-A with a debt multiplier of RAY (1.0).
        // - withFreeCollateral(...) gives Alice 20 collateral units.
        // - withAliceVault locks 10 of those units and borrows 5 internal Dai.

        // Frob arguments:
        // - ILK -> the collateral
        // - alice (u) -> modify Alice's vault
        // - alice (v) -> Use Alice’s free collateral balance
        // - alice (w) -> Take the repayment from Alice’s internal Dai balance
        // - 0 (dink) -> Leave locked collateral unchanged
        // - -2 ether (dart) -> Reduce normalized debt by 2 units

        // Because rate = RAY, repaying 2 normalized debt units costs exactly 2 Dai
        vm.prank(alice);
        vat.frob(ILK, alice, alice, alice, 0, -2 ether);

        // Actual debt = ray x rate
        // With a rate of 1.0, 3 normalized debt units represent 3 Dai owed

        assertEq(vat.urns(ILK, alice).ink, 10 ether);
        assertEq(vat.urns(ILK, alice).art, 3 ether); // 5 - 2
        assertEq(vat.ilks(ILK).Art, 3 ether); // 5 - 2
        assertEq(vat.gem(ILK, alice), 10 ether); // 20 - 10
        assertEq(vat.dai(alice), 3 ether * RAY); // actual debt = normalized debt because rate = 1.0
        assertEq(vat.debt(), 3 ether * RAY); // actual debt = normalized debt because rate = 1.0
    }

    // Verifies the happy path of borrowing at an updated rate
    function test_Frob_BorrowAtAccruedRate()
        public
        withVat(ILK, 100 ether * RAY, 100 ether * RAY, 2 * RAY)
        withFreeCollateral(ILK, alice, int256(20 ether))
    {
        // 1. Set up
        // The initial rate is RAY (meaning 1.0).
        // Alice receives 20 units of free collateral
        // Each collateral unit supports 2 Dai of debt.

        // 2. Increase the rate to 1.1.
        // fold adds 0.1 to the existing rate.
        vat.fold(ILK, feeRecipient, int256(RAY / 10));

        // 3. Alice locks 10 collateral and adds 5 normalized debt.
        vm.prank(alice);
        vat.frob(ILK, alice, alice, alice, 10 ether, 5 ether);

        // Accumulated rate is now 1.1
        assertEq(vat.ilks(ILK).rate, 11 * RAY / 10);

        // generated Dai = normalized debt x rate
        //               = 5 x 1.1 = 5.5 Dai
        assertEq(vat.urns(ILK, alice).ink, 10 ether);
        assertEq(vat.urns(ILK, alice).art, 5 ether);
        assertEq(vat.ilks(ILK).Art, 5 ether);
        assertEq(vat.gem(ILK, alice), 10 ether);
        assertEq(vat.dai(alice), 55 ether * RAY / 10); // 5.5 DAI
        assertEq(vat.debt(), 55 ether * RAY / 10); // 5.5 DAI

        assertEq(vat.dai(feeRecipient), 0);
    }

    // Reverts because operator doesn't have permission to borrow on Alice's behalf
    function test_Frob_RevertWhenBorrowingWithoutVaultPermission()
        public
        withVat(ILK, 100 ether * RAY, 100 ether * RAY, 2 * RAY)
        withFreeCollateral(ILK, alice, int256(20 ether))
        withAliceVault
    {
        // the debt multiplier (rate) is 1, and spot is 2, so each collateral unit supports 2 Dai of debt.

        // The operator is trying to borrow against Alice's vault and send the generated Dai to daiRecipient
        // and reverts
        vm.expectRevert(Vat.Vat__NotAllowedU.selector);
        vm.prank(operator);
        // Frob arguments:
        // - ILK -> the collateral
        // - alice (u) -> the vault that take on the debt
        // - alice (v) -> The collateral source (unused because dink = 0)
        // - daiRecipient (w) -> receives the generated internal Dai
        // - 0 (dink) -> no change to locked collateral
        // - 1 ether (dart) -> add 1 unit of normalized debt
        vat.frob(ILK, alice, alice, daiRecipient, 0, 1 ether);
    }

    // Alice authorizes the operator to borrow against her vault and send Dai to another address.
    function test_Frob_AuthorizedOperatorBorrowsDebt()
        public
        withVat(ILK, 100 ether * RAY, 100 ether * RAY, 2 * RAY)
        withFreeCollateral(ILK, alice, int256(20 ether))
        withAliceVault
    {
        // Alice grant's permissions to operator
        vm.prank(alice);
        vat.hope(operator);

        // operator can borrow against Alice's vault and send the generated Dai to dai recipient.
        // Frob arguments:
        // - ILK  -> the collateral
        // - alice (u) -> the vault that take on the debt
        // - alice (v) -> The collateral source (unused because dink = 0)
        // - daiRecipient (w) -> receives the generated internal Dai
        // - 0 (dink) -> no change to locked collateral
        // - 1 ether (dart) -> add 1 unit of normalized debt
        vm.prank(operator);
        vat.frob(ILK, alice, alice, daiRecipient, 0, 1 ether);

        assertEq(vat.can(alice, operator), 1);
        assertEq(vat.urns(ILK, alice).ink, 10 ether);
        assertEq(vat.urns(ILK, alice).art, 6 ether);
        assertEq(vat.ilks(ILK).Art, 6 ether);
        assertEq(vat.debt(), 6 ether * RAY);
        assertEq(vat.gem(ILK, alice), 10 ether);
        assertEq(vat.dai(alice), 5 ether * RAY);
        assertEq(vat.dai(daiRecipient), 1 ether * RAY);
        assertEq(vat.dai(operator), 0);
    }

    // Reverts because operator doesn't have permission to unlock on Alice's behalf
    function test_Frob_RevertWhenUnlockingWithoutVaultPermission()
        public
        withVat(ILK, 100 ether * RAY, 100 ether * RAY, 2 * RAY)
        withFreeCollateral(ILK, alice, int256(20 ether))
        withAliceVault
    {
        vm.expectRevert(Vat.Vat__NotAllowedU.selector);
        vm.prank(operator);
        // Frob arguments:
        // - ILK -> the collateral
        // - alice (u) -> modify Alice's vault
        // - operator (v) -> Send the unlocked collateral to the operator's free collateral balance
        // - alice (w) -> Dai account; unused here because debt does not change
        // - -1 ether (dink) -> Unlock 1 collateral unit
        // - 0 (dart) -> leave debt unchanged
        vat.frob(ILK, alice, operator, alice, -1 ether, 0);
    }

    // Locking collateral requires permission from the owner of the free collateral being used
    function test_Frob_RevertWhenLockingWithoutCollateralPermission()
        public
        withVat(ILK, 100 ether * RAY, 100 ether * RAY, 2 * RAY)
        withFreeCollateral(ILK, alice, int256(20 ether))
    {
        // Bob is trying to lock Alice's free collateral.
        // Since Alice hasn't authorized Bob it reverts.
        vm.expectRevert(Vat.Vat__NotAllowedV.selector);
        vm.prank(bob);
        // Frob arguments:
        // - ILK -> the collateral
        // - bob (u) -> Bob's vault
        // - alice (v) -> Send the unlocked collateral to alice's free collateral balance
        // - bob (w) -> Bob's Dai account;
        // - 10 ether (dink) -> Add 10 units of locked collateral
        // - 5 (dart) -> Add 5 units of normalized debt
        vat.frob(ILK, bob, alice, bob, 10 ether, 5 ether);
    }

    function test_Frob_RevertWhenRepayingWithoutDaiPermission()
        public
        withVat(ILK, 100 ether * RAY, 100 ether * RAY, 2 * RAY)
        withFreeCollateral(ILK, alice, int256(20 ether))
        withAliceVault
    {
        // Repayment needs the Dai owner's permission, even though it improves the vault.
        // Only Alice can do this operation.
        vm.expectRevert(Vat.Vat__NotAllowedW.selector);
        vm.prank(operator);
        // Frob arguments:
        // - ILK -> the collateral
        // - alice (u) -> modify Alice's vault
        // - alice (v) -> Send the unlocked collateral to alice's free collateral balance
        // - alice (w) -> Alice's Dai account;
        // - 0 ether (dink) -> Unchanged locked collateral
        // - -1 (dart) -> ARepay 1 unit of normalized debt
        vat.frob(ILK, alice, alice, alice, 0, -1 ether);
    }

    // An authorized operator can repay Alice’s debt using Alice’s internal Dai balance.
    function test_Frob_AuthorizedOperatorRepaysDebt()
        public
        withVat(ILK, 100 ether * RAY, 100 ether * RAY, 2 * RAY)
        withFreeCollateral(ILK, alice, int256(20 ether))
        withAliceVault
    {
        vm.prank(alice);
        vat.hope(operator);

        vm.prank(operator);
        vat.frob(ILK, alice, alice, alice, 0, -2 ether);

        assertEq(vat.urns(ILK, alice).ink, 10 ether);
        assertEq(vat.urns(ILK, alice).art, 3 ether);
        assertEq(vat.ilks(ILK).Art, 3 ether);
        assertEq(vat.gem(ILK, alice), 10 ether);
        assertEq(vat.dai(alice), 3 ether * RAY);
        assertEq(vat.debt(), 3 ether * RAY);
    }

    // Verifies that borrowing below the minimum debt (dust) reverts,
    // while borrowing exactly the minimum succeeds.
    function test_Frob_DustBoundaryOnBorrow()
        public
        withVat(ILK, 100 ether * RAY, 100 ether * RAY, 2 * RAY)
        withFreeCollateral(ILK, alice, int256(20 ether))
    {
        vat.file(ILK, "dust", 5 ether * RAY);

        // ilk.rate * urn.art < ilk.dust is true because:
        // 5 ether - 1 < 5 ether
        // So it reverts
        vm.expectRevert(Vat.Vat__Dust.selector);
        vm.prank(alice);
        vat.frob(ILK, alice, alice, alice, 10 ether, int256(5 ether - 1));

        // Debt equal to dust is allowed.
        // ilk.rate * urn.art < ilk.dust is false because:
        // 5 ether == 5 ether
        // SO it doesn't revert
        vm.prank(alice);
        vat.frob(ILK, alice, alice, alice, 10 ether, 5 ether);

        assertEq(vat.urns(ILK, alice).ink, 10 ether);
        assertEq(vat.urns(ILK, alice).art, 5 ether);
        assertEq(vat.ilks(ILK).Art, 5 ether);
        assertEq(vat.gem(ILK, alice), 10 ether);
        assertEq(vat.dai(alice), 5 ether * RAY);
        assertEq(vat.debt(), 5 ether * RAY);
    }

    // This test checks that a partial repayment cannot leave a vault with nonzero debt below dust,
    // the minimum allowed debt.
    function test_Frob_RevertWhenPartialRepaymentLeavesDebtBelowDust()
        public
        withVat(ILK, 100 ether * RAY, 100 ether * RAY, 2 * RAY)
        withFreeCollateral(ILK, alice, int256(20 ether))
        withAliceVault
    {
        // The modifiers prepare Alice’s vault with:
        // - 10 collateral units locked and 10 units of free collateral.
        // - 5 Dai of debt and 5 internal Dai.
        // - rate = RAY, representing a debt multiplier of 1.

        // Set the minimum allowed debt to 3 Dai
        vat.file(ILK, "dust", 3 ether * RAY);
        vm.prank(alice);

        // First Alice repays 2 Dai
        // - dink = 0: leaves the collateral unchanged
        // - dart = -2 ether: reduces normalized debt from 5 to 3
        // This succeeds because the remaining debt equals dust
        vat.frob(ILK, alice, alice, alice, 0, -2 ether);

        assertEq(vat.urns(ILK, alice).ink, 10 ether); // Unchanged locked collateral
        assertEq(vat.urns(ILK, alice).art, 3 ether); //  Urn's normalized debt reduced from 5 to 3 ether
        assertEq(vat.ilks(ILK).Art, 3 ether); // Collateral-type normalized debt reduced to 3 ether
        assertEq(vat.gem(ILK, alice), 10 ether); // Free collateral unchanged
        assertEq(vat.dai(alice), 3 ether * RAY); // Internal Dai balance reduced from 5 to 3 Dai
        assertEq(vat.debt(), 3 ether * RAY); // Total system debt reduced from 5 to 3 Dai

        // Now Alices tries to repay 1 wei of normalized debt so
        // ilk.rate * urn.art < ilk.dust is true because
        // 3 ether - 1 < 3 ether
        vm.expectRevert(Vat.Vat__Dust.selector);
        vm.prank(alice);
        vat.frob(ILK, alice, alice, alice, 0, -1);
    }

    // verifies that a vault may repay its entire debt,
    // even though zero is below the minimum debt (dust).
    function test_Frob_FullRepaymentBelowDust()
        public
        withVat(ILK, 100 ether * RAY, 100 ether * RAY, 2 * RAY)
        withFreeCollateral(ILK, alice, int256(20 ether))
        withAliceVault
    {
        // The modifiers prepare Alice’s vault with:
        // - 10 collateral units locked, plus 10 units of free collateral.
        // - 5 units of normalized debt.
        // - 5 internal Dai available for repayment.
        //     The debt multiplier is RAY, representing 1, so the debt equals 5 Dai.

        // Set the minimum debt to 3 Dai
        vat.file(ILK, "dust", 3 ether * RAY);
        vm.prank(alice);
        // Alice repays everything:
        // - dink = 0: leave collateral unchanged
        // - dart = - 5 ether: remove all 5 units of normalized debt
        //  ilk.rate * urn.art < ilk.dust is not checked because we are doing a full repayment (urn.art == 0)
        vat.frob(ILK, alice, alice, alice, 0, -5 ether);

        assertEq(vat.urns(ILK, alice).ink, 10 ether); // Unchanged locked collateral
        assertEq(vat.urns(ILK, alice).art, 0); // Normalized debt is erased
        assertEq(vat.ilks(ILK).Art, 0); // Normalized debt is erased
        assertEq(vat.gem(ILK, alice), 10 ether); // Unchanged free collateral
        assertEq(vat.dai(alice), 0); // Dai debt is erased
        assertEq(vat.debt(), 0); // Total debt is erased
    }

    // Verifies that frob rejects vault changes after the Vat is shut down
    function test_Frob_RevertAfterShutdown()
        public
        withVat(ILK, 100 ether * RAY, 100 ether * RAY, 2 * RAY)
        withFreeCollateral(ILK, alice, int256(20 ether))
        withAliceVault
    {
        vat.cage(); // Shutting the vault down
        vm.expectRevert(Vat.Vat__NotLive.selector);
        vm.prank(alice);
        vat.frob(ILK, alice, alice, alice, 0, 1 ether);
    }

    // frob reverts if the collateral is not initialized
    function test_Frob_RevertWhenIlkNotInitialized() public {
        vm.expectRevert(Vat.Vat__IlkNotInit.selector);
        vm.prank(alice);
        vat.frob(ILK, alice, alice, alice, 0, 1 ether);
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
        // The fee recipient starts with zero.
        _;
    }

    // Positive adjustment
    // Checks that increasing a collateral type's debt multiplier increases the debt owed
    // and credits the resulting Dai to the fee recipient.

    // Total debt becomes 11 Dai and the feeRecipient receives 1 internal Dai
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
        vat.fold(ILK, feeRecipient, int256(delta));

        assertEq(vat.ilks(ILK).rate, RAY + delta); // The debt multiplier is now 1.1
        assertEq(vat.dai(feeRecipient), ART * delta); // The fee recipient receives 1 internal Dai
        assertEq(vat.debt(), ART * (RAY + delta)); // Global debt increases to 11 Dai
        assertEq(vat.ilks(ILK).Art, ART); // Total normalized debt remains 10
        assertEq(vat.urns(ILK, address(this)).art, ART); // The vault's normalized debt remains 10
        assertEq(vat.urns(ILK, address(this)).ink, LOCKED_COLLATERAL); // Locked collateral remains 10 units
        assertEq(vat.dai(address(this)), ART * RAY); // The borrower still holds the original 10 internal Dai

        // fold can accrue debt above the configured ceilings.
        assertGt(vat.debt(), vat.s_Line());
    }

    // A negative adjustment lowers the multiplier and removes internal Dai from the fee recipient.
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
        assertEq(vat.dai(feeRecipient), 0); // The other address remains unfunded
        assertEq(vat.debt(), ART * (RAY - delta)); // Global debt decreases to 9 Dai
        assertEq(vat.ilks(ILK).Art, ART); // Total normalized debt remains 10
        assertEq(vat.urns(ILK, address(this)).art, ART); // The vault's normalized debt remains 10
        assertEq(vat.urns(ILK, address(this)).ink, LOCKED_COLLATERAL); // Locked collateral remains 10 units
        assertEq(vat.dai(address(this)), ART * RAY - adjustment); // 1 internal Dai is removed from the borrower
    }
}
