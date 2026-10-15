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

interface VatLike {
    function can(address, address) external view returns (uint256);
    function ilks(bytes32) external view returns (uint256, uint256, uint256, uint256, uint256);
    function dai(address) external view returns (uint256);
    function urns(bytes32, address) external view returns (uint256, uint256);
    function frob(bytes32 i, address u, address v, address w, int256 dink, int256 dart) external;
    function hope(address) external;
    function move(address, address, uint256) external;
}

interface GemJoinLike {
    function dec() external view returns (uint256);
    function gem() external view returns (GemLike);
    function join(address, uint256) external payable;
    function exit(address, uint256) external;
}

interface DaiJoinLike {
    function vat() external returns (VatLike);
    function dai() external returns (GemLike);
    function join(address, uint) external payable;
    function exit(address, uint) external;
}

interface JugLike {
    function drip(bytes32) external returns (uint);
}

// Proxy that allows the user to interact with the DSS system
// This is a convienience helper that user can call to perform operation like locking collateral, borrowing Dai and so on...
// without having to call the function needed on the different contract.
// Inspired by https://github.com/sky-ecosystem/dss-proxy-actions/blob/master/src/DssProxyActions.sol
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
    VatLike private immutable i_vat;

    uint256 private constant RAY = 1e27;
    ///////////////////////////////////
    //            Functions          //
    ///////////////////////////////////
    constructor(address vat) {
        if (vat == address(0)) {
            revert DSSProxy__ZeroAddress();
        }
        i_vat = VatLike(vat);
    }

    //////////////////////////////////////////
    //            Public Functions          //
    //////////////////////////////////////////
    // Moves collateral tokens into vat, crediting them to the address urn
    // - adapter: The collateral adapter, which knows which token it accepts.
    // - urn: The address that receives the collateral credit inside the Vat.
    // - amount: The token amount, in the token’s smallest units.
    // - transferFrom: Whether to first pull the tokens from the caller’s wallet.
    function gemJoin_join(address adapter, address urn, uint256 amount, bool transferFrom) public {
        // Only executes for tokens that have approval/transferFrom implementation
        if (transferFrom) {
            // Transfers amount tokens from msg.sender to address(this)
            GemJoinLike(adapter).gem().transferFrom(msg.sender, address(this), amount);
            // Approves the adapter to spend those tokens.
            GemJoinLike(adapter).gem().approve(adapter, amount);
        }
        // Deposits the tokens and credits urn in the Vat.
        GemJoinLike(adapter).join(urn, amount);
    }

    // Takes the ETH sent with the call (msg.value) and deposits it into the Vat as WETH collateral.
    // - adapter: adapter address
    // - urn: is the address credited with the collateral balance  inside the Vat. 
    function ethJoin_join(address adapter, address urn) public payable {
        // Wraps ETH in WETH
        GemJoinLike(adapter).gem().deposit{value: msg.value}();
        // Approves adapter to take the WETH amount
        GemJoinLike(adapter).gem().approve(address(adapter), msg.value);
        // Credits the WETH amount of collateral to the address urn in the Vat.
        GemJoinLike(adapter).join(urn, msg.value);
    }

    ////////////////////////////////////////////
    //            External Functions          //
    ////////////////////////////////////////////

    // takes the ETH sent with the call and locks it as collateral in an existing Vault
    function lockETH(
        bytes32 ilk,
        address ethJoin
    ) external payable {
        // Deposits the ETH into the Vat.
        ethJoin_join(ethJoin, address(this));
        // Locks that collateral in the Vault.
        // - msg.sender: identifies the user’s vault.
        // - address(this): holds the newly deposited free collateral.
        i_vat.frob(
            ilk,
            msg.sender,
            address(this),
            address(this),
            _toInt(msg.value),
            0
        );
    }

    // Deposits (or locks) collateral tokens into an existing vault, without borrowing any DAI.
    // User deposits collateral into its own vault.
    // - gemJoin: the adapter for the collateral token
    // - ilk: collateral Type
    // - amount: Amount to deposit, in the token’s smallest units.
    // - transferFrom: Whether to pull tokens from the caller’s wallet first.
    function lockGem(address gemJoin, bytes32 ilk, uint256 amount, bool transferFrom) external {
        // Takes token amount from user's wallet and joins into the vat
        gemJoin_join(gemJoin, address(this), amount, transferFrom);
        // Locks token amount into the vault
        int256 dink = _toInt(_convertTo18(gemJoin, amount));
        i_vat.frob(ilk, msg.sender, address(this), address(this), dink, 0);
    }

    // Borrows against the caller's existing collateralized vault.
    // - ilk: collateral Type
    // - jug: contract that calculates the new rate
    // - daiJoin: adapter for Dai to borrow
    // - wad: Dai amount to receive
    function draw (
        bytes32 ilk,
        address jug,
        address daiJoin,
        uint256 wad
    ) external {
        // 1. Calculate and generate the required debt
        //  The 0 means no collateral change. The last argument, dart, is the increase in normalized debt.
        int256 dart = _getDrawDart(jug, msg.sender, ilk, wad);
        i_vat.frob(ilk, msg.sender, msg.sender, msg.sender, 0, dart);

        // 2. Move internal Dai to the proxy.
        i_vat.move(msg.sender, address(this), _toRad(wad));

        // 3. Allows adapter to access to proxy's DAI balance in the vat
        if(i_vat.can(address(this), daiJoin) == 0) {
            i_vat.hope(daiJoin);
        }

        // 4. Send ERC-20 Dai to the caller.
        //  DaiJoin takes that internal balance from the proxy, and mints ERC-20 Dai to the user.
        DaiJoinLike(daiJoin).exit(msg.sender, wad);    
    }

    // Deposits ERC-20 collateral and borrows in one call.
    // - ilk: collateral Type
    // - jug: contract that calculates the new rate
    // - gemJoin: adapter for token ERC-20 to deposit
    // - daiJoin: adapter for Dai to borrow
    // - amountCollateral: collateral to deposit in the token's smallest units
    // - wadDai: DAI amount to receive in 18 decimal units
    // - transferFrom: Whether to pull collateral from the caller’s wallet
    function lockGemAndDraw(
        bytes32 ilk,
        address jug,
        address gemJoin,
        address daiJoin,
        uint256 amountCollateral,
        uint256 wadDai,
        bool transferFrom
    ) external {
        // 1. Deposit collateral and credit the caller's free collateral balance in Vat.
        // With transferFrom = true, the helper transfers tokens from the user to the proxy, approves the adapter, and deposits them.
        // With false, the proxy must already hold the tokens and have approved GemJoin.
        gemJoin_join(gemJoin, msg.sender, amountCollateral, transferFrom);

        // 2. Lock the deposited collateral and generate any additional debt needed to receive wadDai.
        int256 dink = _toInt(_convertTo18(gemJoin, amountCollateral));
        int256 dart = _getDrawDart(jug, msg.sender, ilk, wadDai);
        i_vat.frob(ilk, msg.sender, msg.sender, msg.sender, dink, dart);

        // 3. Move internal Dai from msg.sender to the proxy.
        i_vat.move(msg.sender, address(this), _toRad(wadDai));

        // 4. Allows adapter to access to proxy's DAI balance in the vat
        if(i_vat.can(address(this), daiJoin) == 0) {
            i_vat.hope(daiJoin);
        }

        // 5. Send ERC-20 Dai to the caller.
        //  DaiJoin takes that internal balance from the proxy, and mints ERC-20 Dai to the user.
        DaiJoinLike(daiJoin).exit(msg.sender, wadDai);  
    }
    // TODO openLockGemAndDraw(...): also creates the vault. ETH equivalents exist.

    ////////////////////////////////////////////
    //            Internal Functions          //
    ////////////////////////////////////////////

    // Calculates how much normalized debt a vault must add to withdraw wad DAI,
    // accounting for DAI already held by the vault inside the Vat.
    // - wad: DAI requested for withdrawal
    function _getDrawDart (
        address jug,
        address urn,
        bytes32 ilk,
        uint wad
    ) internal returns (int dart) {
        // Updates the stability fee rate
        uint rate = JugLike(jug).drip(ilk);

        // Get the vault's internal DAI balance
        uint256 dai = i_vat.dai(urn);

        // dart stays zero when the existing balance covers the withdrawal.
        if(dai < wad * RAY) {
            // Calculates how much additional normalized debt (dart) is needed to cover the requested DAI withdrawal
            // additional normalized debt (dart) = (requested DAI - existing DAI) / debt multiplier
            dart = _toInt((wad * RAY - dai) / rate);

            // Add one smallest unit of normalized debt for lack of precision.
            // The purpose is to compensate for the previous division rounding down
            dart = uint256(dart) * rate < wad * RAY ? dart + 1 : dart;
        }
    }

    //////////////////////////////////////////////////////
    //     Private & Internal View & Pure Functions     //
    //////////////////////////////////////////////////////
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

    function _toRad(uint wad) internal pure returns (uint rad) {
        rad = wad * RAY;
    }

    //////////////////////////////////////////////////////
    //      External & Public View & Pure Functions     //
    //////////////////////////////////////////////////////
}
