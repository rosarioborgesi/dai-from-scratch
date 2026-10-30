# Dai from scratch

This project is a learning exercise to understand the Dai protocol by reading and rebuilding its DSS smart contracts. It uses Foundry, Solidity 0.8.35, and OpenZeppelin Contracts v5.7.0.

The focus is on understanding how the contracts work together: collateral deposits, vault accounting, borrowing and repayment, stability fees, savings interest, and liquidation. The implementation, tests, and documentation record what each component does and how this reconstruction differs from the reference code. This is an educational reconstruction, with parts of the original system still unimplemented.

## Major differences from the reference implementation

- **Modern Solidity:** uses Solidity 0.8.35 instead of the local DSS reference's 0.6.12, with built-in arithmetic checks and custom errors.
- **OpenZeppelin-based Dai token:** uses `ERC20`, `EIP712`, and `ECDSA` instead of implementing token accounting and signature verification directly. It retains Dai-style boolean `permit`, with some interface and behavior differences: for example, `transferFrom` requires allowance even for the caller's own balance, and OpenZeppelin rejects zero-address transfers. See the [Dai notes](docs/07-dai.md) for the full comparison.
- **Shared permission and shutdown code:** `Auth` centralizes administrative authorization, and `Shutdown` provides individual contract shutdown flags. Full global settlement is not implemented.
- **Collateral decimal conversion:** GemJoin follows the `join-5.sol` approach, supporting tokens with up to 18 decimals and normalizing their balances for Vat. The basic DSS GemJoin assumes 18-decimal collateral.
- **Simpler user helper:** users call `DSSProxy` directly to combine operations on their own vault. It identifies positions by the caller and collateral type, without `DssCdpManager`, a proxy registry, or `delegatecall`.
- **Partial protocol scope:** Dog/Clipper liquidation and Pot savings are implemented. Surplus and debt auctions (`Flapper` and `Flopper`) and global settlement (`End` and `Cure`) are not. The older Cat/Flipper liquidation mechanism is omitted.

## Reading the project

Start with the [introduction](docs/00-intro.md) for the references, implementation changes, and missing components. Continue with the [architecture overview](docs/01-architecture.md) and [user operations guide](docs/02-user-operations.md), then follow the individual contract notes.

The [proxy overview](docs/06-proxies.md) explains the original DSProxy pattern, while the [DSSProxy notes](docs/08-dss-proxy.md) describe this project's simplified helper.

## Resources

- [DSS source](https://github.com/sky-ecosystem/dss)
- [DssProxyActions source](https://github.com/sky-ecosystem/dss-proxy-actions)
- [Maker/Sky whitepaper](https://makerdao.com/en/whitepaper/) — economic context; the linked page also includes Sky-era additions.
- [Sky developer documentation](https://developers.skyeco.com/) — broader protocol and integration documentation.
