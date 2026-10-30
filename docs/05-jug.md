# Jug

The [Jug contract](../src/Jug.sol) manages stability fees: the interest charged on Vault debt. It stores the fee settings for each collateral type (`ilk`, such as `ETH-A`) and calculates how much its debt multiplier has grown since the last update.

The [Vat](../src/Vat.sol) stores each Vault's normalized debt and a shared accumulated debt multiplier, called `rate`, for its collateral type. A Vault's actual debt is `normalized debt × rate`. Increasing that shared multiplier increases the debt of every Vault of that type without looping over individual Vaults or changing their normalized debt.

Fees accrue when someone calls `drip(ilk)`; Jug does not run automatically as time passes. The call accounts for the elapsed time, updates the rate through `Vat.fold`, and credits the fee amount as internal Dai to the configured Vow address. For a positive rate change, Vat increases total system debt and the Vow's internal Dai balance by `total normalized debt × rate change`. This does not mint ERC20 Dai into a wallet.

## Fee settings and accounting

Jug stores three inputs to the fee calculation:

- `duty`: the collateral-specific contribution to the per-second growth factor.
- `base`: the global contribution, shared by all collateral types.
- `rho`: the timestamp of the last accrual for a collateral type.

`base`, `duty`, and Vat's `rate` use ray precision (`1e27` represents `1.0`). The effective per-second factor is `(base + duty) / 1e27`; these are fixed-point factors, not annual percentages. Initially, `base` is zero and `init` sets `duty` to `1e27`, giving a factor of `1.0` and therefore no growth.

Jug holds an immutable reference to Vat and a configurable Vow address. In a working deployment, the collateral type must be initialized in both Vat and Jug, the Vow address must be configured, and Jug must be authorized in Vat to call `fold`.

## Important functions

### `init(ilk)`

Initializes a collateral type in Jug by setting `duty` to `1e27` and `rho` to the current block timestamp. This establishes the starting point for future fee accrual. Only an authorized address can call it, and it rejects a collateral type whose stored `duty` is already nonzero. It does not initialize the collateral type in Vat.

### `file(...)`

The three overloads configure Jug's fee policy and fee recipient. All require administrative authorization:

| Call | Effect |
| --- | --- |
| `file(ilk, "duty", data)` | Sets the collateral-specific fee contribution. Requires `rho` to equal the current block timestamp. |
| `file("base", data)` | Sets the global fee contribution for all collateral types. |
| `file("vow", address)` | Sets the address that receives the internal Dai fee adjustment. |

Before changing `duty`, call `drip(ilk)` at the same block timestamp, typically in the same transaction. This settles the elapsed period using the old settings before the new value takes effect.

The `base` setter has no equivalent timestamp check. To avoid applying a new base to time that elapsed under the old base, accrue fees for the affected collateral types before changing it. Similarly, changing `vow` does not settle pending fees: the next `drip` uses the recipient configured at that time.

### `drip(ilk)`

Anyone can call `drip`; the caller does not need administrative authorization. It:

1. Reads the previous `rate` from Vat and calculates the seconds elapsed since `rho`.
2. Compounds `base + duty` over that interval to calculate the new rate.
3. Calls `Vat.fold(ilk, vow, newRate - previousRate)` to apply the signed rate change and corresponding internal Dai adjustment.
4. Sets `rho` to the current block timestamp and returns the new rate.

Calling it again at the same timestamp produces no additional accrual. Borrowing code can call `drip` before calculating how much normalized debt to create, so it uses the current multiplier.

### Getters and authorization

`ilks(ilk)` returns the collateral type's `duty` and `rho`; `base()`, `vat()`, and `vow()` expose the global configuration. The accumulated `rate` is stored in Vat, so it must be read there or obtained from `drip`.

Jug inherits `rely(user)`, `deny(user)`, and `wards(user)` from [Auth](../src/Auth.sol). These manage and inspect administrative access to initialization and configuration. The deployer starts authorized; this permission is separate from Jug's authorization in Vat.

## Math

From the original Math functions:

```solidity
    function _add(uint x, uint y) internal pure returns (uint z) {
        z = x + y;
        require(z >= x);
    }
    function _diff(uint x, uint y) internal pure returns (int z) {
        z = int(x) - int(y);
        require(int(x) >= 0 && int(y) >= 0);
    }
    function _rmul(uint x, uint y) internal pure returns (uint z) {
        z = x * y;
        require(y == 0 || z / y == x);
        z = z / ONE;
    }
```

The unsigned `_add` helper is unnecessary because Solidity 0.8.35 checks ordinary arithmetic for overflow. The updated `diff` and `rmul` functions live in [Math.sol](../src/libraries/Math.sol), where `RAY` is the fixed-point scale:

```solidity
    function diff(uint256 x, uint256 y) internal pure returns (int256) {
        if (x > uint256(type(int256).max) || y > uint256(type(int256).max)) {
            revert Math__Int256OutOfRange();
        }
        return int256(x) - int256(y);
    }

    // Multiplies two ray-scaled numbers
    function rmul(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x * y) / RAY;
    }
```

## `rpow`

The rpow function was kept as the original in assembly but moved to Math.sol

How `_rpow` works in the [original Jug contract](../../dss/src/jug.sol):

**`_rpow` computes the compounding multiplier**, while `drip` applies it to the accumulated stability-fee rate.

`_rpow` is a general fixed-point exponentiation function:

$$
\operatorname{\_rpow}(x,n,b) \approx b\left(\frac{x}{b}\right)^n
$$

In `drip`, its inputs are:

- `x = base + duty`: the per-second growth factor.
- `n = now - rho`: seconds since the last update.
- `b = ONE = 10²⁷`: the fixed-point scale, called a *ray*.

So the calculation is:

$$
\text{new rate} \approx \text{previous rate}
\times \left(\frac{\text{base}+\text{duty}}{10^{27}}\right)^{\text{elapsed seconds}}
$$

This compounds the stability fee **once per second**. `_rpow` uses exponentiation by squaring to compute it efficiently, with rounding and overflow checks.

## `drip` calculation example

The formula used to calculate the new rate is:

newRate = previousRate × ((base + duty) / 10²⁷)^elapsedSeconds

If you have:

- duty = 11e26 represents 1.1.
- base = 1e27 represents 1.0.
- previousRate = 2 * RAY represents 2.0, rather than 2%.
- elapsedSeconds = 9.

Their sum gives a per-second multiplier of 2.1. These deliberately large values make the arithmetic easy to follow; they are not realistic fee settings.

The new rate is 2 × 2.1⁹ × 10²⁷ = 1.588560093162e30

The [Jug unit test](../test/unit/JugUnitTest.t.sol) checks this calculation. Its Vat mock omits `fold` accounting, so the test verifies the returned rate only.
