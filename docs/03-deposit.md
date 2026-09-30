To perform the deposit you need 2 operations:
	1. GemJoin.join(user, amount)
		Transfers tokens from the user to the adapter and credits the user’s unlocked collateral balance in Vat.

	2. Vat.frob(ilk, user, user, user, int256(amount), 0)
		Moves that unlocked balance into the vault’s locked collateral balance. The final 0 means no debt is created.
	
To do both operations in one step the user can call the proxy: DSProxy

	User → DSProxy.execute(DssProxyActions, encoded lockGem call)
         │
         ├─ Transfer tokens: user → proxy
         ├─ Approve GemJoin to spend those tokens
         ├─ GemJoin.join(proxy, amount)
         └─ Vat.frob(... vault urn ..., collateralIncrease, 0)
		 
		 
What we need to implement

	- Vat.init(ilk) registers a collateral type, such as bytes32("WETH-A").
	
	- Vat.rely(adapter) authorizes the adapter to change internal collateral balances. This is an administrator action.
	
	- GemJoin.join(usr, wad) pulls tokens from its caller and invokes Vat.slip(...) to credit usr. A failed transfer reverts the entire deposit.
	
	- Vat.slip(ilk, usr, amount) adjusts unlocked collateral accounting. Only authorized contracts or administrators may call it.
	
	- Vat.frob(ilk, u, v, w, dink, dart) changes a vault:
	  - u: vault address.
	  - v: address supplying unlocked collateral.
	  - w: internal stablecoin balance address.
	  - dink: signed collateral change.
	  - dart: signed normalized debt change.
	  
	For locking only, use dink > 0 and dart = 0