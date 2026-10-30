# Vat

The [Vat](../src/Vat.sol) is the core accounting system and vault rules engine of the protocol. It tracks collateral, vault debt, internal Dai balances, and unbacked system debt. It also enforces the rules for borrowing and withdrawing collateral.

The Vat updates a ledger; token adapters handle the actual ERC-20 transfers. Collateral tokens are held by a `GemJoin` adapter, while `DaiJoin` connects internal Dai to wallet Dai tokens.

Each deployment has one Vat. All vaults share its accounting rules, with separate risk settings for each collateral type.

## The accounting model

| Record | Meaning |
|---|---|
| `Ilk` | Shared accounting and risk parameters for a collateral type, such as `ETH-A`. |
| `Urn` | One vault's locked collateral (`ink`) and normalized debt (`art`). |
| `s_gem[ilk][user]` | Free collateral inside the system, available to lock or withdraw. |
| `s_dai[user]` | Internal Dai owned by an address: a spendable credit, not its vault debt. |
| `s_sin[user]` | Unbacked system debt assigned to an address, typically the Vow. |

A vault is identified by a collateral type and an address: `s_urns[ilk][urn]`. That address can belong to a user or a contract.

### Units

The Vat uses integers interpreted as fixed-point numbers:

| Unit | Decimal places | Representation of `1` | Used for |
|---|---:|---|---|
| `wad` | 18 | `10 ** 18` | Collateral and normalized debt. |
| `ray` | 27 | `10 ** 27` | Debt multipliers and safety-adjusted prices. |
| `rad` | 45 | `10 ** 45` | Internal Dai, actual debt, and debt limits. |

Multiplying a wad by a ray gives a rad. Therefore, with raw stored integers:

```text
debtRad = artWad * rateRay
debtWad = debtRad / 10 ** 27
```

Examples below use human-readable amounts unless stated otherwise.

### Ilk: settings shared by a collateral type

```solidity
struct Ilk {
    uint256 Art;  // Total normalized debt [wad]
    uint256 rate; // Accumulated debt multiplier [ray]
    uint256 spot; // Price with safety margin [ray]
    uint256 line; // Debt ceiling [rad]
    uint256 dust; // Minimum nonzero vault debt [rad]
}
```

| Field | Meaning |
|---|---|
| `Art` | Sum of all vaults' normalized debt (`art`) for this collateral type. Multiplying by `rate` gives their total actual debt. |
| `rate` | Accumulated debt multiplier, initialized to `10 ** 27`, representing `1.0`. It is not an annual interest percentage. |
| `spot` | Safety-adjusted collateral price: how much debt one unit of collateral can safely support. |
| `line` | Debt ceiling for this collateral type, checked when borrowing. Actual debt includes accumulated fees. |
| `dust` | Minimum nonzero debt allowed for an individual vault. A vault may also have zero debt. |

For example:

- If `Art = 10,000` and `rate = 1.05`, the collateral type's total vault debt is 10,500 Dai.
- If ETH is worth 3,000 Dai and the required collateralization ratio is 150%, `spot = 3,000 / 1.5 = 2,000`. A vault with 2 ETH can support 4,000 Dai of debt.
- If `dust = 100`, a vault can owe zero or at least 100 Dai; it cannot leave 50 Dai outstanding.

`ETH-A` and `ETH-B` can represent the same underlying asset with different risk settings.

### Urn: one vault's position

```solidity
struct Urn {
    uint256 ink; // Locked collateral [wad]
    uint256 art; // Normalized debt [wad]
}
```

Think of `art` as debt shares. Multiplying those shares by the collateral type's `rate` gives the current debt:

```text
Current debt = art × rate
```

| State | `ink` | `art` | `rate` | Current debt |
|---|---:|---:|---:|---:|
| Initially | 2 ETH | 1,000 | 1.00 | 1,000 Dai |
| After fees accrue | 2 ETH | 1,000 | 1.05 | 1,050 Dai |

Borrowing and repayment change `art`. Fee accrual changes the shared `rate`, accounting for fees across all vaults of that collateral type without rewriting each vault's record. The Vat stores this multiplier; the Jug computes fee accrual and requests its adjustment through `fold`.

### Free collateral versus locked collateral

`s_gem[ilk][user]` records free collateral; `urn.ink` records collateral locked in a vault. Locking and unlocking move collateral between these accounting balances without transferring tokens out of the adapter.

| Operation | Free collateral | Locked collateral | WETH held by adapter |
|---|---:|---:|---:|
| Deposit 3 WETH through `GemJoin.join` | 3 | 0 | 3 |
| Lock 2 WETH through `frob` | 1 | 2 | 3 |
| Unlock 1 WETH through `frob` | 2 | 1 | 3 |
| Withdraw 2 WETH through `GemJoin.exit` | 0 | 1 | 1 |

### Vault debt versus internal Dai

