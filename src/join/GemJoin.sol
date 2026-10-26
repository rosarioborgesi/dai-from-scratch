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
    mapping(address user => uint256 auth) private s_wards;

    // Vat associated with this Join
    VatLike private immutable i_vat;

    // Collateral type associated with this Join
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
    event Deny(address indexed user);
    // Amount is in native token units, matching the tokens transferred.
    event Join(address indexed user, uint256 amount);
    event Exit(address indexed user, uint256 amount);
    event Cage();

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

    modifier isGemJoinAlive() {
        // Check that the contract is alive
        if (s_live != 1) {
            revert GemJoin__NotLive();
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
    // Grants administrative permissions to the user
    function rely(address user) external auth {
        s_wards[user] = 1;
        emit Rely(user);
    }

    // Revokes administrative permissions to the user
    function deny(address user) external auth {
        s_wards[user] = 0;
        emit Deny(user);
    }

    // Freezes this contract
    function cage() external auth {
        s_live = 0;
        emit Cage();
    }

    // Deposits ERC-20 collateral into the GemJoin (adapter)
    // and credits the tokens amount in the user free collateral balance inside the Vat contract.
    // This is implementation is from join-5.sol: https://github.com/sky-ecosystem/dss-gem-joins/blob/master/src/join-5.sol
    // - user: is the address whose free collateral balance in the Vat gets credited.
    // - amount is the amount deposited in the token's native units.
    //      The adapter converts it to 18-decimal units before crediting the Vat.
    function join(address user, uint256 amount) external isGemJoinAlive {
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

    // Withdraws collateral tokens (amount) from the adapter and sends them to user.
    // This is implementation is from join-5.sol: https://github.com/sky-ecosystem/dss-gem-joins/blob/master/src/join-5.sol
    function exit(address user, uint256 amount) external {
        // COnvert amount into 18-decimals
        uint256 wad = amount * (10 ** (18 - i_dec));
        // Check that the conversion from uint256 to int256 is safe
        if (wad > uint256(type(int256).max)) {
            revert GemJoin__Overflow();
        }
        // This subtracts wad from msg.sender’s free collateral for i_ilk.
        // The recipient can be a different address.
        i_vat.slip(i_ilk, msg.sender, -int256(wad));

        // The adapter sends amount ERC-20 tokens from its custody to user.
        if (!i_gem.transfer(user, amount)) {
            revert GemJoin__FailedTransfer();
        }
        emit Exit(user, amount);
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