# Jug

The primary function of the Jug smart contract is to accumulate stability fees for a particular collateral type whenever its drip() method is called. This effectively updates the accumulated debt for all Vaults of that collateral type as well as the total accumulated debt as tracked by the Vat (global) and the amount of Dai surplus (represented as the amount of Dai owned by the Vow.

# Math
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

I have removed the _add function because we don't need to check against overflow in Solidity 0.8.35, I have converted _rpow from assembly into Solidity and also updated the function _diff and _rmul into solidity 0.8.35 and moved the code into the library JugMath.sol .

```solidity
    function diff(uint256 x, uint256 y) internal pure returns (int256) {
        if (x > uint256(type(int256).max) || y > uint256(type(int256).max)) {
            revert JugMath__Int256OutOfRange();
        }
        return int256(x) - int256(y);
    }

    // Multiplies two ray-scaled numbers
    function rmul(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x * y) / ONE;
    }
```


# drip
The function drip returns the new rate.

the new rate returned by this method is a debt multipler used to calculate the actual debt

actual debt = normalized debt x rate

The formula used to calculate the new rate is:

newRate = previousRate × ((base + duty) / 10²⁷)^elapsedSeconds

If you have:

- duty = 11e26 represents 1.1.
- base = 1e27 represents 1.0.
Their sum gives a per-second multiplier of 2.1.

- previousRate = 2 * RAY represents 2.0, rather than 2%.

The new rate is 2 × 2.1⁹ × 10²⁷ = 1.588560093162e30

This function also calls the fold method on the vat contract to update the accounting.