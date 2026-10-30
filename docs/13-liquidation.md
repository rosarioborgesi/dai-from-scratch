# Liquidation

dss/src contains two liquidation systems: Liquidation 2.0 (Dog → Clipper) and the older Cat → Flipper. Both seize collateral from unsafe Vaults, sell it for Dai, and send proceeds to Vow to cover system debt.

The Liquidation 2.0 flow is:
1. Someone triggers liquidation. Anyone can call Dog.bark(ilk, urn, kpr)
2. Dog sizes the liquidation.
3. Collateral is seized and debt moves into system accounting. Vat.grab removes collateral and normalized debt from the Vault, credits collateral to the Clipper, and records unbacked debt against Vow. Vow.fess queues that debt. The auction target is:
due = liquidated normalized debt × rate
tab = due × chop / 10^18
chop is the penalty multiplier
4. Clipper sells collateral through a Dutch auction.
5. The auction closes or resets.


Unlike the old Liquidation 1.2 system which utilized English auctions, in which DAI bids are placed, with a participant’s capital remaining locked until they are outbid or until the auction terminates, Liquidation 2.0 uses Dutch auctions which settle instantly. They do so according to a price calculated from the initial price and the time elapsed since the auction began. 


The older path starts with permissionless [`Cat.bite` (line 135)](/home/rosario/linux_workspaces/dai/dss/src/cat.sol:135). Its [`Flipper` (line 145)](/home/rosario/linux_workspaces/dai/dss/src/flip.sol:145) uses two bidding phases: tend raises the Dai bid for fixed collateral; once the target is reached, dent lowers the collateral requested for that fixed Dai amount. deal settles after expiry.

## Example: liquidating Alice's vault

This scenario is covered by [`test_LiquidateUnsafeVault_BuyCollateralAndSettleDebt`](../test/integration/LiquidationIntegrationTest.t.sol) in `LiquidationIntegrationTest.t.sol`.

Alice borrows **1,000 Dai against 1 WETH**, initially worth $3,000, and keeps that Dai in her wallet.

When WETH's price falls to **$1,200**, her vault becomes unsafe. With a 150% collateral requirement, that collateral can support only **800 Dai of debt**, less than the 1,000 she owes.

The liquidation works like this:

1. **The protocol seizes her collateral and removes the debt from her vault.** A keeper calls `Dog.bark`. Her vault is now empty, while the protocol records the 1,000 Dai as bad debt assigned to `Vow` and queues it for settlement.
2. **An auction sells enough collateral to collect 1,100 Dai:** the 1,000 Dai principal plus a 100 Dai liquidation penalty.
3. **The buyer pays 1,100 internal Dai and receives about 0.9167 WETH.** At the auction's starting price of $1,200 per WETH, this covers the full target. The remaining **0.0833 WETH goes back to Alice**, because the auction has collected everything required. Both then withdraw their collateral as wallet WETH.
4. **After the one-hour waiting period, the protocol cancels the 1,000 Dai debt using the auction proceeds.** `Vow.flog` releases the debt from the waiting queue; `Vow.heal` cancels it against 1,000 internal Dai held by `Vow`. The remaining 100 Dai stays with the protocol as surplus.

At the end:

| Party | Outcome |
|---|---|
| Alice | Keeps her borrowed 1,000 Dai and gets back about 0.0833 WETH; her vault has no debt or collateral. |
| Buyer | Pays 1,100 internal Dai and receives about 0.9167 WETH. |
| Protocol | Clears the liquidated debt and retains 100 internal Dai as surplus. |

Alice's debt is paid through **the sale of her collateral**. That is why she still holds the Dai she originally borrowed even though her vault's debt is gone.

The buyer funds the purchase by borrowing 2,000 Dai through a separate vault, which remains safe after the price drop. After settlement, total system debt is therefore 2,000 Dai: Alice's 1,000 Dai debt has been canceled, while the buyer's debt remains. This example has no stability fees or keeper rewards, so the accounting isolates the principal and liquidation penalty.

