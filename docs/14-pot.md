# Pot: Dai savings at a glance

[`Pot.sol`](../src/Pot.sol) implements the Dai Savings Rate (DSR). Users deposit internal Dai from the Vat, the protocol's accounting engine, and receive savings shares. As interest accrues, each share becomes worth more Dai. These shares are recorded inside Pot; they are not transferable tokens.

Pot works with **internal Vat balances**, so depositing ERC-20 Dai requires first converting it to internal Dai through DaiJoin. Withdrawing from Pot returns internal Dai to the user's Vat balance.

The main values are:

| Value | Meaning |
| --- | --- |
| `pie(user)` | The user's savings shares. |
| `Pie()` | Total savings shares across all users. |
| `chi()` | The accumulated Dai value per share. |
| `dsr()` | The per-second compounding rate configured by authorized governance. |
| `rho()` | The timestamp of the last interest update. |

Conceptually, **Dai balance = shares × chi**. For example, 100 shares at a value of 1 Dai each represent 100 Dai. If `chi` grows to 1.05 Dai per share, those same shares represent 105 Dai. In the contract, shares use 18 decimals (`wad`), `chi` uses 27 (`ray`), and their product is an internal Dai amount with 45 decimals (`rad`).

The most important functions are:

| Function | High-level behavior |
| --- | --- |
| `drip()` | Anyone can call it to compound interest through the current timestamp, updating `chi` and `rho`. It creates the internal Dai needed to fund the increase in total savings value and assigns matching unbacked debt to the configured Vow account. Pot must be authorized in Vat for this. |
| `join(wad)` | Deposits internal Dai and credits the caller with `wad` savings shares. The cost is `wad × chi`, so the argument is a number of shares. The caller must grant Pot permission through `Vat.hope`, and interest must already be updated to the current timestamp. |
| `exit(wad)` | Burns `wad` of the caller's shares and returns `wad × chi` internal Dai. It uses the stored `chi`; call `drip()` first to include interest accrued since the last update. |
| `file(...)` | Lets authorized callers configure the savings rate (`"dsr"`) or the debt account (`"vow"`). Changing the rate requires interest to be updated to the current timestamp first. |
| `cage()` | Lets authorized callers shut down Pot and reset the rate to the neutral multiplier of one, stopping further interest growth. It does not accrue pending interest. In this implementation, deposits and withdrawals remain available, but the savings rate can no longer be changed. |

A typical flow is to obtain internal Dai, grant Pot permission, call `drip()` and `join()` in the same transaction, then later call `drip()` followed by `exit()` to withdraw the shares' updated Dai value.
