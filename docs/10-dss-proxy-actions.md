# Differenceces between DssProxy and the original DssProxyActions

I have created a proxy DssProxy that the user can call directly and manage its own urns to understand how the operations like borrowing, depositing, repaying and withdrawing works and what contracts are called in DSS. 

Is inspired by https://github.com/sky-ecosystem/dss-proxy-actions/blob/master/src/DssProxyActions.sol

Your proxy already covers the main operations needed to manage a user’s own Vault. It includes locking, borrowing, repayment, collateral withdrawal, and the combined operations. I wouldn’t add much more from DssProxyActions.sol for that scope.
The key difference is that your Vault is identified by (ilk, msg.sender), while the original uses a CDP manager and numbered Vaults. Many original functions exist to support that extra layer.

| Original functions | Recommendation for your proxy |
|---|---|
| `open`, `openLockETHAndDraw`, `openLockGemAndDraw` | **Unnecessary.** Your existing `lockETHAndDraw` and `lockGemAndDraw` can populate the caller’s initially empty Vat position without a separate opening step. |
| `give`, `giveToProxy`, `cdpAllow`, `urnAllow`, `quit`, `enter`, `shift` | **Skip.** These manage ownership, permissions, or migration of manager-controlled Vaults. |
| `safeLockETH`, `safeLockGem`, `safeWipe`, `safeWipeAll` | **Unnecessary for your current model.** These check the expected owner of a numbered Vault. Your functions already select the caller’s position. |
| Generic `frob`, `flux`, `move` | **Optional, low priority.** Your higher-level functions already cover their main uses while keeping the interface easier to understand. |
| `DssProxyActionsEnd` functions | **Only if you implement emergency shutdown.** They need adaptation to your direct Vat ownership model. |
| `DssProxyActionsDsr` functions | **Outside basic Vault management.** Add separately if you implement the savings module. |