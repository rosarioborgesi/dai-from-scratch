# Spot.sol

[spot.sol (line 32)](/home/rosario/linux_workspaces/dai/dss/src/spot.sol:32) defines Spotter, the bridge between collateral price feeds and Maker’s core accounting contract, Vat. It converts an oracle price into a price adjusted for the required collateralization ratio, then stores that value in Vat.
The flow is:
Oracle price → Spotter.poke(ilk) → Vat.ilks[ilk].spot
What it stores
An ilk is a collateral type, identified by a bytes32 value such as "ETH-A".

| Variable | Meaning |
|---|---|
| `ilks[ilk].pip` | Oracle supplying that collateral’s price |
| `ilks[ilk].mat` | Required collateralization ratio; e.g. `1.5` means 150% |
| `par` | Reference currency per Dai; initialized to `1` |
| `vat` | Core accounting contract receiving the adjusted price |
| `wards` | Addresses authorized to administer Spotter |
| `live` | Whether configuration changes are allowed |


## Calculate the safety-adjusted price

How much debt (DAI) does 1 unit of collateral (spot) support?

Ignoring fixed-point scaling, the formula is:
spot = oracle price / par / mat
Here, par is the reference currency value of one Dai, and mat is the required collateralization ratio.

For example, with a collateral price of $3,000, par = 1, and mat = 1.5 (150%):
spot = 3000 / 1 / 1.5 = 2000 Dai per collateral unit
This means one unit of collateral supports up to 2,000 Dai of debt under the collateralization requirement.