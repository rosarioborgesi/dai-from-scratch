# User Operations in Multi-Collateral Dai

This guide describes the main user operations in the reference DSS protocol and the contracts and functions involved.

The main operations are depositing collateral, borrowing Dai, repaying debt, withdrawing collateral, and earning savings interest. Users can also participate in liquidations and auctions.

## 1. Before starting: tokens and internal balances

**ERC-20 tokens in a wallet and balances inside `Vat` are separate representations.** Adapters connect them:

- `GemJoin` connects a collateral token to internal collateral accounting.
- `DaiJoin` connects ERC-20 Dai to internal Dai accounting.
- `Vat` records free collateral, locked collateral, normalized debt, and internal Dai.

These sequences assume direct interaction from the user's address. A proxy or router can combine calls into one transaction, but must handle the corresponding ownership and permissions.

### Notation and units

| Name | Meaning | Unit |
| --- | --- | --- |
| `user` | Address operating its own vault and balances in these examples | address |
| `recipient` | Address receiving tokens or internal collateral | address |
| `ilk` | Identifier of a collateral type and its risk configuration | bytes32 |
| `amount` | Collateral quantity; examples assume an 18-decimal token and compatible adapter | wad |
| `daiAmount` | ERC-20 Dai quantity | wad |
| `dart` | Magnitude of a change in normalized debt | wad |
| `art` | A vault's current normalized debt | wad |
| `rate` | Accumulated debt multiplier for an ilk | ray |
| `pieAmount` | Normalized savings quantity | wad |
| `chi` | Accumulated savings multiplier | ray |

A wad has 18 decimals, a ray has 27, and a rad has 45. Internal Dai balances use rad. Amounts passed to contracts are scaled integers, not human-readable decimals.

Positive and negative amounts in the tables are conceptual signed deltas. In Solidity, construct those deltas with explicit range checks before converting unsigned amounts to signed integers.

## 2. Deposit and lock collateral

Depositing collateral and locking it in a vault are two separate steps.

| Step | Contract | Function | Effect |
| --- | --- | --- | --- |
| 1 | Collateral ERC-20 | `approve(gemJoin, amount)` | Allows the adapter to transfer your tokens |
| 2 | `GemJoin` | `join(user, amount)` | Transfers tokens into the adapter and credits free collateral in Vat |
| 3 | `Vat` | `frob(ilk, user, user, user, +amount, 0)` | Moves free collateral into your vault |

There is no separate **open vault** function in Vat. A core vault is identified by `(ilk, user)` and is populated when first modified. The ilk must already have been initialized and configured by authorized actors.

Tokens remain in the adapter while Vat records how their corresponding collateral is allocated. The basic reference GemJoin does not automatically normalize arbitrary token decimals; other tokens may require a different adapter.

## 3. Borrow Dai

Borrowing creates vault debt and internal Dai. A subsequent adapter call produces transferable wallet tokens.

| Step | Contract | Function | Effect |
| --- | --- | --- | --- |
| 1 | `Jug` | `drip(ilk)` | Updates accumulated borrowing fees for the collateral type |
| 2 | `Vat` | `frob(ilk, user, user, user, 0, +dart)` | Increases normalized debt and credits internal Dai |
| 3 | `Vat` | `hope(daiJoin)` | Authorizes DaiJoin to move your internal Dai |
| 4 | `DaiJoin` | `exit(recipient, daiAmount)` | Moves internal Dai to the adapter and mints ERC-20 Dai to the recipient |

`hope` is normally needed only once, until revoked using `nope`. Vat does not call Jug automatically; the caller or integration is responsible for updating the rate when fresh accounting is required.

**The normalized debt delta is not the requested token amount.**

```text
Internal Dai created [rad] = dart [wad] × rate [ray]
Internal Dai needed for exit [rad] = daiAmount [wad] × 10^27
```

After updating the rate, select a normalized debt delta that produces enough internal Dai for the desired withdrawal, accounting for any existing internal balance and rounding.

