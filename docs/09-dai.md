# dai

I have implemented Dai inheriting from ERC20 contract by Open Zeppelin. The original contract implemented directly the ERC20 features inside Dai.

Since we are using Solidity 0.8.35 the functions add and sub are not needed because Solidity automatically reverts on overflow and underflow.

Since we are inheriting from ERC20 we can skip the implementation of the function like transfer, transferFrom..

The [original Dai contract](https://github.com/sky-ecosystem/dss/blob/master/src/dai.sol) used EIP712 directly implemented in the code. SInce we are using Open Zeppelin contract I decided to reimplement it using EIP712 contract.

# permit
The permit function allows an holder of Dai to approve another spender through a signature validation.

The great idea is that another address (the relayer) can call the permit function and it can pay for the gas transaction. 

What happens is that: 
- holder signs the approval.
- spender receives unlimited allowance.
- relayer submits the signature.

Check the test test_Permit_ValidSignatureApprovesThroughRelayer to undertand how this works.