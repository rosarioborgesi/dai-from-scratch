# Vow.sol

[Vow.sol](../src/Vow.sol) manages MakerDAO’s system debt and surplus. It uses accumulated Dai surplus to cancel debt and starts auctions when the system has excess surplus or a remaining deficit. Its Dai and debt balances are held in the [Vat](../src/Vat.sol), the core accounting contract.

Debt can wait in a queue before becoming available for settlement or a debt auction. Debt already assigned to an auction is tracked separately so it cannot be used again for settlement or another auction.

Debt auctions raise Dai to cover a deficit in exchange for governance tokens. Surplus auctions sell excess Dai while leaving enough to cover outstanding debt and a configured surplus buffer. Vow starts these auctions; the separate auction contracts handle bidding and completion.

| Function | Purpose |
|---|---|
| [`fess(tab)`](/home/rosario/linux_workspaces/dai/dai-from-scratch/src/Vow.sol:107) | Records existing debt in a queue under the current timestamp. Only authorized callers can use it. It **does not create debt** in Vat. |
| [`flog(era)`](/home/rosario/linux_workspaces/dai/dai-from-scratch/src/Vow.sol:114) | Releases that timestamp’s queued debt after `wait` seconds, making it available for settlement or a debt auction. It does not cancel the debt. |
| [`heal(rad)`](/home/rosario/linux_workspaces/dai/dai-from-scratch/src/Vow.sol:123) | Cancels available debt using an equal amount of Vow’s internal Dai. Both balances decrease. |
| [`flop()`](/home/rosario/linux_workspaces/dai/dai-from-scratch/src/Vow.sol:139) | Starts a debt auction through `flopper`, offering an initial `dump` governance-token lot for `sump` Dai. Requires enough available debt and a zero Dai balance. Increases `Ash` to reserve the auction’s debt. |
| [`kiss(rad)`](/home/rosario/linux_workspaces/dai/dai-from-scratch/src/Vow.sol:131) | Uses received Dai to cancel debt already assigned to auctions, reducing `Ash` by the same amount. |
| [`flap()`](/home/rosario/linux_workspaces/dai/dai-from-scratch/src/Vow.sol:147) | Starts a surplus auction through `flapper`, selling `bump` internal Dai. Requires enough Dai to cover all outstanding debt, the auction lot, and the retained `hump` buffer. Available debt must also be zero. |
