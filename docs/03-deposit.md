# Deposit collateral

Depositing collateral into a vault takes two steps:

1. **Join:** transfer tokens from your wallet to `GemJoin`. `Vat` records them as your free (unlocked) collateral.
2. **Lock:** call `Vat.frob` to move that free balance into your vault's locked collateral.

The tokens stay in `GemJoin`; `Vat` only tracks balances. These steps do not create debt or mint Dai.

## 1. Set up the collateral type

Before users can deposit, an administrator must:

- Call `Vat.init(ilk)` to register the collateral type, such as `bytes32("WETH-A")`.
- Deploy a `GemJoin` adapter for that token, collateral type, and `Vat`.
- Call `Vat.rely(adapter)` to let the adapter update collateral balances in `Vat`.

This setup happens once for each collateral type.

## 2. Deposit directly

For an 18-decimal token such as WETH, the user makes these calls:

| Step | Call | What happens |
| --- | --- | --- |
| Approve | `token.approve(adapter, amount)` | Allows `GemJoin` to take the tokens from the user's wallet. |
| Join | `gemJoin.join(user, amount)` | Transfers tokens into `GemJoin` and credits the user's free collateral in `Vat`. |
| Lock | `vat.frob(ilk, user, user, user, int256(amount), 0)` | Moves that free collateral into the user's vault. |

The approval is needed when the existing token allowance is too small.

Inside `join`, the adapter calls `Vat.slip` to increase the free collateral balance, then pulls tokens from the caller. If the transfer fails, the entire `join` call reverts, including the balance change. Only authorized addresses can call `slip`.

The arguments to `frob` are:

```text
frob(collateralType, vault, collateralSource, daiAccount, collateralChange, debtChange)
```

Here, all three addresses are `user`. A positive collateral change locks collateral; the final `0` leaves debt unchanged.

**Amounts:** `join` takes the token's native units, while `Vat` uses 18 decimals. For WETH, `1 WETH = 10^18` in both calls. For tokens with fewer decimals, this implementation converts the amount to 18 decimals before recording or locking it. The direct `frob` example assumes an 18-decimal token and an amount that fits in `int256`.

## 3. Combine join and lock with the test proxy

Our test proxy [DssProxy](../test/proxy/DssProxy.sol) provides `lockGem` to perform both steps in one transaction.

First, the user approves the **proxy** to spend the tokens:

```solidity
token.approve(address(proxy), amount);
proxy.lockGem(address(gemJoin), ilk, user, amount, true);
```

The final `true` tells the proxy to take the tokens from the caller's wallet. It then performs this sequence:

```text
User calls lockGem
  → Proxy transfers tokens from the user to itself
  → Proxy approves GemJoin to spend those tokens
  → GemJoin.join(proxy, amount) credits the proxy's free collateral
  → Vat.frob(ilk, user, proxy, proxy, dink, 0) locks it in the user's vault
```

`dink` is the amount converted to 18 decimals. The free collateral belongs to the proxy during the call, so the proxy supplies it to the user's vault. If any step reverts, the whole `lockGem` transaction is undone.

This is a simple test helper that calls `GemJoin` and `Vat` directly, without `delegatecall`.
