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

import {Math} from "../libraries/Math.sol";

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
    function frob(bytes32, address, address, address, int256, int256) external;
    function hope(address) external;
    function move(address, address, uint256) external;
    function flux(bytes32 ilk, address src, address dst, uint256 wad) external;
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
    function join(address, uint256) external payable;
    function exit(address, uint256) external;
}

interface JugLike {
    function drip(bytes32) external returns (uint256);
}

// Proxy that allows the user to interact with the DSS system
// The caller should call its own vault.
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
    error DSSProxy__EthTransferFailed();

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

    receive() external payable {}

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

    // Converts the ETH sent with the call into WETH and
    // deposits it as free collateral credited to urn in the Vat
    // This function alone does not lock collateral into a vault or borrow Dai.
    // - adapter: adapter address
    // - urn: is the address credited with the collateral balance inside the Vat.
    function ethJoin_join(address adapter, address urn) public payable {
        // Wraps ETH in WETH
        GemJoinLike(adapter).gem().deposit{value: msg.value}();
        // Approves adapter to take the WETH amount
        GemJoinLike(adapter).gem().approve(address(adapter), msg.value);
        // The adapter pulls the WETH from the proxy into its own custody and
        // increases urn's free collateral balance in the Vat.
        GemJoinLike(adapter).join(urn, msg.value);

        // The resulting flow is:
        // Caller's ETH -> WETH held by the proxy -> WETH held by the adapter
        //                                             + free collateral credited to urn in Vat
    }

    // Converts the caller’s ERC-20 DAI into an internal DAI balance in the Vat, credited to urn.
    //  - adapter: the DaiJoin contract handling the conversion.
    //  - urn: the address receiving the internal DAI.
    //  - wad: the DAI amount with 18 decimals;
    function daiJoin_join(address adapter, address urn, uint256 wad) public {
        // Pulls DAI from the user's wallet into the proxy
        DaiJoinLike(adapter).dai().transferFrom(msg.sender, address(this), wad);
        // Approves the adapter to take the DAI amount
        DaiJoinLike(adapter).dai().approve(adapter, wad);
        // Joins DAI into the vat
        // Calls DaiJoin.join, which:
        //   - Transfers wad * RAY internal DAI from the adapter's Vat balance to urn.
        //   - Burns wad ERC-20 Dai from the proxy
        DaiJoinLike(adapter).join(urn, wad);

        // The resulting flow is:
        // Caller's DAI -> DAI held by Proxy --> DAI burned by the proxy
        //                                        + Dai interanl balance to urn in Vat
    }

    ////////////////////////////////////////////
    //            External Functions          //
    ////////////////////////////////////////////

    // Takes the ETH sent with the call, deposits and locks it as collateral in an existing Vault
    function lockETH(bytes32 ilk, address ethJoin) external payable {
        // Deposits the ETH into the Vat.
        ethJoin_join(ethJoin, address(this));
        // Locks that collateral in the Vault.
        // - msg.sender: identifies the user’s vault.
        // - address(this): holds the newly deposited free collateral.
        i_vat.frob(ilk, msg.sender, address(this), address(this), Math.toInt(msg.value), 0);
    }

    // Deposits (or locks) collateral tokens into an existing vault, without borrowing any DAI.
    // User deposits collateral into its own vault.
    // - gemJoin: the adapter for the collateral token
    // - ilk: collateral Type
    // - amount: Amount to deposit, in the token’s smallest units.
    // - transferFrom: Whether to pull tokens from the caller’s wallet first.
    function lockGem(bytes32 ilk, address gemJoin, uint256 amount, bool transferFrom) external {
        // Takes token amount from user's wallet and joins into the vat
        gemJoin_join(gemJoin, address(this), amount, transferFrom);
        // Locks token amount into the vault
        int256 dink = Math.toInt(_convertTo18(gemJoin, amount));
        i_vat.frob(ilk, msg.sender, address(this), address(this), dink, 0);
    }

    // Withdraws ETH that was previously locked as collateral in a Vault.
    // - ethJoin: the adapter holding the WETH collateral.
    // - wad: how much ETH to withdraw, using 18 decimals
    function freeETH(bytes32 ilk, address ethJoin, uint256 wad) external {
        // 1. Unlock collateral in the Vat
        // This reduces the caller’s locked collateral by wad and
        // credits the proxy’s free collateral balance.
        // The final 0 leaves the vault’s debt unchanged.
        i_vat.frob(ilk, msg.sender, address(this), msg.sender, -Math.toInt(wad), 0);

        // 2. Withdraw WETH from the adapter
        // The adapter debits the proxy’s free collateral balance in the Vat and
        // sends WETH tokens to the proxy.
        GemJoinLike(ethJoin).exit(address(this), wad);

        // 3. Converts WETH to ETH
        // WETH burns the proxy’s tokens and sends ETH to the proxy’s receive() function.
        GemJoinLike(ethJoin).gem().withdraw(wad);

        // 4. Send ETH to the caller
        (bool success,) = msg.sender.call{value: wad}("");
        if (!success) {
            revert DSSProxy__EthTransferFailed();
        }
    }

    // Withdraws ERC-20 collateral from a Vault from the caller’s vault and sends the tokens to their wallet.
    // It leaves the vault’s debt unchanged.
    // - ilk: collateral Type identifying the vault.
    // - gemJoin: the adapter holding the collateral tokens
    // - amount: amount to withdraw in tokens native decimals
    function freeGem(bytes32 ilk, address gemJoin, uint256 amount) external {
        // 1. Normalize the amount to 18 decimals.
        uint256 wad = _convertTo18(gemJoin, amount);

        // 2. Unlock collateral inside the vault
        // frob args:
        // - ilk: collateral type
        // - msg.sender (u): select's the caller's vault
        // - address(this) (v): receives the unlocked collateral inside Vat from msg.sender
        // - msg.sender (w): Identifies the internal Dai account; unused here because debt does not change
        // - -wad (dink): reduces the vault's locked collateral
        // - 0 (dart): Leaves normalized debt unchanged
        i_vat.frob(ilk, msg.sender, address(this), msg.sender, -Math.toInt(wad), 0);

        // At this point:
        // - Caller's locked collateral = -wad
        // - Proxy's free collateral: + wad

        // 3. Withdraw actual tokens from the adapter and send them to the user's wallet
        // The adapter subtracts wad from the proxy's free Vat balance and
        // transfers ERC-20 amount to the user.
        GemJoinLike(gemJoin).exit(msg.sender, amount);

        // The complete flow is:
        // user's locked collateral -> proxy's free collateral in Vat -> ERC-20 tokens in suer's wallet
    }

    // Withdraws already unlocked ETH collateral from a Vault and sends it to the caller as native ETH.
    function exitETH(bytes32 ilk, address ethJoin, uint256 wad) public {
        // Moves the amount from the CDP urn to proxy's address
        i_vat.flux(ilk, msg.sender, address(this), wad);

        // Exits WETH amount to proxy address as a token
        GemJoinLike(ethJoin).exit(address(this), wad);
        // Converts WETH to ETH
        GemJoinLike(ethJoin).gem().withdraw(wad);
        // Sends ETH back to the user's wallet
        (bool success,) = msg.sender.call{value: wad}("");
        if (!success) {
            revert DSSProxy__EthTransferFailed();
        }
    }

    // Withdraws alread unlocked ERC-20 collateral from a vault and sends the ERC-20to the caller.
    function exitGem(bytes32 ilk, address gemJoin, uint256 amount) public {
        // 1. Convert the token amount from native decimals to 18 decimals for Vat accounting.
        // 2. Move already unlocked collateral into the proxy’s free Vat balance.
        i_vat.flux(ilk, msg.sender, address(this), _convertTo18(gemJoin, amount));

        // 3. send tokens to the caller.
        GemJoinLike(gemJoin).exit(msg.sender, amount);
    }

    // Borrows against the caller's existing collateralized vault.
    // - ilk: collateral Type
    // - jug: contract that calculates the new rate
    // - daiJoin: adapter for Dai to borrow
    // - wad: Dai amount to receive
    function draw(bytes32 ilk, address jug, address daiJoin, uint256 wad) external {
        // 1. Calculate and generate the required debt
        //  The 0 means no collateral change. The last argument, dart, is the increase in normalized debt.
        int256 dart = _getDrawDart(ilk, jug, msg.sender, wad);
        i_vat.frob(ilk, msg.sender, msg.sender, msg.sender, 0, dart);

        // 2. Move internal Dai to the proxy.
        i_vat.move(msg.sender, address(this), Math.toRad(wad));

        // 3. Allows adapter to access to proxy's DAI balance in the vat
        if (i_vat.can(address(this), daiJoin) == 0) {
            i_vat.hope(daiJoin);
        }

        // 4. Send ERC-20 Dai to the caller.
        //  DaiJoin takes that internal balance from the proxy, and mints ERC-20 Dai to the user.
        DaiJoinLike(daiJoin).exit(msg.sender, wad);
    }

    // Lets the caller deposit and lock ETH as collateral, and receive borrowed DAI
    // - ilk: collateral Type
    // - jug: contract that calculates the new rate
    // - ethJoin: adapter for token ETH to deposit
    // - daiJoin: adapter for Dai to borrow
    // - wadDai: DAI amount to receive in 18 decimal units [wad]
    function lockETHAndDraw(bytes32 ilk, address jug, address ethJoin, address daiJoin, uint256 wadDai) public payable {
        // 1. Receives ETH amount, converts it to WETH and deposit it into the vat
        ethJoin_join(ethJoin, msg.sender);

        // 2. Calculate the additional debt needed
        //  _getDrawDart updates the stability fee through jug.drip and calculates the normalized debt needed to obtain wadDai
        int256 dart = _getDrawDart(ilk, jug, msg.sender, wadDai); // Change in the normalized debt

        // 3. Locks the collateral (WETH) and generate internal DAI
        // Arguments of the frob function:
        // frob(bytes32 i, address u, address v, address w, int256 dink, int256 dart)
        //  - ilk (i): Collateral type
        //  - msg.sender (u): Vault being modified
        //  - msg.sender (v): Account supplying free collateral
        //  - msg.sender (w): Account receiving newly generated internal Dai
        //  - msg.value (dink): Amount of collateral to lock
        //  - dart: normalized debt to add
        i_vat.frob(ilk, msg.sender, msg.sender, msg.sender, Math.toInt(msg.value), dart);

        // 4. Move the requested internal DAI to the proxy
        i_vat.move(msg.sender, address(this), Math.toRad(wadDai));

        // 5. Authorize the DAI adapter
        // Allows daiJoin to spend the proxy’s internal DAI.
        if (i_vat.can(address(this), address(daiJoin)) == 0) {
            i_vat.hope(daiJoin);
        }
        // 5. Send ERC-20 DAI to the caller
        DaiJoinLike(daiJoin).exit(msg.sender, wadDai);
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
        int256 dink = Math.toInt(_convertTo18(gemJoin, amountCollateral));
        int256 dart = _getDrawDart(ilk, jug, msg.sender, wadDai);
        i_vat.frob(ilk, msg.sender, msg.sender, msg.sender, dink, dart);

        // 3. Move internal Dai from msg.sender to the proxy.
        i_vat.move(msg.sender, address(this), Math.toRad(wadDai));

        // 4. Allows adapter to access to proxy's DAI balance in the vat
        if (i_vat.can(address(this), daiJoin) == 0) {
            i_vat.hope(daiJoin);
        }

        // 5. Send ERC-20 Dai to the caller.
        //  DaiJoin takes that internal balance from the proxy, and mints ERC-20 Dai to the user.
        DaiJoinLike(daiJoin).exit(msg.sender, wadDai);
    }

    // Repays a vault's DAI debt without changing its collateral
    // - ilk: collateral Type
    // - daiJoin: the adapter that converts ERC-20 DAI into internal DAI in the Vat.
    // - wad: the amount of DAI to supply, expressed with 18 decimals.
    function wipe(bytes32 ilk, address daiJoin, uint256 wad) external {
        // Pull ERC-20 DAI from the caller and credit their internal Vat balance.
        daiJoin_join(daiJoin, msg.sender, wad);

        // Calculate repayment using the caller's entire internal DAI balance.
        int256 dart = _getWipeDart(ilk, i_vat.dai(msg.sender), msg.sender);

        // Reduce only the caller's debt, spending their internal DAI.
        i_vat.frob(ilk, msg.sender, msg.sender, msg.sender, 0, dart);
    }

    // Repays all debt in the caller’s vault for a given collateral type, leaving its collateral locked.
    function wipeAll(bytes32 ilk, address daiJoin) external {
        // Reads the normalized debt from the caller's vault for the ILK collateral type
        (, uint256 art) = i_vat.urns(ilk, msg.sender);

        // Normalized debt becomes actual Dai through the accumulated rate:
        // debt [rad] = art [wad] × rate [ray]

        // Calculates how much additiona ERC-20 DAI the caller must supply.
        // The helper calculates:
        // missing DAI [rad] = art × rate − caller’s internal DAI
        // required ERC-20 DAI [wad] = ceil(missing DAI / RAY)
        uint256 wad = _getWipeAllWad(ilk, address(i_vat), msg.sender, msg.sender);

        // pulls wad amount of ERC-20 DAI from the caller into the proxy
        // and joins it into the Vat. The caller receives the corresponding internal DAI balance.
        daiJoin_join(daiJoin, msg.sender, wad);

        // msg.sender (u): vault whose debt changes
        // msg.sender (v): collateral account; no change here
        // msg.sender (w): internal DAI account funding repayment
        // 0 (dink): collateral stays unchanged
        // -Math.toInt(art) (dart): remove all normalized debt
        i_vat.frob(ilk, msg.sender, msg.sender, msg.sender, 0, -Math.toInt(art));
    }

    /**
     * @notice Repays DAI and withdraws ETH collateral from the caller's vault.
     * @dev Requires the caller's Vat authorization and ERC-20 DAI approval for this proxy.
     * Uses the caller's existing internal DAI as well as wadDai, capped at the vault's debt.
     * @param ilk Collateral type identifying the caller's vault.
     * @param ethJoin WETH adapter for ilk.
     * @param daiJoin DAI adapter for this Vat.
     * @param wadCollateral ETH collateral to withdraw, with 18 decimals. [wad]
     * @param wadDai ERC-20 DAI to supply, with 18 decimals. [wad]
     */
    function wipeAndFreeETH(bytes32 ilk, address ethJoin, address daiJoin, uint256 wadCollateral, uint256 wadDai)
        external
    {
        // 1. Bring the caller’s DAI into the Vat
        //  daiJoin_join pulls the Dai from the caller into the proxy, and joins it.
        // It then burns the ERC-20 DAI and credits the caller's internal Dai balance in the Vat
        daiJoin_join(daiJoin, msg.sender, wadDai);

        // 2. Calculate how much normalized debt can be repaid
        int256 dart = _getWipeDart(ilk, i_vat.dai(msg.sender), msg.sender);
        // 3. Repay debt and unlock collateral
        // - msg.sender (u)	Modify the caller’s vault
        // - address(this) (v)	Credit unlocked collateral to the proxy’s free collateral balance
        // - msg.sender (w)	Spend the caller’s internal DAI for repayment
        // - -wadCollateral (dink)	Decrease locked collateral
        // - dart	Decrease normalized debt
        i_vat.frob(ilk, msg.sender, address(this), msg.sender, -Math.toInt(wadCollateral), dart);

        // 4. Withdraw WETH and unwrap it
        // exit consumes the proxy’s free collateral balance in the Vat and sends WETH from the adapter to the proxy.
        // withdraw then unwraps that WETH into native ETH
        GemJoinLike(ethJoin).exit(address(this), wadCollateral);
        GemJoinLike(ethJoin).gem().withdraw(wadCollateral);

        // 5. Send the ETH to the caller
        (bool success,) = msg.sender.call{value: wadCollateral}("");
        if (!success) {
            revert DSSProxy__EthTransferFailed();
        }
    }

    /**
     * @notice Repays all debt in the caller's vault and withdraws the requested ETH collateral.
     * @dev Requires the caller's Vat authorization and ERC-20 DAI approval for this proxy.
     * Uses existing internal DAI and rounds any additional ERC-20 DAI needed up to the next wei.
     * @param ilk Collateral type identifying the caller's vault.
     * @param ethJoin WETH adapter for ilk.
     * @param daiJoin DAI adapter for this Vat.
     * @param wadCollateral ETH collateral to withdraw, with 18 decimals. [wad]
     */
    function wipeAllAndFreeETH(bytes32 ilk, address ethJoin, address daiJoin, uint256 wadCollateral) external {
        (, uint256 art) = i_vat.urns(ilk, msg.sender);

        // Join only the additional DAI needed to cover the caller's entire debt.
        uint256 wadDai = _getWipeAllWad(ilk, address(i_vat), msg.sender, msg.sender);
        daiJoin_join(daiJoin, msg.sender, wadDai);

        // Repay all normalized debt and credit unlocked collateral to the proxy.
        i_vat.frob(ilk, msg.sender, address(this), msg.sender, -Math.toInt(wadCollateral), -Math.toInt(art));

        // Withdraw WETH, unwrap it, and send native ETH to the caller.
        GemJoinLike(ethJoin).exit(address(this), wadCollateral);
        GemJoinLike(ethJoin).gem().withdraw(wadCollateral);
        (bool success,) = msg.sender.call{value: wadCollateral}("");
        if (!success) {
            revert DSSProxy__EthTransferFailed();
        }
    }

    /**
     * @notice Repays DAI and withdraws ERC-20 collateral from the caller's vault.
     * @dev Requires the caller's Vat authorization and ERC-20 DAI approval for this proxy.
     * Uses existing internal DAI as well as wadDai, capped at the vault's debt.
     * @param ilk Collateral type identifying the caller's vault.
     * @param gemJoin Collateral adapter for ilk.
     * @param daiJoin DAI adapter for this Vat.
     * @param amountCollateral Collateral to withdraw, in the token's native decimals.
     * @param wadDai ERC-20 DAI to supply, with 18 decimals. [wad]
     */
    function wipeAndFreeGem(bytes32 ilk, address gemJoin, address daiJoin, uint256 amountCollateral, uint256 wadDai)
        external
    {
        daiJoin_join(daiJoin, msg.sender, wadDai);
        uint256 wadCollateral = _convertTo18(gemJoin, amountCollateral);
        int256 dart = _getWipeDart(ilk, i_vat.dai(msg.sender), msg.sender);

        // Repay the caller's debt and credit unlocked collateral to the proxy.
        i_vat.frob(ilk, msg.sender, address(this), msg.sender, -Math.toInt(wadCollateral), dart);

        // Exit using the token's native decimals and send tokens to the caller.
        GemJoinLike(gemJoin).exit(msg.sender, amountCollateral);
    }

    /**
     * @notice Repays all debt in the caller's vault and withdraws the requested ERC-20 collateral.
     * @dev Requires the caller's Vat authorization and ERC-20 DAI approval for this proxy.
     * Uses existing internal DAI and rounds any additional ERC-20 DAI needed up to the next wei.
     * @param ilk Collateral type identifying the caller's vault.
     * @param gemJoin Collateral adapter for ilk.
     * @param daiJoin DAI adapter for this Vat.
     * @param amountCollateral Collateral to withdraw, in the token's native decimals.
     */
    function wipeAllAndFreeGem(bytes32 ilk, address gemJoin, address daiJoin, uint256 amountCollateral) external {
        (, uint256 art) = i_vat.urns(ilk, msg.sender);

        // Join only the additional DAI needed to cover the caller's entire debt.
        uint256 wadDai = _getWipeAllWad(ilk, address(i_vat), msg.sender, msg.sender);
        daiJoin_join(daiJoin, msg.sender, wadDai);
        uint256 wadCollateral = _convertTo18(gemJoin, amountCollateral);

        // Repay all normalized debt and credit unlocked collateral to the proxy.
        i_vat.frob(ilk, msg.sender, address(this), msg.sender, -Math.toInt(wadCollateral), -Math.toInt(art));

        // Exit using the token's native decimals and send tokens to the caller.
        GemJoinLike(gemJoin).exit(msg.sender, amountCollateral);
    }

    ////////////////////////////////////////////
    //            Internal Functions          //
    ////////////////////////////////////////////

    // Calculates how much normalized debt a vault must add to withdraw wad DAI,
    // accounting for DAI already held by the vault inside the Vat.
    // - wad: DAI requested for withdrawal [wad]
    function _getDrawDart(bytes32 ilk, address jug, address urn, uint256 wad) internal returns (int256 dart) {
        // Updates the stability fee rate
        uint256 rate = JugLike(jug).drip(ilk);

        // Get the vault's internal DAI balance
        uint256 dai = i_vat.dai(urn);

        // dart stays zero when the existing balance covers the withdrawal.
        if (dai < wad * RAY) {
            // Calculates how much additional normalized debt (dart) is needed to cover the requested DAI withdrawal
            // additional normalized debt (dart) = (requested DAI - existing DAI) / debt multiplier
            dart = Math.toInt((wad * RAY - dai) / rate);

            // Add one smallest unit of normalized debt for lack of precision.
            // The purpose is to compensate for the previous division rounding down
            dart = uint256(dart) * rate < wad * RAY ? dart + 1 : dart;
        }
    }

    // Calculates how much a Vault's normalized debt can be reduced using a given
    // amount of internal DAI
    // - dai: interanl DAI available for repayment, supplied by the caller [rad]
    // - urn: the urn address
    function _getWipeDart(bytes32 ilk, uint256 dai, address urn) internal view returns (int256 dart) {
        // Gets actual rate from the vat
        (, uint256 rate,,,) = VatLike(i_vat).ilks(ilk); // multiplier
        // Get the actual art value of the urn
        (, uint256 art) = VatLike(i_vat).urns(ilk, urn); // art = vault's normalized debt

        // A Vault's DAI debt is normalized debt * rate
        // So:
        // dai = art * rate -> normalized debt = Dai / rate -> art = Dai / rate

        // Let's calculate how much normalized debt the supplied Dai can cover:
        dart = Math.toInt(dai / rate);

        // Caps the reduction at the Vault's outstanding debt,
        // then it makes it negative because frob applies
        // new art = old art + dart
        dart = uint256(dart) <= art ? -dart : -Math.toInt(art);
    }

    // Calculates how much additional ERC-20 DAI is needed to repay a vault’s entire debt,
    // accounting for DAI already available inside the Vat.
    // - art: the vault's normalized debt
    // - rate: the accumulated debt multiplier
    // - dai: the internal Dai balance belonging to the user
    // - urn: the address identifying the vault whose debt you want to repay. vat.urns(ilk, urn)
    // - user: the address holding the internal Vat DAI available for repayment. vat.dai(user)
    function _getWipeAllWad(bytes32 ilk, address vat, address user, address urn) internal view returns (uint256 wad) {
        // Gets actual rate from the vat
        (, uint256 rate,,,) = VatLike(vat).ilks(ilk);
        // Gets actual art value of the urn
        (, uint256 art) = VatLike(vat).urns(ilk, urn);
        // Gets actual dai amount in the urn
        uint256 dai = VatLike(vat).dai(user);

        // art * rate gives the vault's total debt in rad,
        // subtracting the existing internal DAI balance gives the amount still needed
        uint256 debt = art * rate;
        if (dai >= debt) return 0;
        uint256 rad = debt - dai;
        wad = rad / RAY; // Converting rad into wad

        // If the division discarded a remainder, this adds one wei of DAI so the repayment fully covers the debt.
        wad = wad * RAY < rad ? wad + 1 : wad;
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

    //////////////////////////////////////////////////////
    //      External & Public View & Pure Functions     //
    //////////////////////////////////////////////////////
}
