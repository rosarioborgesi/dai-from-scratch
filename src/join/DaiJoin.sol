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

contract DaiJoin {
    ////////////////////////////////
    //            Errors          //
    ////////////////////////////////
    error DaiJoin__NotAuthorized();
    error DaiJoin__NotLive();

    ///////////////////////////////////////////
    //            Type Declarations          //
    ///////////////////////////////////////////

    /////////////////////////////////////////
    //            State Variables          //
    /////////////////////////////////////////
    // Stores the addresses that have administrative permission in the contract. (0 not authorized, 1 authorized)
    mapping(address user => uint256 auth) private s_wards;

    // Vat associated with this join
    VatLike private immutable i_vat;

    // Dai token associated with this join
    DSTokenLike private immutable i_dai;

    // Indicates whether the contract is active (1) or shut down (0)
    uint256 private s_live;

    uint256 private constant ONE = 1e27;

    ////////////////////////////////
    //            Events          //
    ////////////////////////////////
    event Rely(address indexed user);
    event Deny(address indexed user);
    event Join(address indexed usr, uint256 wad);
    event Exit(address indexed user, uint256 wad);
    event Cage();

    ///////////////////////////////////
    //            Modifiers          //
    ///////////////////////////////////
    modifier auth() {
        if (s_wards[msg.sender] != 1) {
            revert DaiJoin__NotAuthorized();
        }
        _;
    }

    modifier isDaiJoinAlive() {
        if (s_live != 1) {
            revert DaiJoin__NotLive();
        }
        _;
    }

    ///////////////////////////////////
    //            Functions          //
    ///////////////////////////////////
    constructor(address vat, address dai) {
        // Gives administrative permissions to msg.sender
        s_wards[msg.sender] = 1;
        // Sets the contract as active
        s_live = 1;
        // Initializes the Vat
        i_vat = VatLike(vat);
        // Initializes the Dai token
        i_dai = DSTokenLike(dai);
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

    // Converts external Dai into an internal Dai balance
    function join(address user, uint256 wad) external {
        // Moves internal Dai from the adapter to user
        i_vat.move(address(this), user, ONE * wad);
        // Burns external Dai units from msg.sender
        i_dai.burn(msg.sender, wad);
        emit Join(user, wad);
    }

    // Converts the the caller's internal Dai balance in the Vat into external Dai tokens.
    function exit(address user, uint256 wad) external isDaiJoinAlive {
        // Moves internal Dai from the caller's into the adapter
        i_vat.move(msg.sender, address(this), ONE * wad);
        // Mints external Dai to the user.
        i_dai.mint(user, wad);
        emit Exit(user, wad);
    }

    //////////////////////////////////////////////////////
    //      External & Public View & Pure Functions     //
    //////////////////////////////////////////////////////
    function dai() external view returns (DSTokenLike) {
        return i_dai;
    }
}

