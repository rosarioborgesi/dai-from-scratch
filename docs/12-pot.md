# Pot.sol

[pot.sol (line 26)](/home/rosario/linux_workspaces/dai/dss/src/pot.sol:26) implements the Dai Savings Rate (DSR): it lets users deposit Dai and earn interest at a rate configured by authorized governance.
It works through three main functions:
- join(wad) deposits funds by moving Dai from the caller’s balance in the Vat into the Pot and recording savings shares.
- drip() compounds interest for the time elapsed since the previous update. Anyone can call it.
- exit(wad) redeems savings shares, returning their Dai value to the caller’s Vat balance.
The key accounting variables are pie[user], the user’s savings shares, and chi, the accumulated Dai value per share. A user’s balance is therefore conceptually:
Dai balance = savings shares × chi
For example, 100 shares worth 1 Dai each represent 100 Dai. If interest increases chi to 1.05, those same shares become redeemable for 105 Dai.