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
    function approve(address, uint256) external;
    function transfer(address, uint256) external;
    function transferFrom(address, address, uint256) external;
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface GemJoinLike {
    function dec() external view returns (uint256);
    function gem() external view returns (GemLike);
    function join(address, uint256) external payable;
    function exit(address, uint256) external;
}

interface VatLike {
    function can(address, address) external view returns (uint256);
    function ilks(bytes32) external view returns (uint256, uint256, uint256, uint256, uint256);
    function dai(address) external view returns (uint256);
    function urns(bytes32, address) external view returns (uint256, uint256);
    function frob(bytes32 i, address u, address v, address w, int256 dink, int256 dart) external;
    function hope(address) external;
    function move(address, address, uint256) external;
}

// Proxy that allows the user to interact with the DSS system
contract DSSProxy {
    ////////////////////////////////
    //            Errors          //
    ////////////////////////////////    
    error DSSProxy__ZeroAddress();
    error DSSProxy__Overflow();
    error DSSProxy__UnsupportedDecimals();

    /////////////////////////////////////////
    //            State Variables          //
    /////////////////////////////////////////

    address private immutable i_vat;

    ///////////////////////////////////
    //            Functions          //
    ///////////////////////////////////
    constructor(address vat) {
        if (vat == address(0)) {
            revert DSSProxy__ZeroAddress();
        }
        i_vat = vat;
    }

    ////////////////////////////////////////////
    //            Public Functions          //
    ////////////////////////////////////////////
    function gemJoin_join(address adapter, address urn, uint256 amount, bool transferFrom) public {
        // Only executes for tokens that have approval/transferFrom implementation
        if (transferFrom) {
            // Gets token from the user's wallet
            GemJoinLike(adapter).gem().transferFrom(msg.sender, address(this), amount);
            // Approves adapter to take the token amount
            GemJoinLike(adapter).gem().approve(adapter, amount);
        }
        // Joins token collateral into the vat
        GemJoinLike(adapter).join(urn, amount);
    }

    function lockGem(address gemJoin, bytes32 collateral, address vault, uint256 amount, bool transferFrom) public {
        int256 dink = _toInt(_convertTo18(gemJoin, amount));
        // Takes token amount from user's wallet and joins into the vat
        gemJoin_join(gemJoin, address(this), amount, transferFrom);
        // Locks token amount into the CDP
        VatLike(i_vat).frob(collateral, vault, address(this), address(this), dink, 0);
    }

    ////////////////////////////////////////////
    //            Internal Functions          //
    ////////////////////////////////////////////

    function _convertTo18(address adapter, uint256 amount) internal view returns (uint256) {
        uint256 decimals = GemJoinLike(adapter).dec();
        if (decimals > 18) {
            revert DSSProxy__UnsupportedDecimals();
        }
        return amount * (10 ** (18 - decimals));
    }

    function _toInt(uint256 amount) internal pure returns (int256) {
        if (amount > uint256(type(int256).max)) {
            revert DSSProxy__Overflow();
        }
        return int256(amount);
    }
}
