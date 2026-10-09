// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "openzeppelin-contracts/interfaces/draft-IERC6093.sol";
import {Dai} from "../../src/Dai.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

contract DaiUnitTest is Test {
    uint256 constant HOLDER_KEY = 0xA11CE;
    uint256 constant WRONG_SIGNER_KEY = 0xBAD;
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 PERMIT_TYPEHASH;

    Dai dai;
    address holder;
    address spender;
    address relayer;
    address otherHolder;
    address otherSpender;

    function setUp() public {
        dai = new Dai();
        PERMIT_TYPEHASH = dai.getPermitTypeHash();

        holder = vm.addr(HOLDER_KEY);
        spender = makeAddr("spender");
        relayer = makeAddr("relayer");
        otherHolder = makeAddr("otherHolder");
        otherSpender = makeAddr("otherSpender");
    }

    // The holder signs an unlimited approval for the spender; a separate relayer submits it.
    // The signature determines the holder and spender, regardless of who submits the permit.
    function test_Permit_ValidSignatureApprovesThroughRelayer() public {
        uint256 nonce = 0;
        uint256 expiry = 0;
        bool allowed = true;
        bytes32 digest = dai.getPermitDigest(holder, spender, nonce, expiry, allowed);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(HOLDER_KEY, digest);

        assertEq(dai.allowance(holder, spender), 0);
        assertEq(dai.nonces(holder), 0);

        vm.expectEmit(true, true, false, true, address(dai));
        emit IERC20.Approval(holder, spender, type(uint256).max);

        vm.prank(relayer);
        dai.permit(holder, spender, nonce, expiry, allowed, v, r, s);

        assertEq(dai.allowance(holder, spender), type(uint256).max);
        assertEq(dai.nonces(holder), 1);
        assertEq(dai.nonces(relayer), 0);
        assertEq(dai.allowance(relayer, spender), 0);
    }

    // expiry = 0 disables the time limit; the permit remains valid if its nonce is current.
    function test_Permit_ZeroExpiryRemainsValidAfterTimeAdvances() public {
        uint256 nonce = 0;
        uint256 expiry = 0;
        bool allowed = true;
        bytes32 digest = dai.getPermitDigest(holder, spender, nonce, expiry, allowed);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(HOLDER_KEY, digest);
        vm.warp(block.timestamp + 365 days);

        vm.prank(relayer);
        dai.permit(holder, spender, nonce, expiry, allowed, v, r, s);

        assertEq(dai.allowance(holder, spender), type(uint256).max);
        assertEq(dai.nonces(holder), 1);
    }

    // A new permit with allowed = false revokes the existing allowance.
    function test_Permit_AllowedFalseRevokesExistingAllowance() public {
        // Grant unlimited allowance with the initial nonce.
        uint256 nonce = 0;
        uint256 expiry = 0;
        bool allowed = true;
        bytes32 digest = dai.getPermitDigest(holder, spender, nonce, expiry, allowed);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(HOLDER_KEY, digest);

        vm.prank(relayer);
        dai.permit(holder, spender, nonce, expiry, allowed, v, r, s);

        assertEq(dai.allowance(holder, spender), type(uint256).max);

        // Sign a new permit with the next nonce to revoke the allowance.
        nonce = 1;
        allowed = false;
        digest = dai.getPermitDigest(holder, spender, nonce, expiry, allowed);
        (v, r, s) = vm.sign(HOLDER_KEY, digest);

        vm.expectEmit(true, true, false, true, address(dai));
        emit IERC20.Approval(holder, spender, 0);
        vm.prank(relayer);
        dai.permit(holder, spender, nonce, expiry, allowed, v, r, s);

        assertEq(dai.allowance(holder, spender), 0);
        assertEq(dai.nonces(holder), 2);
    }

    // Each successful permit increments the holder's nonce, even for a different spender.
    function test_Permit_FreshSignaturesWithSuccessiveNoncesSucceed() public {
        // Approve the first spender with the initial nonce.
        uint256 nonce = 0;
        uint256 expiry = 0;
        bool allowed = true;
        bytes32 digest = dai.getPermitDigest(holder, spender, nonce, expiry, allowed);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(HOLDER_KEY, digest);

        vm.prank(relayer);
        dai.permit(holder, spender, nonce, expiry, allowed, v, r, s);

        // Approve a different spender with the next nonce.
        nonce = 1;
        digest = dai.getPermitDigest(holder, otherSpender, nonce, expiry, allowed);
        (v, r, s) = vm.sign(HOLDER_KEY, digest);

        vm.prank(relayer);
        dai.permit(holder, otherSpender, nonce, expiry, allowed, v, r, s);

        assertEq(dai.nonces(holder), 2);
        assertEq(dai.allowance(holder, spender), type(uint256).max);
        assertEq(dai.allowance(holder, otherSpender), type(uint256).max);
        assertEq(dai.nonces(otherHolder), 0);
    }

    // A valid permit succeeds one second before its signed expiry.
    function test_Permit_SucceedsBeforeExpiry() public {
        uint256 nonce = 0;
        uint256 expiry = block.timestamp + 1 hours;
        bool allowed = true;
        bytes32 digest = dai.getPermitDigest(holder, spender, nonce, expiry, allowed);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(HOLDER_KEY, digest);

        vm.warp(expiry - 1);

        vm.prank(relayer);
        dai.permit(holder, spender, nonce, expiry, allowed, v, r, s);

        assertEq(dai.allowance(holder, spender), type(uint256).max);
        assertEq(dai.nonces(holder), 1);
    }

    // A correctly signed permit reverts one second after its expiry.
    function test_Permit_RevertsOneSecondAfterSignedExpiry() public {
        uint256 nonce = 0;
        uint256 expiry = block.timestamp + 1 hours;
        bool allowed = true;
        bytes32 digest = dai.getPermitDigest(holder, spender, nonce, expiry, allowed);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(HOLDER_KEY, digest);

        vm.warp(expiry + 1);

        vm.expectRevert(Dai.Dai__PermitExpired.selector);
        vm.prank(relayer);
        dai.permit(holder, spender, nonce, expiry, allowed, v, r, s);
    }

    // Reusing a successful permit fails because the holder's nonce has advanced.
    function test_Permit_RevertsOnReplay() public {
        uint256 nonce = 0;
        uint256 expiry = 0;
        bool allowed = true;
        bytes32 digest = dai.getPermitDigest(holder, spender, nonce, expiry, allowed);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(HOLDER_KEY, digest);

        // Submit the permit once to consume its nonce.
        vm.prank(relayer);
        dai.permit(holder, spender, nonce, expiry, allowed, v, r, s);

        // The same signature is still authentic, but its nonce is no longer current.
        vm.expectRevert(Dai.Dai__InvalidNonce.selector);
        vm.prank(relayer);
        dai.permit(holder, spender, nonce, expiry, allowed, v, r, s);
    }

    // A correctly signed permit fails if its nonce is ahead of the holder's current nonce.
    function test_Permit_RevertsOnCorrectlySignedFutureNonce() public {
        uint256 nonce = 1;
        uint256 expiry = 0;
        bool allowed = true;
        bytes32 digest = dai.getPermitDigest(holder, spender, nonce, expiry, allowed);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(HOLDER_KEY, digest);

        vm.expectRevert(Dai.Dai__InvalidNonce.selector);
        vm.prank(relayer);
        dai.permit(holder, spender, nonce, expiry, allowed, v, r, s);
    }

    // A signature from another private key cannot authorize approval for the holder.
    function test_Permit_RevertsOnWrongSigner() public {
        uint256 nonce = 0;
        uint256 expiry = 0;
        bool allowed = true;
        bytes32 digest = dai.getPermitDigest(holder, spender, nonce, expiry, allowed);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(WRONG_SIGNER_KEY, digest);

        vm.expectRevert(Dai.Dai__InvalidPermit.selector);
        vm.prank(relayer);
        dai.permit(holder, spender, nonce, expiry, allowed, v, r, s);
    }

    // Substituting another holder invalidates the original holder's signature.
    function test_Permit_RevertsOnChangedHolder() public {
        uint256 nonce = 0;
        uint256 expiry = 0;
        bool allowed = true;
        bytes32 digest = dai.getPermitDigest(holder, spender, nonce, expiry, allowed);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(HOLDER_KEY, digest);

        vm.expectRevert(Dai.Dai__InvalidPermit.selector);
        vm.prank(relayer);
        dai.permit(otherHolder, spender, nonce, expiry, allowed, v, r, s);
    }

    // The holder signs approval for spender; substituting another spender invalidates the signature.
    function test_Permit_RevertsOnChangedSpender() public {
        uint256 nonce = 0;
        uint256 expiry = 0;
        bool allowed = true;
        bytes32 digest = dai.getPermitDigest(holder, spender, nonce, expiry, allowed);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(HOLDER_KEY, digest);

        vm.expectRevert(Dai.Dai__InvalidPermit.selector);
        vm.prank(relayer);
        dai.permit(holder, otherSpender, nonce, expiry, allowed, v, r, s);
    }

    // Changing the signed nonce invalidates the signature before the nonce check runs.
    function test_Permit_RevertsOnChangedNonce() public {
        uint256 nonce = 0;
        uint256 expiry = 0;
        bool allowed = true;
        bytes32 digest = dai.getPermitDigest(holder, spender, nonce, expiry, allowed);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(HOLDER_KEY, digest);

        vm.expectRevert(Dai.Dai__InvalidPermit.selector);
        vm.prank(relayer);
        dai.permit(holder, spender, 1, expiry, allowed, v, r, s);
    }
}
