# Join

The purpose of join adapters is to  to add/remove value to/from the Vat. 

Join consists of three smart contracts: GemJoin, ETHJoin, and DaiJoin:

GemJoin - allows standard ERC20 tokens to be deposited for use with the system. ETHJoin - allows native Ether to be used with the system.
DaiJoin - allows users to withdraw their Dai from the system into a standard ERC20 token.

Each join contract is created specifically to allow the given token type to be join’ed to the vat. Because of this, each join contract has slightly different logic to account for the different types of tokens within the system.

