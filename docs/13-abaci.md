# Abaci.sol

[Abaci.sol](../src/Abaci.sol) contains three price calculators for collateral liquidation auctions. They determine how the auction's asking price decreases over time, allowing buyers to purchase collateral as the price becomes attractive.

All three implement the `Abacus` interface through `price(top, dur)`, where `top` is the initial auction price and `dur` is the number of seconds elapsed since the auction started. The result is the current price. Prices use **ray** precision (`10^27` represents one).

The [Clip contract](../src/Clip.sol) calls its configured calculator with the auction's starting price and elapsed time. The calculators only compute prices: they do not hold collateral, transfer Dai, or manage auction bids. They also do not read an oracle or track auction start times themselves.

| Contract | How the price decreases | Configuration |
|---|---|---|
| `LinearDecrease` | Falls at a constant rate from `top` to zero over `tau` seconds. At or after `tau`, the price is zero. | `tau`: duration of the price decline in seconds. |
| `StairstepExponentialDecrease` | Stays constant between steps, then multiplies the price by `cut` at each completed step. | `step`: seconds between drops; `cut`: fraction retained after each drop, in ray units. |
| `ExponentialDecrease` | Multiplies the price by `cut` for every elapsed second. | `cut`: fraction retained each second, in ray units. |

For example, with an initial price of 100, a linear curve with `tau = 100` reaches 50 after 50 seconds and zero after 100 seconds. A stairstep curve with `step = 60` and `cut = 0.9 × 10^27` stays at 100 for the first minute, becomes 90 at 60 seconds, and becomes 81 at 120 seconds. The per-second exponential calculator applies the same compounding principle every second.

Authorized addresses configure each calculator through `file(what, data)`, using the parameter names shown above. The deployer is initially authorized, and permissions are managed through the inherited `rely` and `deny` functions. Anyone can query `price`.

The exponential calculators reject a `cut` greater than `10^27`. A `cut` equal to `10^27` keeps the price unchanged, while a smaller value decreases it. The stairstep calculator requires a nonzero `step` before use to avoid division by zero. For the linear calculator, an unconfigured or zero `tau` makes the price immediately zero.
