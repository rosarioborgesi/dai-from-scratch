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

contract Dai is ERC20, EIP712 {
    ////////////////////////////////
    //            Errors          //
    ////////////////////////////////
    error Dai__NotAuthorized();
    error Dai__InvalidAddressZero();
    error Dai__InvalidPermit();
    error Dai__PermitExpired();
    error Dai__InvalidNonce();

    ///////////////////////////////////////////
    //            Type Declarations          //
    ///////////////////////////////////////////

    /////////////////////////////////////////
    //            State Variables          //
    /////////////////////////////////////////
    // Stores the addresses that have administrative permission in the contract. (0 not authorized, 1 authorized)
    mapping(address user => uint256 auth) private s_wards;

    // Per address counter that prevents a permit signature from being reused
    // The signed nonce must match the holder’s current counter, initially 0
    // A successful permit increments it, so submitting the same signature again fails.
    mapping(address user => uint256 counter) private s_nonces;

    // --- EIP712 ---;
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address holder,address spender,uint256 nonce,uint256 expiry,bool allowed)");

    ////////////////////////////////
    //            Events          //
    ////////////////////////////////

    ///////////////////////////////////
    //            Modifiers          //
    ///////////////////////////////////
    // Only authorized addresses (1) can execute this function
    modifier auth() {
        if (s_wards[msg.sender] != 1) {
            revert Dai__NotAuthorized();
        }
        _;
    }

    ///////////////////////////////////
    //            Functions          //
    ///////////////////////////////////
    constructor() ERC20("Dai Stablecoin", "DAI") EIP712("Dai Stablecoin", "1") {
        s_wards[msg.sender] = 1;
    }

    ////////////////////////////////////////////
    //            Internal Functions          //
    ////////////////////////////////////////////
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
    // Grants administrative permissions the user
    function rely(address user) external auth {
        s_wards[user] = 1;
    }

    // Revokes administrative permissions to the user
    function deny(address user) external auth {
        s_wards[user] = 0;
    }

    function mint(address user, uint256 amount) external auth {
        _mint(user, amount);
    }

    function burn(address user, uint256 amount) external {
        address spender = _msgSender();
        if (user != spender) {
            _spendAllowance(user, spender, amount);
        }
        _burn(user, amount);
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
    function wards(address user) external view returns (uint256) {
        return s_wards[user];
    }

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
