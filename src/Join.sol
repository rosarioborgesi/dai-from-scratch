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

interface GemLike {
    function decimals() external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface DSTokenLike {
    function mint(address, uint256) external;
    function burn(address, uint256) external;
}

interface VatLike {
    function slip(bytes32, address, int256) external;
    function move(address, address, uint256) external;
}

/*
    Here we provide *adapters* to connect the Vat to arbitrary external
    token implementations, creating a bounded context for the Vat. The
    adapters here are provided as working examples:

      - `GemJoin`: For well behaved ERC20 tokens, with simple transfer
                   semantics.

      - `ETHJoin`: For native Ether.

      - `DaiJoin`: For connecting internal Dai balances to an external
                   `DSToken` implementation.

    In practice, adapter implementations will be varied and specific to
    individual collateral types, accounting for different transfer
    semantics and token standards.

    Adapters need to implement two basic methods:

      - `join`: enter collateral into the system
      - `exit`: remove collateral from the system

*/

contract GemJoin {
    ////////////////////////////////
    //            Errors          //
    ////////////////////////////////
    error GemJoin__NotAuthorized();
    error GemJoin__NotLive();
    error GemJoin__Overflow();
    error GemJoin__FailedTransfer();
    error GemJoin__UnsupportedDecimals();

    ///////////////////////////////////////////
    //            Type Declarations          //
    ///////////////////////////////////////////

    /////////////////////////////////////////
    //            State Variables          //
    /////////////////////////////////////////
    // Stores the addresses that have administrative permission in the contract. (0 not authorized, 1 authorized)
    mapping(address => uint256) private s_wards;

    // Vat associated with this Join
    VatLike private immutable i_vat;

    // Id of the Collateral associated with this Join
    bytes32 private immutable i_ilk;

    // Collateral token associated with this Join
    GemLike private immutable i_gem;

    // Decimals of the collateral token associated with this Join
    uint256 private immutable i_dec;

    // Indicates whether the contract is active (1) or shut down (0)
    uint256 private s_live;

    ////////////////////////////////
    //            Events          //
    ////////////////////////////////
    event Rely(address indexed user);
    // Amount is in native token units, matching the tokens transferred.
    event Join(address indexed user, uint256 amount);

    ///////////////////////////////////
    //            Modifiers          //
    ///////////////////////////////////
    // Only authorized addresses (1) can execute this function
    modifier auth() {
        if (s_wards[msg.sender] != 1) {
            revert GemJoin__NotAuthorized();
        }
        _;
    }

    ///////////////////////////////////
    //            Functions          //
    ///////////////////////////////////
    constructor(address vat, bytes32 ilk, address token) {
        // Grants administrative permissions to msg.sender
        s_wards[msg.sender] = 1;
        // Sets the contract as active.
        s_live = 1;
        i_vat = VatLike(vat);
        i_ilk = ilk;
        i_gem = GemLike(token);
        i_dec = i_gem.decimals();
        if (i_dec > 18) {
            revert GemJoin__UnsupportedDecimals();
        }
        emit Rely(msg.sender);
    }

    ////////////////////////////////////////////
    //            External Functions          //
    ////////////////////////////////////////////

    // Deposits ERC-20 collateral into the GemJoin (adapter)
    // and credits the tokens amount in the user collateral balance inside the Vat contract.
    // This is implementation is from join-5.sol: https://github.com/sky-ecosystem/dss-gem-joins/blob/master/src/join-5.sol
    function join(address user, uint256 amount) external {
        // Check that the contract is alive
        if (s_live != 1) {
            revert GemJoin__NotLive();
        }
        // Token transfers use native decimals; Vat collateral uses 18 decimals.
        uint256 wad = amount * (10 ** (18 - i_dec));
        // Check the normalized amount before casting to int256.
        if (wad > uint256(type(int256).max)) {
            revert GemJoin__Overflow();
        }

        // Credit normalized collateral to the user's free Vat balance.
        i_vat.slip(i_ilk, user, int256(wad));

        // The Join contract pulls the tokens from the caller into its own custody.
        if (!i_gem.transferFrom(msg.sender, address(this), amount)) {
            revert GemJoin__FailedTransfer();
        }
        emit Join(user, amount);
    }

    //////////////////////////////////////////////////////
    //      External & Public View & Pure Functions     //
    //////////////////////////////////////////////////////
    function dec() external view returns (uint256) {
        return i_dec;
    }

    function gem() external view returns (GemLike) {
        return i_gem;
    }
}