Locking collateral and borrowing can be combined into one `frob` call by supplying positive `dink` and positive `dart`. Vat checks safety, debt ceilings, permissions, and the minimum nonzero debt requirement.

## 4. Repay debt

Repayment converts wallet Dai into internal Dai, then consumes that internal Dai to reduce vault debt.

| Step | Contract | Function | Effect |
| --- | --- | --- | --- |
| 1 | `Jug` | `drip(ilk)` | Updates the debt rate |
| 2 | Dai ERC-20 | `approve(daiJoin, daiAmount)` | Allows DaiJoin to burn your tokens |
| 3 | `DaiJoin` | `join(user, daiAmount)` | Burns ERC-20 Dai and credits internal Dai |
| 4 | `Vat` | `frob(ilk, user, user, user, 0, -dart)` | Reduces normalized debt and consumes internal Dai |

For full repayment, the magnitude of the negative debt delta equals the vault's entire `art`:

```text
Internal Dai required [rad] = art × rate
```

If the user has no existing internal Dai, the token amount required is:

```text
daiAmount [wad] = ceil((art × rate) / 10^27)
```

Round up to cover the complete internal amount. A small internal Dai remainder may remain. If transactions occur separately and another rate update happens before repayment, recompute the required amount or use an atomic integration.

Partial repayment is allowed, but remaining debt must be either zero or at least the collateral type's `dust` threshold.

**Calling DaiJoin.join alone does not repay a vault.** The final `frob` performs the repayment. Users who already hold sufficient internal Dai can skip the token conversion steps.

## 5. Withdraw collateral

| Step | Contract | Function | Effect |
| --- | --- | --- | --- |
| 1 | `Vat` | `frob(ilk, user, user, user, -amount, 0)` | Unlocks collateral into your free internal balance |
| 2 | `GemJoin` | `exit(recipient, amount)` | Debits that balance and transfers collateral tokens to the recipient |

If debt remains, the vault must remain safe after withdrawal. Users can withdraw excess collateral without repaying the entire debt.

Repayment and unlocking can be combined into one `frob` using negative `dart` and negative `dink`. Already-free collateral needs only the adapter's `exit` call.

## 6. Deposit Dai into savings

The savings contract, `Pot`, accepts internal Dai. Its `join` argument is a **normalized savings quantity**, not an ordinary Dai deposit amount.

| Step | Contract | Function | Effect |
| --- | --- | --- | --- |
| 1 | Dai ERC-20 | `approve(daiJoin, daiAmount)` | Allows conversion into internal Dai |
| 2 | `DaiJoin` | `join(user, daiAmount)` | Credits internal Dai |
| 3 | `Pot` | `drip()` | Updates the savings accumulator, chi |
| 4 | `Vat` | `hope(pot)` | Allows Pot to move your internal Dai |
| 5 | `Pot` | `join(pieAmount)` | Deposits internal Dai and credits normalized savings |

```text
Internal Dai deposited [rad] = pieAmount [wad] × chi [ray]
pieAmount = floor(internal Dai available / chi)
```

Rounding down avoids depositing more internal Dai than is available. Any remainder stays in the user's internal balance.

`Pot.join` requires the accumulator to have been updated at the current block timestamp. Merely sending separate transactions in this order does not guarantee that condition. A router or proxy can call `drip` and `join` atomically, with ownership and permissions configured for the calling address.

## 7. Withdraw savings and interest

| Step | Contract | Function | Effect |
| --- | --- | --- | --- |
| 1 | `Pot` | `drip()` | Updates accrued savings |
| 2 | `Pot` | `exit(pieAmount)` | Returns pieAmount × chi internal Dai |
| 3 | `Vat` | `hope(daiJoin)` | Grants permission if not already given |
| 4 | `DaiJoin` | `exit(recipient, daiAmount)` | Converts available internal Dai into wallet Dai |

To withdraw all normalized savings, use the full `Pot.pie(user)` balance. Determine the exportable token amount from the resulting internal Dai balance:

