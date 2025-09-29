# Price Range Configuration

## Summary

This document contains verified tick values for setting up Uniswap V4 pools with specific price ranges. All values have been tested with fork tests in `test/PriceRangeFork.t.sol`.

## Parent/ETH Pool

**Target Price Range**: Parent token costs **0.01 to 0.5 ETH**
**Starting Price**: 0.01 ETH per parent token (100 parent per ETH)
**Liquidity**: 500 parent tokens + ~5 ETH

### Configuration

```solidity
tickLower: 6900
tickUpper: 46020
sqrtPriceX96: 792281625142643375935439503360
tickSpacing: 60
fee: 3000 (0.3%)
```

### Price Interpretation
- When parent is **cheap** (0.01 ETH): You get 100 parent per ETH
- When parent is **expensive** (0.5 ETH): You get 2 parent per ETH
- Liquidity is active throughout this range

### Test Results
✅ Pool initializes at correct price
✅ Liquidity can be added in the specified range
✅ Swaps work correctly: 0.1 ETH buys ~8-10 parent tokens (depending on slippage)

## Derivative/Parent Pool

**Target Price Range**: Derivative costs **0.1 to 1.0 parent tokens**
**Starting Price**: 0.1 parent per derivative (at mint out)

### Configuration

The exact ticks depend on which token has a lower address (currency0), but the **DerivativeFactory automatically normalizes** them.

**Use these values when calling `createDerivative()`:**

```solidity
tickLower: -23040
tickUpper: 0
sqrtPriceX96: 25054144837504793750611689472
tickSpacing: 60
fee: 3000 (0.3%)
```

The factory's `_normalizePriceAndTicks()` function (line 280 in DerivativeFactory.sol) will:
- Keep these values if derivative address < parent address
- Flip them to (0, 23040) if parent address < derivative address

Both cases result in the **same economic outcome**: derivative starts at 0.1 parent and can appreciate to 1.0 parent.

### Price Interpretation
- When derivative is **cheap**: 0.1 parent per derivative (10 derivative per parent)
- When derivative is **expensive**: 1.0 parent per derivative (1:1 ratio)
- Starting at the cheap end allows room for price appreciation

### Test Results
✅ Pool initializes at correct price (~0.1 parent per derivative)
✅ Liquidity position created successfully
✅ Swaps work: 3 parent tokens buy ~10 derivative tokens
✅ Effective price after swap: ~0.36 parent per derivative (showing price movement)
✅ Price can move toward boundaries without reverting

## Tick Calculation Formula

For reference, these ticks were calculated using:

```python
tick = floor(log(price) / log(1.0001))
```

Where `price` is the ratio of token amounts (currency1/currency0).

## Usage Example

```solidity
DerivativeFactory.DerivativeParams memory params;
params.parentVault = parentVaultAddress;
params.tickLower = -23040;
params.tickUpper = 0;
params.sqrtPriceX96 = 25054144837504793750611689472;
params.liquidity = 5e18; // 5 units of liquidity
params.parentTokenContribution = 20 * 1e18; // 20 parent tokens
params.fee = 3000;
params.tickSpacing = 60;

factory.createDerivative(params);
```

## Important Notes

1. **Root Pool Liquidity Required**: The parent/ETH pool must have liquidity before derivative pools can be used for swaps (enforced by the hook).

2. **Token Ordering**: Currency0 is always the lower address. ETH (address 0) is always currency0 in root pools.

3. **Liquidity Amount**: The `liquidity` parameter determines the depth of the pool. Higher liquidity = less slippage.

4. **Starting Price**: Starting at the lower end of the range (0.1 parent per derivative) means:
   - Most of the position is in derivative tokens initially
   - Derivative can appreciate 10x before hitting the upper bound
   - Suitable for launches where you want room for growth

## Verification

Run the fork tests to verify these values:

```bash
uv run forge test --match-contract PriceRangeForkTest -vv
```

All three tests should pass:
- ✅ `test_ParentEthPriceRange()`
- ✅ `test_DerivativeParentPriceRange()`
- ✅ `test_SwapTowardsPriceBoundaries()`