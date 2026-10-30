# Vow.sol

The Vow contract represents the Sky Protocol’s balance sheet. In particular, the Vow acts as the recipient of both the system surplus and system debt.

Vow is MakerDAO’s system debt and surplus settlement module. It uses accumulated Dai surplus to cancel system debt, and starts auctions when there is excess surplus or a remaining deficit.

It operates on balances inside the Vat, Maker’s core accounting contract.

| Value | Meaning |
|---|---|
| `vat.sin(address(vow))` | Total system debt assigned to the Vow |
| `vow.sin[timestamp]` | Debt recorded in a particular timestamp’s queue entry |
| `vow.Sin` | Total debt still in that queue |
| `vow.Ash` | Debt already allocated to debt auctions |




The debt available for settlement or a new debt auction is:

```text
available debt = vat.sin(address(vow)) - vow.Sin() - vow.Ash()
```

| Function | Purpose |
|---|---|
| [`fess(tab)`](/home/rosario/linux_workspaces/dai/dai-from-scratch/src/Vow.sol:107) | Records existing debt in a queue under the current timestamp. Only authorized callers can use it. It **does not create debt** in Vat. |
| [`flog(era)`](/home/rosario/linux_workspaces/dai/dai-from-scratch/src/Vow.sol:114) | Releases that timestamp’s queued debt after `wait` seconds, making it available for settlement or a debt auction. It does not cancel the debt. |
| [`heal(rad)`](/home/rosario/linux_workspaces/dai/dai-from-scratch/src/Vow.sol:123) | Cancels available debt using an equal amount of Vow’s internal Dai. Both balances decrease. |
| [`flop()`](/home/rosario/linux_workspaces/dai/dai-from-scratch/src/Vow.sol:139) | Starts a debt auction through `flopper`, offering an initial `dump` governance-token lot for `sump` Dai. Requires enough available debt and a zero Dai balance. Increases `Ash` to reserve the auction’s debt. |
| [`kiss(rad)`](/home/rosario/linux_workspaces/dai/dai-from-scratch/src/Vow.sol:131) | Uses received Dai to cancel debt already assigned to auctions, reducing `Ash` by the same amount. |
| [`flap()`](/home/rosario/linux_workspaces/dai/dai-from-scratch/src/Vow.sol:147) | Starts a surplus auction through `flapper`, selling `bump` internal Dai. Requires enough Dai to cover all outstanding debt, the auction lot, and the retained `hump` buffer. Available debt must also be zero. |