```text
daiAmount [wad] = floor(internal Dai available [rad] / 10^27)
```

Token conversion may leave a small internal remainder. Pot records savings shares internally; the reference Pot does not itself issue a transferable savings-share token.

## 8. Participate in liquidation

Automated keepers commonly perform these actions, but ordinary addresses can call them too.

| Operation | Contract | Function |
| --- | --- | --- |
| Refresh the safety-adjusted oracle price | `Spotter` | `poke(ilk)` |
| Trigger liquidation of an unsafe vault | `Dog` | `bark(ilk, vaultAddress, incentiveRecipient)` |
| Buy auctioned collateral | `Clipper` | `take(id, amount, maxPrice, recipient, data)` |
| Reset an auction when its reset conditions are met | `Clipper` | `redo(id, incentiveRecipient)` |

These are the **Liquidation 2.0** contracts. The reference repository also contains the older Cat/Flipper mechanism.

### Triggering a liquidation

Calling `bark` does not require the vault owner's approval. Dog checks that the vault is unsafe, the safety price is positive, and liquidation capacity and other conditions permit an auction. A caller cannot liquidate an arbitrary healthy vault.

`Spotter.poke` reads the configured oracle; it does not let a user supply an arbitrary price.

### Buying collateral

For a straightforward purchase:

1. Obtain internal Dai, using DaiJoin if starting with ERC-20 Dai.
2. Call `Vat.hope(clipper)` so the auction can collect payment.
3. Call `Clipper.take`, specifying an auction ID, maximum collateral amount, and maximum acceptable price. Use empty `data` for a purchase without a callback.
4. The recipient receives free internal collateral.
5. The recipient calls the corresponding `GemJoin.exit` to withdraw actual collateral tokens.

The auction may fill less than the requested amount. Clipper uses a descending price, and an expired auction may require a reset before another purchase. Advanced purchases can use callback data; those integrations require additional care with permissions and callback behavior.

## 9. The central vault function: Vat.frob

Most ordinary vault operations center on this function:

```solidity
frob(
    bytes32 ilk,  // Collateral type
    address u,    // Vault being modified
    address v,    // Free collateral source or destination
    address w,    // Internal Dai recipient or payer
    int256 dink,  // Change in locked collateral
    int256 dart   // Change in normalized debt
)
```

This is an explanatory signature, not a complete Solidity declaration.

| Action | dink | dart |
| --- | --- | --- |
| Lock collateral | Positive | Zero |
| Borrow Dai | Zero | Positive |
| Repay debt | Zero | Negative |
| Unlock collateral | Negative | Zero |
| Lock and borrow | Positive | Positive |
| Repay and unlock | Negative | Negative |

The three addresses need not be identical. The examples use the same user for clarity; more advanced integrations can separate the vault owner, collateral account, and Dai account, subject to the function's consent checks.

The adapters handle the token boundary. **frob handles the vault's collateral and debt changes.**

## 10. Permission checklist for integrations

| Permission | Set on | Purpose |
| --- | --- | --- |
| `approve(gemJoin, amount)` | Collateral ERC-20 | Lets the adapter transfer collateral tokens |
| `approve(daiJoin, amount)` | Dai ERC-20 | Lets DaiJoin burn tokens when entering internal accounting |
| `hope(daiJoin)` | Vat | Lets DaiJoin move internal Dai when exiting to tokens |
| `hope(pot)` | Vat | Lets Pot collect internal Dai for savings |
| `hope(clipper)` | Vat | Lets Clipper collect internal Dai for auction purchases |

ERC-20 allowances and Vat delegation are distinct. Vat's `hope` is an address-level accounting delegation, not an amount-limited token approval; `nope` revokes it. Direct calls modifying the user's own vault do not require granting that user permission to itself.

Administrative `rely`/`deny` permissions are separate again. A deployed system must already authorize and configure its modules; ordinary user operations do not grant those administrative powers.

