# Vat
The Vat is the core Vault engine of dss. It stores Vaults and tracks all the associated Dai and collateral balances. 


# Math

Since we are using Solidity 0.8.35 I replaced:

The original:

```solidity
// --- Math ---
    function _add(uint x, int y) internal pure returns (uint z) {
        z = x + uint(y);
        require(y >= 0 || z <= x);
        require(y <= 0 || z >= x);
    }
    function _sub(uint x, int y) internal pure returns (uint z) {
        z = x - uint(y);
        require(y <= 0 || z <= x);
        require(y >= 0 || z >= x);
    }
    function _mul(uint x, int y) internal pure returns (int z) {
        z = int(x) * y;
        require(int(x) >= 0);
        require(y == 0 || z / y == int(x));
    }
    function _add(uint x, uint y) internal pure returns (uint z) {
        require((z = x + y) >= x);
    }
    function _sub(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x);
    }
    function _mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }
```

with the library [`VatMath.sol`](../src/libraries/VatMath.sol):

```solidity
library VatMath {
    function _add(uint x, int y) internal pure returns (uint z) {
        unchecked { z = x + uint(y); }
        require(y >= 0 || z <= x);
        require(y <= 0 || z >= x);
    }

    function _sub(uint x, int y) internal pure returns (uint z) {
        unchecked { z = x - uint(y); }
        require(y <= 0 || z <= x);
        require(y >= 0 || z >= x);
    }

    function _mul(uint x, int y) internal pure returns (int z) {
        require(x <= uint(type(int).max));
        z = int(x) * y;
    }
}
```
I have kept only the functions with y int as input parameters, I have removed the others with y as uint:

```solidity
 function _add(uint x, uint y) internal pure returns (uint z) {
        require((z = x + y) >= x);
    }
    function _sub(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x);
    }
    function _mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }
```

Because in Solidity 0.8.35 there is no need to guard agains underflow/overflow of uint256 since it is done by the language itself.


# Ilk

```solidity
    struct Ilk {
        uint256 Art;   // Total Normalised Debt     [wad]
        uint256 rate;  // Accumulated Rates         [ray]
        uint256 spot;  // Price with Safety Margin  [ray]
        uint256 line;  // Debt Ceiling              [rad]
        uint256 dust;  // Urn Debt Floor            [rad]
    }
```

An Ilk contains the shared accounting and risk settings for all vaults of one collateral type. Each individual vault has an Urn, which stores its locked collateral (ink) and normalized debt (art).

First, the units represent fixed-point numbers:

| Unit | Scale | How `1` is stored |
|---|---|---|
| `wad` | 18 decimal places | `10 ** 18` |
| `ray` | 27 decimal places | `10 ** 27` |
| `rad` | 45 decimal places | `10 ** 45` |

These are conventions for interpreting integers. Multiplying a wad by a ray gives a rad.

## What each field means

| Field | Meaning |
|---|---|
| `Art` | Sum of all vaults’ normalized debt (`art`) for this collateral type. Think of normalized debt as debt shares: multiplying them by `rate` gives the actual debt. |
| `rate` | Accumulated debt multiplier. Starts at `1.0`, stored as `10 ** 27`. As fees accrue, the multiplier increases without needing to update every vault’s `art`. It is **not an annual interest percentage**. |
| `spot` | Safety-adjusted collateral price: how much debt one unit of collateral can safely support. |
| `line` | Maximum total debt for this collateral type, including accumulated fees. |
| `dust` | Minimum nonzero debt allowed for an individual vault. A vault may also have zero debt. This avoids tiny debt positions that are uneconomical to liquidate. |


For example, using readable numbers instead of scaled integers:
- A vault has art = 100 and the collateral type has rate = 1.05: its actual debt is 105 Dai.
- All vaults together have Art = 10,000: their total debt is 10,500 Dai.
- Suppose ETH is worth 3,000 Dai and the required collateralization ratio is 150%. The adjusted price is spot = 3,000 / 1.5 = 2,000. A vault with 2 ETH can therefore support 4,000 Dai of debt.
- If dust = 100, a vault can have zero debt or at least 100 Dai of debt; it cannot leave 50 Dai outstanding.

# Urn

```solidity
struct Urn {
    uint256 ink;   // Locked Collateral  [wad]
    uint256 art;   // Normalised Debt    [wad]
}
```
An Urn is the accounting record for one Vault: it tracks the collateral locked in that Vault and the debt attached to it.

- ink = collateral locked in the Vault, measured in collateral units. For example, locking 2 ETH gives ink = 2 in human-readable units.

- art = normalized debt. Think of it as debt shares: multiply them by the collateral type’s accumulated fee multiplier, rate, to get the current debt:

Current debt = art × rate

For example, ignoring the contract’s decimal scaling:

| State | `ink` | `art` | `rate` | Current debt |
|---|---:|---:|---:|---:|
| Initially | 2 ETH | 1,000 | 1.00 | 1,000 Dai |
| After fees accrue | 2 ETH | 1,000 | 1.05 | 1,050 Dai |

The key is that fees can increase your debt without changing art. Updating the shared rate accounts for fees across all Vaults of that collateral type, without rewriting each Vault’s record. Borrowing or repaying changes art.

# State Variables

```solidity
mapping(bytes32 => Ilk) public ilks;
```
This declares a lookup table that stores an Ilk struct for each collateral type.

- bytes32 is the key: a 32-byte identifier, such as "ETH-A".
- Ilk is the value: the struct containing Art, rate, spot, line, and dust.

Conceptually, the mapping looks like this:

ilks
 ├── "ETH-A" → Ilk { Art, rate, spot, line, dust }
 ├── "ETH-B" → Ilk { Art, rate, spot, line, dust }
 └── "WBTC-A"→ Ilk { Art, rate, spot, line, dust }

 ETH-A and ETH-B can represent the same underlying asset with different risk settings.

```solidity
 mapping(address => uint) public wards;
 ```
This is a lookup table that records which addresses have administrative permission in the contract.

The contract uses these values: 

```solidity
wards[usr] = 1; // Authorized
wards[usr] = 0; // Not authorized (also the default)
```

```solidity
mapping(bytes32 ilkId => mapping(address user => uint balance)) private s_gem;
```
Stores for each collateral id (ilkId) the balance of each user.

```solidity
uint256 public live;
```
Indicates whether the contract is active (1) or shut down (0)
   