`urn.art` tracks normalized debt owed by a vault. `s_dai[user]` tracks internal Dai owned by an address. Borrowing creates a debt obligation and credits spendable internal Dai; spending or withdrawing that Dai does not repay the debt.

Assume `rate = 1.0` and the user receives the borrowed Dai and supplies repayments:

| Operation | Internal Dai | `urn.art` | Actual debt |
|---|---:|---:|---:|
| Start | 0 Dai | 0 | 0 Dai |
| Borrow 100 Dai through `frob` | 100 Dai | 100 | 100 Dai |
| Exit all 100 Dai to the wallet | 0 Dai | 100 | 100 Dai |
| Join 40 wallet Dai into the Vat | 40 Dai | 100 | 100 Dai |
| Repay 40 Dai through `frob` | 0 Dai | 60 | 60 Dai |

## Most important functions

### `frob`: lock, unlock, borrow, and repay

```solidity
function frob(
    bytes32 i,
    address u,
    address v,
    address w,
    int256 dink,
    int256 dart
) external isAlive;
```

`frob` is the main vault operation. It changes locked collateral and normalized debt together in one transaction.

| Parameter | Meaning |
|---|---|
| `i` | Collateral type. |
| `u` | Address identifying the vault being modified. |
| `v` | Address supplying or receiving free collateral. |
| `w` | Address receiving borrowed Dai or supplying repayment Dai. |
| `dink` | Signed change in locked collateral, in wad: positive locks, negative unlocks. |
| `dart` | Signed change in normalized debt, in wad: positive borrows, negative repays. |

The three addresses can differ. A vault owner, collateral provider, and Dai recipient need not be the same account.

Conceptually, the accounting changes are:

```text
urn.ink       += dink
freeCollateral[v] -= dink
urn.art       += dart
ilk.Art       += dart
internalDai[w] += dart × rate
totalDebt     += dart × rate
```

For example, with `rate = 1.0`, positive changes of 2 collateral units and 1,000 normalized debt units lock 2 units of free collateral and generate 1,000 internal Dai. Negative changes reverse these effects. Either change can also be zero.

Before accepting the operation, `frob` checks:

- The Vat is live and the collateral type is initialized.
- New borrowing respects both the collateral type's ceiling (`line`) and the global ceiling (`s_Line`).
- Borrowing or unlocking leaves the vault safe: `art × rate <= ink × spot`.
- The caller has vault permission when borrowing or unlocking, collateral-source permission when locking, and Dai-source permission when repaying.
- Remaining debt is zero or at least `dust`.

Adding collateral and/or repaying debt can proceed even if the vault remains unsafe, provided the other checks pass. It does not require the vault owner's consent when neither debt increases nor collateral decreases, but permission to spend the supplied balances is still required.

### `fold`: account for changes in accumulated fees

```solidity
function fold(bytes32 i, address u, int256 rate) external auth isAlive;
```

`fold` adds a signed change to a collateral type's stored debt multiplier. The `rate` argument is an increment, not a new multiplier or an annual interest rate.

```text
ilk.rate      += rate
adjustment     = ilk.Art × rate
internalDai[u] += adjustment
totalDebt     += adjustment
```

A positive adjustment increases all affected vault debts and credits the resulting internal Dai to `u`, typically the Vow. Individual vaults' `ink` and `art` stay unchanged. Negative adjustments reverse the accounting and require sufficient balances.

### `grab`: record liquidation or confiscation

```solidity
function grab(bytes32 i, address u, address v, address w, int256 dink, int256 dart)
    external auth;
```

`grab` is a privileged accounting operation used during liquidation. A typical liquidation supplies negative `dink` and `dart`:

- Locked collateral and normalized debt are removed from vault `u`.
- The seized collateral becomes free collateral credited to `v`, typically the auction contract.
- The removed actual debt becomes unbacked debt (`sin`) assigned to `w`, typically the Vow.
- Total unbacked debt (`s_vice`) increases.

Total issued Dai (`s_debt`) stays unchanged: liquidation reclassifies the debt instead of repaying it. The Vat does not itself decide when to liquidate or run the auction; authorized modules handle those steps.

### `heal` and `suck`: cancel or create unbacked debt

| Function | Effect |
|---|---|
| `heal(rad)` | Consumes equal amounts of the caller's internal Dai and `sin`, reducing both total issued Dai and total unbacked debt. |
| `suck(u, v, rad)` | Creates internal Dai for `v` and matching unbacked debt for `u`, increasing both totals. Restricted to authorized addresses. |

`heal` requires sufficient internal Dai and unbacked debt on the caller's account. It settles system debt; ordinary vault repayment uses `frob`.

### Collateral and Dai transfers

| Function | Effect | Permission |
|---|---|---|
| `slip(ilk, user, wad)` | Applies a signed adjustment to free collateral. Adapters use it when tokens enter or leave. | Administrative authorization. |
| `flux(ilk, source, destination, wad)` | Transfers free collateral within the Vat. | Source or its approved operator. |
| `move(source, destination, rad)` | Transfers internal Dai within the Vat. | Source or its approved operator. |
| `fork(ilk, src, dst, dink, dart)` | Moves locked collateral and normalized debt between vaults of the same collateral type. | Both vaults must consent. |

