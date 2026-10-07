FLOW:
1 Check the vault is ready.
	Collateral must already be locked in Vat.urns(ilk, user).ink. 
	It requires GemJoin.join and Vat.frob with positive dink.

2. Update the borrowing rate
	Call Jug.drip(ilk). It returns the updated rate, scaled by 10²⁷. 

3. Calculate normalized debt (dart).

	Your borrowing code calculates dart. Neither Vat.frob nor DaiJoin.exit calculates it for you.
	Where that code runs depends on your implementation:
	- Direct wallet calls: your frontend or script reads the updated rate and calculates dart before calling Vat.frob.
	- Helper contract or proxy: its borrowing function calls Jug.drip(ilk), uses the returned rate to calculate dart, then calls Vat.frob and DaiJoin.exit within the same transaction.

	Vat.frob then takes your calculated dart and creates dart × rate internal DAI.
	
4. Create the debt and internal DAI.

	Vat.frob(ilk, user, user, user, 0, int256(dart));
	
	This leaves locked collateral unchanged, increases the vault’s normalized debt by dart, and credits dart × rate internal DAI to user.
	
5. Authorize the DAI adapter.
	User calls: Vat.hope(address(daiJoin));
	
	This is needed only if Vat.can(user, address(daiJoin)) != 1. It is a Vat permission;
	
6. Receive wallet DAI.
	
	From user, call:
	DaiJoin.exit(recipient, daiAmount);
	
	The adapter moves daiAmount × 10²⁷ internal DAI from the caller to itself and mints daiAmount ERC-20 DAI to recipient.
	
