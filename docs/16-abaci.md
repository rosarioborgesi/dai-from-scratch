# Abaci.sol

`src/Abaci.sol` implements the three auction price calculators from DSS. Each implements `Abacus.price(top, dur)`, where `top` and the returned price use ray precision (`1e27`), and `dur` is elapsed seconds. Clipper supplies the starting price and elapsed time.

| Calculator | Parameters | Price curve |
|---|---|---|
| `LinearDecrease` | `tau`: seconds to reach zero | `top × (tau - dur) / tau`, zero when `dur >= tau` |
| `StairstepExponentialDecrease` | `step`: seconds between drops; `cut`: retained fraction per step [ray] | `top × (cut / RAY)^floor(dur / step)` |
| `ExponentialDecrease` | `cut`: retained fraction per second [ray] | `top × (cut / RAY)^dur` |

For example, `cut = 99e25` retains 99% of the price at each drop: a 1% decrease. `cut = RAY` holds the price constant. `cut = 0` makes the price zero at the first drop, while elapsed time zero still returns the initial price for the exponential curves.

The deployer is authorized through `Auth`. Authorized callers configure parameters using `file(bytes32 what, uint256 data)` and manage other administrators with `rely` and `deny`. All prices are publicly readable. Successful parameter updates emit `File`.

Configure the calculator before assigning it to Clipper:

```solidity
StairstepExponentialDecrease calc = new StairstepExponentialDecrease();
calc.file("step", 60);
calc.file("cut", 99e25);
clip.file("calc", address(calc));
```

The caller must be authorized on each contract it configures. Every 60 seconds this example retains 99% of the preceding price. Clipper independently decides whether an auction needs a reset using its `tail` and `cusp` parameters.

The port preserves DSS configuration boundaries: a zero `tau` returns zero immediately; a zero `step` causes price queries to revert on division by zero; `cut` above `RAY` is rejected. Parameters start at zero. Updating a calculator changes the pricing of any running auction that uses it.

The shared `Math` library preserves the original rounding: linear pricing truncates the remaining-time fraction to ray precision before multiplying by `top`; exponential powers round intermediate products to the nearest ray unit, and the final price multiplication rounds down. Solidity 0.8 checked arithmetic rejects intermediate multiplication overflow, even when a final scaled result could fit. Administrative reverts use contract-specific custom errors.
