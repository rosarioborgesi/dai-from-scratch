# Liquidation

Liquidation sells collateral from an unsafe Vault to cover its debt and a liquidation penalty. A Vault becomes unsafe when the collateral value used by the protocol falls below the required collateralization ratio. This can happen as collateral prices fall or debt grows through stability fees.

The reference implementation in [`dss/src`](../../dss/src) contains two liquidation systems: the older **Liquidation 1.2 (`Cat` → `Flipper`)** and the newer **Liquidation 2.0 (`Dog` → `Clipper`)**. This project implements the newer flow.

## How liquidation works

1. **Someone triggers liquidation.** Anyone can call `Dog.bark` on an unsafe Vault. Keepers are bots that monitor Vaults and submit these transactions; a price drop alone does not execute a liquidation.
2. **The protocol takes collateral and transfers the corresponding debt.** `Dog` determines how much to liquidate within the configured limits. Liquidation can be partial or cover the entire Vault. The seized collateral goes to `Clipper`, while the debt is assigned to `Vow`, the system's debt and surplus manager.
3. **An auction sells the collateral for Dai.** The target covers the liquidated debt, including accrued stability fees, plus a liquidation penalty. In Liquidation 2.0, the asking price decreases over time. Buyers can purchase portions of collateral at the current price and receive them immediately.
4. **The sale ends when the target is collected or the collateral runs out.** If the target is met, leftover collateral returns to the Vault owner. An unfinished auction that exceeds its time or price limits must be reset before purchases resume.
5. **The protocol settles the debt.** Auction proceeds go to `Vow`. After the debt's waiting period, Dai can be used to cancel it. Any excess remains as system surplus; if the sale raises too little, the remaining debt must be covered by other surplus or debt auctions.

Removing debt from the Vault transfers responsibility to the protocol. The system debt is canceled separately using Dai, as the example below shows.

## Older versus newer liquidation

Both systems sell seized collateral to recover Dai. The main difference is how buyers compete and when their purchases settle.

| Aspect | Liquidation 1.2: Cat → Flipper | Liquidation 2.0: Dog → Clipper |
|---|---|---|
| Auction style | English-style bidding: participants improve the current bid. | Dutch auction: the asking price falls over time. |
| How buyers compete | First offer more Dai for a fixed collateral amount; once the target is reached, accept less collateral for the same Dai. | Choose when to buy and how much collateral to purchase at the current price. Multiple buyers can fill one auction. |
| Settlement | The winner receives collateral after bidding expires and the auction is settled. | Each purchase exchanges Dai for collateral in the same transaction. |
| Dai commitment | The leading bidder's Dai is committed until they are outbid or the auction settles. | Buyers pay when purchasing, with no bidding lockup period. |

The newer design lets buyers receive and reuse collateral immediately, reducing their exposure to price changes while waiting for an auction to finish. See the [protocol's liquidation documentation](https://developers.skyeco.com/protocol/vaults/collateral-liquidation/) for the design rationale.

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

