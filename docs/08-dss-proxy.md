# DssProxy: a helper for managing your own Vault

[DssProxy.sol](../src/proxy/DssProxy.sol) defines `DSSProxy`, a learning-oriented helper that combines the contract calls needed to deposit collateral, borrow Dai, repay debt, and withdraw collateral. Users call the helper directly instead of coordinating each step across the protocol themselves.

For example, `lockETHAndDraw` wraps ETH into WETH, deposits it through the collateral adapter, locks it in the caller's Vault, and delivers borrowed Dai to their wallet—all in one transaction. The helper coordinates the operation; the underlying contracts still hold the assets, record balances, and enforce the protocol's rules. If a step fails, the transaction reverts as a whole.

## Managing only the caller's Vault

The helper identifies a Vault by its collateral type (`ilk`) and the caller's address (`msg.sender`). Its Vault operations always use that caller's position: there is no argument for selecting someone else's Vault. Each address therefore has one position per collateral type, with no separate Vault-opening step.

This keeps the learning flow focused on managing your own collateral and debt. The public deposit helpers can credit another address's free balance inside the Vat, but they do not modify that address's Vault.

Users still need the relevant permissions: token approval lets the helper take collateral or Dai from their wallet, and Vat authorization through `hope` lets it perform operations that require access to their position or internal balances. The Vat continues to enforce collateralization, debt ceilings, and minimum-debt rules.

## Differences from the original DssProxyActions

The helper is inspired by the original [DssProxyActions.sol](../../dss-proxy-actions/src/DssProxyActions.sol), but simplifies how users access and identify their Vaults.

| Aspect | This project's DSSProxy | Original DssProxyActions |
|---|---|---|
| How it is called | Users call the helper directly. | Action code is designed to run through a user-owned DSProxy. |
| Vault identity | The caller's address and collateral type identify the position directly in the Vat. | A CDP manager tracks numbered Vaults and their associated positions. |
| Vault selection | Vault operations always select the caller's position. | Operations accept a Vault ID; the manager enforces ownership and delegated permissions. |
| Opening a Vault | Depositing and locking collateral can populate an initially empty position. | A manager-controlled Vault must be opened; combined functions can open, deposit, and borrow together. |
| Scope | Everyday management of the caller's own Vault. | Also supports ownership transfers, delegated access, and moving positions; separate action contracts cover savings and emergency settlement. |

The original separates the user's proxy, shared action code, and Vault manager. This helper removes those layers so the interaction with the core contracts is easier to follow. See [the proxy overview](06-proxies.md) for the original DSProxy execution model.

## Main functions

`ETH` functions accept or return native ETH, wrapping or unwrapping WETH as needed. `Gem` functions work with ERC-20 collateral tokens.

| Function | Purpose |
|---|---|
| `lockETH`, `lockGem` | Deposit collateral and lock it in the caller's Vault without borrowing. |
| `draw` | Receive Dai against existing collateral, adding debt as needed. |
| `lockETHAndDraw`, `lockGemAndDraw` | Deposit and lock collateral, then receive Dai in one transaction. |
| `wipe` | Repay debt using supplied Dai and any existing internal Dai balance, up to the Vault's outstanding debt. |
| `wipeAll` | Repay the Vault's entire debt, bringing in only the additional Dai needed. |
| `freeETH`, `freeGem` | Unlock collateral and send it to the caller's wallet, provided the Vault remains valid. |
| `wipeAndFreeETH`, `wipeAndFreeGem` | Repay debt and withdraw collateral together. |
| `wipeAllAndFreeETH`, `wipeAllAndFreeGem` | Repay all debt and withdraw the requested collateral amount. |
| `exitETH`, `exitGem` | Withdraw collateral that is already unlocked in the caller's Vat balance. |

The lower-level `ethJoin_join`, `gemJoin_join`, and `daiJoin_join` helpers move assets into the system and credit internal balances. Depositing alone does not lock collateral in a Vault or repay its debt; the higher-level functions combine those steps.
