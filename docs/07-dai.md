# Dai

The [Dai contract](../src/Dai.sol) represents the transferable ERC20 token used outside the Vat. It tracks balances, allowances, and the total token supply. Dai has 18 decimals, so `1e18` units represent 1 Dai; amounts named `wad` use this scale.

The Vat maintains the protocol's internal accounting, including internal Dai balances. The token contract does not manage Vaults, calculate stability fees, or enforce collateral requirements. Those responsibilities belong to other modules.

[DaiJoin](../src/join/DaiJoin.sol) connects the two representations:

- `exit(user, wad)` moves internal Dai from the caller to the adapter and mints ERC20 Dai to `user`.
- `join(user, wad)` burns ERC20 Dai from the caller and moves internal Dai from the adapter to `user`.

The Vat uses `rad` precision (`1e45`), so DaiJoin multiplies the token amount by `RAY` (`1e27`) when moving internal Dai. This conversion moves value between the two representations without creating additional Vault debt.

## Differences from the original

I implemented Dai by inheriting from OpenZeppelin's `ERC20` and `EIP712` contracts, together with the shared `Auth` contract. The [original Dai contract](https://github.com/sky-ecosystem/dss/blob/master/src/dai.sol) implements token accounting, authorization, and EIP712 hashing directly.

The main implementation changes are:

- **ERC20 inheritance:** OpenZeppelin provides `transfer`, `transferFrom`, `approve`, balances, allowances, and supply accounting. Dai adds its minting, burning, and signature approval logic.
- **Checked arithmetic:** Solidity 0.8.35 checks ordinary arithmetic for overflow and underflow, so the original `add` and `sub` helpers are unnecessary. OpenZeppelin also uses explicit checks and some `unchecked` arithmetic where its accounting guarantees safety.
- **Shared authorization:** `Auth` provides `wards`, `rely`, `deny`, and the `auth` modifier. The deployer starts authorized. This implementation also emits `Rely` and `Deny` events.
- **EIP712 and signature recovery:** OpenZeppelin constructs the signing domain and message digest. `ECDSA.tryRecover` validates signatures, including rejecting high-`s` signatures that the original direct `ecrecover` call accepts.
- **Custom errors:** Failures use custom errors from Dai or OpenZeppelin instead of the original revert strings.

These choices also introduce observable compatibility differences:

| Area | Original Dai | This implementation |
| --- | --- | --- |
| `transferFrom` on your own balance | Does not require allowance | Requires allowance even when the caller is `from`; use `transfer` for ordinary transfers of your own tokens |
| Zero addresses | Allows transfers and minting to zero, and approval of a zero spender | Rejects those operations through OpenZeppelin's checks |
| Convenience transfers | Provides `push`, `pull`, and `move` aliases | Omits these aliases |
| Signing domain | Stores a separator built with the constructor's supplied chain ID | Uses `block.chainid` and rebuilds the separator if the chain ID changes |
| Public helpers | Exposes `version()` and `PERMIT_TYPEHASH()` | Uses domain version `"1"` internally, exposes `getPermitTypeHash()` and `getPermitDigest()`, and inherits `eip712Domain()` |

The core design is preserved, but callers should account for these interface and behavior differences.

## Important functions

### `mint(user, wad)`

Creates tokens for `user` and increases `totalSupply`. Only an authorized address can call it. OpenZeppelin's `_mint` updates the accounting and emits a `Transfer` event from the zero address.

In the protocol setup, DaiJoin must be authorized to mint when users exit internal Dai. `mint` itself does not check collateral or Vat balances; the surrounding protocol determines when minting is valid.

### `burn(user, wad)`

Destroys tokens from `user` and reduces `totalSupply`. Unlike `mint`, it does not require administrative authorization:

- A holder can burn their own tokens without allowance.
- Another caller must have sufficient allowance from the holder.
- A finite allowance decreases by the burned amount; unlimited allowance remains unchanged.

OpenZeppelin's `_burn` checks the balance and emits a `Transfer` event to the zero address. This lets DaiJoin burn a caller's tokens after receiving approval. Calling `burn` directly only destroys tokens; it does not credit internal Dai or repay Vault debt.

### `permit(holder, spender, nonce, expiry, allowed, v, r, s)`

`permit` lets a holder approve a spender by signing a message off-chain. Any address, including a separate relayer, can submit that signature and pay the transaction gas. The holder does not need to send an approval transaction.

The flow is:

1. The holder signs the spender, current nonce, expiry, and `allowed` value using the contract's EIP712 domain.
2. A relayer submits those values and the signature to `permit`.
3. The contract verifies the holder's signature, checks the expiry and nonce, then increments the holder's nonce.
4. It sets the spender's allowance and emits `Approval`.

The relayer submits the approval; the signed `spender` receives it. The relayer cannot change the signed fields and still use the same signature.

This preserves the **Dai-style permit**, which uses a boolean approval rather than an exact amount:

- `allowed = true` sets allowance to `type(uint256).max` (unlimited).
- `allowed = false` sets allowance to zero, revoking the current approval.

It therefore has a different interface and signed message from the amount-based EIP-2612 permit implemented by OpenZeppelin's `ERC20Permit`. That is why this contract inherits `EIP712` and implements `permit` itself.

`expiry = 0` means there is no submission deadline. Otherwise, the permit can be submitted up to and including `expiry`. **Expiry limits when the signature can be submitted; it does not make the resulting allowance expire.**

Each successful permit consumes one nonce belonging to the holder, shared across all spenders. Reusing a signature fails because its nonce is no longer current. The signing domain includes the chain ID and contract address, tying the signature to that domain.

`permit` only changes allowance. It does not transfer or burn tokens; the approved spender performs those actions separately.

### Signing and authorization helpers

- `getPermitDigest(...)` returns the EIP712 digest to sign. Internally, `_getPermitHashStruct` hashes the permit fields, and `_hashTypedDataV4` combines that hash with the domain separator.
- `_isValidSignature(...)` recovers the signer using `ECDSA.tryRecover` and compares it with the holder.
- `nonces(holder)`, `DOMAIN_SEPARATOR()`, and `getPermitTypeHash()` expose the values needed to construct and inspect permits.
- The inherited `rely(user)` and `deny(user)` functions grant and revoke administrative authorization. This is separate from ERC20 allowance: authorization controls minting and permission management, while allowance lets a spender transfer or burn a holder's tokens.

## Permit example in the tests

See [`test_Permit_ValidSignatureApprovesThroughRelayer`](../test/unit/DaiUnitTest.t.sol). The holder signs a permit for the spender, and a separate relayer submits it. The test checks that the spender receives unlimited allowance, the holder's nonce advances from zero to one, and the relayer receives no allowance.

The same test file covers revocation, successive nonces, expiry, replay rejection, incorrect signers, and changes to signed fields.