`fork` requires both resulting vaults to be safe and to have zero debt or debt at least equal to `dust`. It leaves total debt, free collateral, and internal Dai unchanged. Negative amounts move the position in the opposite direction.

## Permissions and configuration

The Vat has two separate permission systems:

- **Administrative authorization**, inherited from [Auth](../src/Auth.sol): `wards(address)` reports whether an address can call privileged functions. `rely` grants this access and `deny` revokes it. Authorized modules can perform powerful accounting operations such as `slip`, `grab`, and `suck`.
- **Account permission**: `hope(operator)` grants an operator permission to act on the caller's balances and vaults; `nope(operator)` revokes it. `can(owner, operator)` exposes the approval. These approvals are broad account permissions, not amount-limited allowances.

Internally, `_wish(owner, caller)` accepts either the owner itself or an operator the owner approved.

| Function | Purpose |
|---|---|
| `init(ilk)` | Initializes a collateral type's `rate` to `10 ** 27` (`1.0`). Does not configure its other risk parameters. |
| `file("Line", data)` | Sets the global debt ceiling, in rad. |
| `file(ilk, what, data)` | Sets `spot` (ray), `line` (rad), or `dust` (rad) for a collateral type. |
| `cage()` | Sets the Vat's live flag to zero through the inherited [Shutdown](../src/Shutdown.sol) contract. |

The live flag is read through `live()`. Shutdown disables `frob`, `fold`, parameter updates through `file`, and changes to administrative authorization through `rely` and `deny`. It does not disable every function: transfers, `fork`, `grab`, and settlement operations remain callable subject to their normal permissions and balance checks. Each adapter has its own shutdown flag.

## Typical user flow

To deposit collateral and borrow wallet Dai:

1. `GemJoin.join`: transfer collateral tokens into the adapter and credit free collateral in the Vat.
2. `Vat.frob`: lock collateral and generate internal Dai.
3. `DaiJoin.exit`: move internal Dai into the Dai adapter and mint wallet Dai tokens.

To repay and withdraw:

1. `DaiJoin.join`: burn wallet Dai and transfer matching internal Dai from the adapter to the selected account.
2. `Vat.frob`: consume internal Dai to repay debt and unlock collateral, subject to the vault checks.
3. `GemJoin.exit`: debit free collateral and transfer collateral tokens out of the adapter.

These flows require the relevant token approvals and Vat permissions. In particular, `DaiJoin.exit` needs permission to move the caller's internal Dai. Joining or exiting Dai changes where its value is represented; vault debt changes only when a debt operation such as `frob` occurs.

## State variables and getters

The current implementation uses private storage mappings with explicit getters:

| Storage | Getter | Meaning |
|---|---|---|
| `s_ilks` | `ilks(ilk)` | Collateral type accounting and risk parameters. |
| `s_urns` | `urns(ilk, user)` | Vault position. |
| `s_gem` | `gem(ilk, user)` | Free collateral [wad]. |
| `s_dai` | `dai(account)` | Internal Dai [rad]. |
| `s_sin` | `sin(user)` | Assigned unbacked debt [rad]. |
| `s_can` | `can(owner, operator)` | Account permission. |
| `s_debt` | `debt()` | Total issued internal Dai [rad], including Dai represented externally through the adapter. |
| `s_vice` | `vice()` | Total unbacked debt [rad]. |
| `s_Line` | `s_Line()` | Global debt ceiling [rad]; this variable is public. |

The accounting relationship is:

```text
totalDebt = sum(ilk.Art × ilk.rate) + totalUnbackedDebt
```

This explains why `grab` leaves total debt unchanged while `heal` reduces it.

## Arithmetic in the Solidity 0.8.35 implementation

The original Vat used explicit overflow and underflow checks for unsigned arithmetic. Solidity 0.8.35 checks ordinary addition, subtraction, and multiplication automatically outside `unchecked` blocks, so the unsigned helper overloads are unnecessary here.

Signed adjustments to unsigned balances still use [Math.sol](../src/libraries/Math.sol):

| Helper | Meaning |
|---|---|
| `add(uint256 x, int256 y)` | Add a signed change to an unsigned balance. Negative `y` decreases it. |
| `sub(uint256 x, int256 y)` | Subtract a signed change. Negative `y` increases the balance. |
| `mul(uint256 x, int256 y)` | Multiply unsigned and signed values, returning a signed result. |

`add` and `sub` deliberately use wrapping arithmetic inside `unchecked`, followed by explicit overflow and underflow checks. This preserves the original Vat's signed-adjustment behavior. `mul` checks that `x` fits in `int256` before multiplying; Solidity checks the signed product for overflow.

These helpers do not rescale fixed-point values. For example, `rate.mul(dart)` multiplies ray by wad and returns a signed rad amount.
