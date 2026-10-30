# Join

Join adapters are the **bridge between tokens in your wallet and balances recorded inside the Vat**.

The [Vat](../src/Vat.sol) is the system's accounting engine: it tracks collateral and Dai as numbers in its own storage. Adapters handle the actual token transfers needed to back those numbers.

The adapter types are:

- **GemJoin**: deposits and withdraws ERC-20 collateral.
- **DaiJoin**: converts between internal Dai balances and ERC-20 Dai tokens.

This project implements [GemJoin](../src/join/GemJoin.sol) and [DaiJoin](../src/join/DaiJoin.sol); it has no separate ETHJoin implementation. Each adapter has logic specific to the asset it handles.

## GemJoin: collateral deposits and withdrawals

Each GemJoin is permanently associated with:

| Field | Meaning |
|---|---|
| `i_vat` | The Vat whose collateral balances it updates. |
| `i_ilk` | The collateral type identifier, such as `ETH-A`. |
| `i_gem` | The ERC-20 collateral token. |
| `i_dec` | The token's number of decimals. |

The adapter holds the real tokens while the Vat records who owns the corresponding internal collateral balances. GemJoin must be authorized in the Vat because it calls the privileged `slip()` function.

### `join(address user, uint256 amount)`

Deposits collateral into the system:

1. Converts `amount` from the token's native decimals into the Vat's 18-decimal format.
2. Calls `vat.slip(ilk, user, wad)` to increase `user`'s **free collateral** balance.
3. Transfers `amount` tokens from `msg.sender` into the adapter.

The caller must first approve GemJoin to spend their tokens. The caller supplies the tokens, but `user` receives the internal credit, so you can deposit for another address.

The conversion is:

```solidity
uint256 wad = amount * (10 ** (18 - i_dec));
```

For example, depositing one token with 6 decimals means passing `1e6`; the Vat receives a collateral credit of `1e18`. The constructor rejects tokens with more than 18 decimals, and the function checks that the normalized amount fits into the signed integer used by `slip()`.

**Depositing does not lock collateral into a Vault or borrow Dai.** Those are separate operations handled through the Vat, principally `frob()`.

### `exit(address user, uint256 amount)`

Withdraws collateral from the system:

1. Converts `amount` into the Vat's 18-decimal format.
2. Calls `vat.slip(ilk, msg.sender, -wad)` to decrease **the caller's** free collateral balance.
3. Transfers `amount` tokens from the adapter to `user`.

The recipient can differ from the caller, but the caller's internal balance pays for the withdrawal. Collateral locked in a Vault must first be unlocked, subject to the Vat's rules.

For both `join()` and `exit()`, a failed token transfer reverts the entire transaction, including the Vat balance change. This adapter assumes ordinary ERC-20 transfer behavior: the amount transferred must match the amount credited or debited.

For example, using readable token amounts:

| Operation | User's free collateral in Vat | Collateral locked in Vault | Tokens held by adapter |
|---|---:|---:|---:|
| Deposit 3 tokens through `join()` | 3 | 0 | 3 |
| Lock 2 through `Vat.frob()` | 1 | 2 | 3 |
| Unlock 1 through `Vat.frob()` | 2 | 1 | 3 |
| Withdraw 2 through `exit()` | 0 | 1 | 1 |

## DaiJoin: internal Dai and wallet tokens

Dai exists in two forms:

| Form | Where it lives | Precision |
|---|---|---|
| Internal Dai | Vat accounting | 45 decimals, called `rad` |
| ERC-20 Dai | Wallet token balances | 18 decimals, called `wad` |

DaiJoin converts between these representations using the scaling constant `RAY = 1e27`:

```solidity
rad = wad * RAY;
```

For example, 1 Dai is represented as `1e18` ERC-20 units or `1e45` internal Vat units.

### `exit(address user, uint256 wad)`

Turns internal Dai into wallet tokens:

1. Calls `vat.move(msg.sender, address(this), RAY * wad)` to move internal Dai from the caller into DaiJoin's Vat balance.
2. Calls `dai.mint(user, wad)` to mint ERC-20 Dai to the recipient.

The caller must authorize DaiJoin to move their internal Dai through `vat.hope(address(daiJoin))`. DaiJoin must also have minting permission on the Dai token.

For example, after borrowing 100 internal Dai, calling `exit(yourAddress, 100e18)` produces 100 Dai in your wallet.

This does not create additional Vault debt. It moves existing internal Dai into the adapter and issues its external token representation. The internal Dai held by DaiJoin backs the tokens it issues.

### `join(address user, uint256 wad)`

Turns wallet tokens back into internal Dai:

1. Calls `vat.move(address(this), user, RAY * wad)` to move internal Dai from DaiJoin's balance to the recipient.
2. Calls `dai.burn(msg.sender, wad)` to burn ERC-20 Dai from the caller.

The caller must approve DaiJoin to burn their Dai through the token's allowance mechanism. The caller supplies the tokens, while `user` receives the internal Dai credit.

The internal Dai held by the adapter when tokens were issued supplies the balance released when those tokens are burned. Both steps happen atomically: a failed burn also reverts the internal transfer.

**Joining Dai does not automatically repay a Vault's debt.** It makes internal Dai available for a separate repayment operation through the Vat.

For example, assuming a debt multiplier of 1 and using readable Dai amounts:

| Operation | User's internal Dai | User's wallet Dai | Vault debt |
|---|---:|---:|---:|
| Borrow 100 through `Vat.frob()` | 100 | 0 | 100 |
| Exit 100 through `DaiJoin.exit()` | 0 | 100 | 100 |
| Join 40 through `DaiJoin.join()` | 40 | 60 | 100 |
| Repay 40 through `Vat.frob()` | 0 | 60 | 60 |

## Administrative functions and shutdown

Both adapters inherit administrative functions from [Auth](../src/Auth.sol) and shutdown behavior from [Shutdown](../src/Shutdown.sol):

- `rely(address user)` grants administrative access.
- `deny(address user)` removes administrative access.
- `cage()` irreversibly shuts down that adapter by setting its `live` flag to `0`.
- `live()` reports whether the adapter is active (`1`) or shut down (`0`).

Only authorized administrators can call `rely()`, `deny()`, or `cage()`. Ordinary users can call `join()` and `exit()`, subject to balances, permissions, and shutdown checks.

Shutdown blocks one direction of conversion for each adapter:

| Adapter | Blocked after `cage()` | Still available |
|---|---|---|
| GemJoin | `join()` — deposit collateral | `exit()` — withdraw free collateral |
| DaiJoin | `exit()` — mint external Dai | `join()` — burn external Dai for internal credit |

The remaining operations still require sufficient balances and the usual permissions. Each adapter has its own shutdown flag; calling its `cage()` does not itself shut down the Vat or other adapters.

GemJoin holds collateral tokens and adjusts collateral accounting. DaiJoin mints or burns Dai tokens while moving existing internal Dai balances.
