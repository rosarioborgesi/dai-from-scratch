# Clipper auctions

[Clip.sol](/home/rosario/linux_workspaces/dai/dai-from-scratch/src/Clip.sol) defines Clipper, which sells liquidated collateral through Dutch auctions: the price starts high and decreases over time, and buyers purchase at the current price.

Payments and collateral transfers use Vat’s internal balances. The main auction fields are:
| Field | Meaning |
|---|---|
| `tab` | Remaining Dai target, usually including the liquidation penalty |
| `lot` | Remaining collateral for sale |
| `usr` | Address that receives leftover collateral |
| `tic` | Time the auction started or was last reset |
| `top` | Starting price for the current auction round |


Amounts use wad (10¹⁸) for collateral, ray (10²⁷) for prices, and rad (10⁴⁵) for internal Dai.

Each Clipper sells one immutable collateral type (`ilk`). 

- `kick(tab, lot, usr, kpr)` Starts an auction and returns its ID.
- `take(id, amt, max, who, data)` Lets anyone buy up to amt collateral
- `redo(id, kpr)` Lets anyone restart an existing auction once it has run too long or its price has fallen too far.
- `upchost()` Lets anyone refresh the cached minimum remaining auction target
- `yank(id)` Lets an authorized address cancel an auction

