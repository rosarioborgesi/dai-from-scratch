// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// internal & private view & pure functions
// external & public view & pure functions

// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {EIP712} from "openzeppelin-contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "openzeppelin-contracts/utils/cryptography/ECDSA.sol";
import {Auth} from "./Auth.sol";

contract Dai is ERC20, EIP712, Auth {
    ////////////////////////////////
    //            Errors          //
    ////////////////////////////////
    error Dai__NotAuthorized();
    error Dai__InvalidAddressZero();
    error Dai__InvalidPermit();
    error Dai__PermitExpired();
    error Dai__InvalidNonce();

    // Per address counter that prevents a permit signature from being reused
    // The signed nonce must match the holder’s current counter, initially 0
    // A successful permit increments it, so submitting the same signature again fails.
    mapping(address user => uint256 counter) private s_nonces;

    // --- EIP712 ---;
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address holder,address spender,uint256 nonce,uint256 expiry,bool allowed)");

    ///////////////////////////////////
    //            Functions          //
    ///////////////////////////////////
    constructor() ERC20("Dai Stablecoin", "DAI") EIP712("Dai Stablecoin", "1") {}

    ////////////////////////////////////////////
    //            Internal Functions          //
    ////////////////////////////////////////////
    function _revertNotAuthorized() internal pure override {
        revert Dai__NotAuthorized();
    }

    // Returns the Permit hash struct
    function _getPermitHashStruct(address holder, address spender, uint256 nonce, uint256 expiry, bool allowed)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(PERMIT_TYPEHASH, holder, spender, nonce, expiry, allowed));
    }

    function _isValidSignature(address signer, bytes32 digest, uint8 v, bytes32 r, bytes32 s)
        internal
        pure
        returns (bool)
    {
        (address actualSigner,,) = ECDSA.tryRecover(digest, v, r, s);
        return actualSigner == signer;
    }

    ////////////////////////////////////////////
    //            External Functions          //
    ////////////////////////////////////////////
    function mint(address user, uint256 wad) external auth {
        _mint(user, wad);
    }

    function burn(address user, uint256 wad) external {
        address spender = _msgSender();
        if (user != spender) {
            _spendAllowance(user, spender, wad);
        }
        _burn(user, wad);
    }

    // Approve by signature
    function permit(
        address holder,
        address spender,
        uint256 nonce,
        uint256 expiry,
        bool allowed,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (holder == address(0)) {
            revert Dai__InvalidAddressZero();
        }

        bytes32 digest = getPermitDigest(holder, spender, nonce, expiry, allowed);

        if (!_isValidSignature(holder, digest, v, r, s)) {
            revert Dai__InvalidPermit();
        }
        if (expiry > 0 && block.timestamp > expiry) {
            revert Dai__PermitExpired();
        }
        if (nonce != s_nonces[holder]) {
            revert Dai__InvalidNonce();
        }

        s_nonces[holder]++;

        uint256 wad = allowed ? type(uint256).max : 0;

        _approve(holder, spender, wad);
    }

    //////////////////////////////////////////
    //            Public Functions          //
    //////////////////////////////////////////

    // Returns the hash of the fully EIP712 encoded Permit hash. This is the hash to be signed
    function getPermitDigest(address holder, address spender, uint256 nonce, uint256 expiry, bool allowed)
        public
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(_getPermitHashStruct(holder, spender, nonce, expiry, allowed));
    }

    //////////////////////////////////////////////////////
    //      External & Public View & Pure Functions     //
    //////////////////////////////////////////////////////
    function nonces(address user) external view returns (uint256) {
        return s_nonces[user];
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function getPermitTypeHash() external view returns (bytes32) {
        return PERMIT_TYPEHASH;
    }
}
