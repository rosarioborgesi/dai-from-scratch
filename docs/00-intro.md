# Dai from scratch

This project is a learning exercise aimed at understanding how the Dai protocol works by reading and rebuilding its DSS smart contracts. It uses Solidity 0.8.35, Foundry, and OpenZeppelin Contracts, while documenting changes from the original implementation and components that have not been rebuilt.

The goal is to follow how the contracts work together: depositing collateral, managing vault debt, borrowing and repaying Dai, accruing fees and savings interest, and liquidating unsafe positions. The code, tests, and notes support that exploration; this is an educational reconstruction rather than a complete production deployment.

Start with the [architecture overview](01-architecture.md) for the roles of the main contracts and the [user operations guide](02-user-operations.md) for how they interact.

## Reference implementations

The main references are:

- [DSS](../../dss/): the core accounting, token, fee, liquidation, savings, and settlement contracts. Upstream: [sky-ecosystem/dss](https://github.com/sky-ecosystem/dss).
- [DssProxyActions](../../dss-proxy-actions/): shared action code used through user-owned proxies to combine operations across contracts such as Vat, Jug, and the adapters. Upstream: [sky-ecosystem/dss-proxy-actions](https://github.com/sky-ecosystem/dss-proxy-actions).
- [DSS Gem Joins](../../dss-proxy-actions/lib/dss-gem-joins/): collateral adapters, including the decimal conversion used here. Upstream: [sky-ecosystem/dss-gem-joins](https://github.com/sky-ecosystem/dss-gem-joins).

## Changes from the original implementation

The reconstruction follows the reference contracts' core ideas, with changes intended to make the code easier to study using modern Solidity. Individual contract notes explain the details and any differences in behavior or interfaces.

| Area | Change in this project |
| --- | --- |
| Solidity | Uses Solidity 0.8.35 instead of the 0.6.12 version used by the local DSS reference. Ordinary arithmetic has built-in overflow and underflow checks, and failures use custom errors. |
| Dai token | Uses OpenZeppelin Contracts v5.7.0: `ERC20` supplies token accounting, while `EIP712` and `ECDSA` support signature verification. The original implements these directly. Dai-style boolean `permit` is retained; see the [Dai notes](07-dai.md) for compatibility differences. |
| Shared authorization | [Auth](../src/Auth.sol) centralizes `wards`, `rely`, `deny`, and administrative permission checks that the original repeats across contracts. |
| Contract shutdown | [Shutdown](../src/Shutdown.sol) provides a shared implementation of each inheriting contract's shutdown flag and `cage` entry point. It does not implement the full global settlement process provided by `End`. |
| Collateral decimals | [GemJoin](../src/join/GemJoin.sol) follows the decimal conversion approach in `join-5.sol`, supporting tokens with up to 18 decimals and normalizing collateral balances to 18 decimals in Vat. The basic GemJoin in DSS assumes 18-decimal collateral. See the [adapter notes](04-join.md). |
| User operations | [DSSProxy](../src/proxy/DssProxy.sol) is a helper inspired by `DssProxyActions`. Users call it directly to combine deposits, borrowing, repayment, and withdrawals. It uses the caller's address and collateral type to identify their vault, without `DssCdpManager`, a proxy registry, or `delegatecall`. See the [proxy overview](06-proxies.md) and [helper notes](08-dss-proxy.md). |

## Components not implemented

The reconstruction includes [Pot](../src/Pot.sol) for the Dai Savings Rate; see the [savings notes](14-pot.md). The following reference components have not been rebuilt:

| Missing contract | Role in the reference implementation |
| --- | --- |
| [Flapper](../../dss/src/flap.sol) | Auctions surplus internal Dai for governance tokens, which are burned. |
| [Flopper](../../dss/src/flop.sol) | Auctions newly minted governance tokens for Dai to cover system debt. |
| [End](../../dss/src/end.sol) | Coordinates global shutdown and settlement, including auction unwinding, vault processing, and collateral redemption for Dai holders. |
| [Cure](../../dss/src/cure.sol) | Collects debt adjustments from registered sources for End's settlement accounting. |

Vow retains interfaces to Flapper and Flopper, but their auction implementations are absent. Individual contract shutdown flags are present, but global settlement through End and Cure is not implemented.

### Older liquidation contracts

This project implements the Dog/Clipper liquidation mechanism. The older contracts are omitted as a separate design choice:

| Omitted contract | Role in the older liquidation mechanism |
| --- | --- |
| [Cat](../../dss/src/cat.sol) | Identifies unsafe vaults, confiscates collateral and debt, and starts Flipper auctions. Dog fills the liquidation-controller role here. |
| [Flipper](../../dss/src/flip.sol) | Uses competitive bidding to sell seized collateral. Clipper instead uses descending-price auctions. |
