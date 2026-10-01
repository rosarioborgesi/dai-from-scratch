# How DSS uses proxies

DSS operations often require several contract calls. A user-owned proxy can combine them into one transaction: for example, moving collateral into the system and locking it in a vault.

This guide explains the DSProxy pattern used by the reference DSS integrations. Users can also call DSS contracts directly; a proxy is a convenience layer around the protocol.

## 1. The contracts involved

| Contract | Role |
| --- | --- |
| `DSProxy` | A contract owned by the user that executes actions on their behalf. |
| `DSProxyFactory` | Deploys new proxy instances. |
| `ProxyRegistry` | Uses the factory to create proxies and records the proxy associated with each user. |
| `DssProxyActions` | Shared code that groups DSS calls into operations such as depositing or borrowing. |

The user typically reuses one proxy for many operations. The action code is shared; each user does not need a separate deployment of it.

Sources: [DSProxy and its factory](https://github.com/dapphub/ds-proxy/blob/master/src/proxy.sol), [ProxyRegistry](https://github.com/sky-ecosystem/proxy-registry/blob/master/src/ProxyRegistry.sol), [DssProxyActions](https://github.com/sky-ecosystem/dss-proxy-actions/blob/master/src/DssProxyActions.sol).

## 2. Create a proxy, then execute actions

With an existing registry, a user creates their proxy by calling:

```solidity
DSProxy proxy = DSProxy(registry.build());
```

The registry asks the factory to deploy the proxy and assigns ownership to the caller. This is setup, not something repeated for every deposit. An existing proxy can be found through `registry.proxies(user)`. See [the registry implementation](https://github.com/sky-ecosystem/proxy-registry/blob/master/src/ProxyRegistry.sol).

To perform an operation, the user calls:

```solidity
proxy.execute(address(dssProxyActions), data);
```

`data` encodes the action's function selector and arguments. Forwarding `msg.data` works only when it already contains the intended action call.

## 3. Why delegatecall matters

```text
User
  → DSProxy.execute(actions, data)
      → delegatecall: run the action code inside the proxy
          → calls to DSS contracts
```

Inside the delegated action, `address(this)` is the proxy and `msg.sender` remains the user. When that code calls another contract, that contract sees the proxy as its caller.

This lets shared code operate through each user's own contract identity. `execute` requires authorization, normally from the proxy owner. If an action reverts, the transaction's changes are rolled back. See [DSProxy.execute](https://github.com/dapphub/ds-proxy/blob/master/src/proxy.sol).

## 4. How this relates to our project

Our [test proxy](../test/proxy/DssProxy.sol) puts `lockGem` directly in the helper contract. It calls `GemJoin` and `Vat` without a registry, shared action contract, or `delegatecall`.

The reference integration also uses `DssCdpManager` to look up a vault by its numeric ID (`cdp`). Our helper instead accepts the collateral type and vault address directly. The underlying [join-and-lock flow](03-deposit.md) is the same idea.

## 5. Example: call lockGem through DSProxy

This illustrative Solidity sequence uses the reference contracts, not our local helper. Assume the user owns the proxy, has 1 WETH, and has an existing WETH vault managed by `manager`. `cdp` is that vault's ID, and `gemJoin` is its matching WETH adapter. The calls below must be made as the user; in a Foundry test, use `vm.startPrank(user)`.

```solidity
uint256 amount = 1 ether; // 1 WETH (18 decimals)

// Allow the proxy to take WETH from the user's wallet.
weth.approve(address(proxy), amount);

// Encode the action to run inside the proxy.
bytes memory data = abi.encodeWithSignature(
    "lockGem(address,address,uint256,uint256,bool)",
    address(manager),
    address(gemJoin),
    cdp,
    amount,
    true // Transfer tokens from the caller's wallet.
);

// Run join and lock in one transaction, after approval.
proxy.execute(address(dssProxyActions), data);
```

During execution:

1. The proxy pulls WETH from the user and approves `GemJoin`.
2. `GemJoin.join` takes the tokens and credits the proxy's free collateral.
3. The action looks up the vault through the manager, then calls `Vat.frob` directly to lock the collateral, with zero debt change.

The tokens remain in `GemJoin`; the vault gains locked collateral. See the reference [lockGem implementation](https://github.com/sky-ecosystem/dss-proxy-actions/blob/master/src/DssProxyActions.sol#L371-L389) and [proxy action tests](https://github.com/sky-ecosystem/dss-proxy-actions/blob/master/src/DssProxyActions.t.sol).
