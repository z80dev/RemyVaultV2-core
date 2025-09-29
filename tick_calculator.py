#!/usr/bin/env python3
"""
Tick calculator for Uniswap V3/V4 liquidity positions.
Formula: price = 1.0001^tick
Therefore: tick = log(price) / log(1.0001)
"""
import math

def price_to_tick(price):
    """Convert price to tick."""
    return int(math.floor(math.log(price) / math.log(1.0001)))

def tick_to_price(tick):
    """Convert tick to price."""
    return 1.0001 ** tick

def align_tick_to_spacing(tick, tick_spacing):
    """Align tick to the nearest valid tick spacing."""
    return (tick // tick_spacing) * tick_spacing

print("=" * 80)
print("UNISWAP V4 TICK CALCULATOR")
print("=" * 80)

# Parent/ETH Pool Configuration
print("\n1. PARENT/ETH POOL")
print("-" * 80)
print("Target: Parent token price range 0.01 ETH to 0.5 ETH")
print("Current price: 0.01 ETH per parent token")
print("Liquidity: 500 parent tokens + corresponding ETH")
print()

# Assuming parent is currency1 (higher address) and ETH is currency0
# Then price = amount1 / amount0 = parent / ETH
# If 1 parent = 0.01 ETH, then 1 ETH = 100 parent
# So price_lower = 100 parent per ETH (when parent is cheap)
# price_upper = 2 parent per ETH (when parent is expensive at 0.5 ETH each)

parent_eth_lower = 0.01  # ETH per parent (parent is cheap)
parent_eth_upper = 0.5   # ETH per parent (parent is expensive)
parent_eth_current = 0.01

# If ETH is currency0 and parent is currency1:
# price = parent/ETH, so we invert:
price_eth_lower = 1 / parent_eth_upper  # When parent is expensive, price is low
price_eth_upper = 1 / parent_eth_lower  # When parent is cheap, price is high
price_current = 1 / parent_eth_current

print(f"If ETH is currency0 (lower address), Parent is currency1:")
print(f"  Price = Parent/ETH")
print(f"  Lower price (parent expensive): {price_eth_lower:.6f} (parent per ETH)")
print(f"  Upper price (parent cheap): {price_eth_upper:.6f} (parent per ETH)")
print(f"  Current price: {price_current:.6f} (parent per ETH)")

tick_lower = price_to_tick(price_eth_lower)
tick_upper = price_to_tick(price_eth_upper)
tick_current = price_to_tick(price_current)

# Align to tick spacing (common spacings: 1, 10, 60, 200)
tick_spacing = 60
tick_lower_aligned = align_tick_to_spacing(tick_lower, tick_spacing)
tick_upper_aligned = align_tick_to_spacing(tick_upper, tick_spacing)
tick_current_aligned = align_tick_to_spacing(tick_current, tick_spacing)

print(f"\n  Raw ticks:")
print(f"    tickLower: {tick_lower} (price: {tick_to_price(tick_lower):.6f})")
print(f"    tickUpper: {tick_upper} (price: {tick_to_price(tick_upper):.6f})")
print(f"    tickCurrent: {tick_current} (price: {tick_to_price(tick_current):.6f})")

print(f"\n  Aligned to tick spacing {tick_spacing}:")
print(f"    tickLower: {tick_lower_aligned} (price: {tick_to_price(tick_lower_aligned):.6f})")
print(f"    tickUpper: {tick_upper_aligned} (price: {tick_to_price(tick_upper_aligned):.6f})")
print(f"    tickCurrent: {tick_current_aligned} (price: {tick_to_price(tick_current_aligned):.6f})")

# Calculate sqrtPriceX96 for current price
sqrt_price = math.sqrt(price_current)
sqrt_price_x96 = int(sqrt_price * (2 ** 96))
print(f"\n  sqrtPriceX96: {sqrt_price_x96}")

# Calculate required amounts for liquidity
# For a position at current price with 500 tokens
print(f"\n  For 500 parent tokens in the pool at current price 0.01 ETH:")
L = 500 * 1e18  # Approximate liquidity
eth_needed = 500 * 0.01  # ETH needed
print(f"    Approx ETH needed: {eth_needed} ETH")
print(f"    Parent tokens: 500")

print("\n" + "=" * 80)
print("\n2. DERIVATIVE/PARENT POOL")
print("-" * 80)
print("Target: Derivative priced 0.1 parent token to 1 parent token")
print("At mint out: Start at 0.1 parent per derivative")
print()

# Derivative/Parent pool
deriv_parent_lower = 0.1  # Parent per derivative (derivative is cheap)
deriv_parent_upper = 1.0  # Parent per derivative (derivative is expensive)
deriv_parent_start = 0.1  # Starting price at mint out

print(f"Scenario 1: If Derivative is currency0, Parent is currency1:")
print(f"  Price = Parent/Derivative")
# In this case, prices are directly as stated
print(f"  Lower price: {deriv_parent_lower} (parent per derivative)")
print(f"  Upper price: {deriv_parent_upper} (parent per derivative)")
print(f"  Start price: {deriv_parent_start} (parent per derivative)")

tick_lower_d = price_to_tick(deriv_parent_lower)
tick_upper_d = price_to_tick(deriv_parent_upper)
tick_start_d = price_to_tick(deriv_parent_start)

tick_spacing_d = 60
tick_lower_d_aligned = align_tick_to_spacing(tick_lower_d, tick_spacing_d)
tick_upper_d_aligned = align_tick_to_spacing(tick_upper_d, tick_spacing_d)
tick_start_d_aligned = align_tick_to_spacing(tick_start_d, tick_spacing_d)

print(f"\n  Raw ticks:")
print(f"    tickLower: {tick_lower_d} (price: {tick_to_price(tick_lower_d):.6f})")
print(f"    tickUpper: {tick_upper_d} (price: {tick_to_price(tick_upper_d):.6f})")
print(f"    tickStart: {tick_start_d} (price: {tick_to_price(tick_start_d):.6f})")

print(f"\n  Aligned to tick spacing {tick_spacing_d}:")
print(f"    tickLower: {tick_lower_d_aligned} (price: {tick_to_price(tick_lower_d_aligned):.6f})")
print(f"    tickUpper: {tick_upper_d_aligned} (price: {tick_to_price(tick_upper_d_aligned):.6f})")
print(f"    tickStart: {tick_start_d_aligned} (price: {tick_to_price(tick_start_d_aligned):.6f})")

sqrt_price_d = math.sqrt(deriv_parent_start)
sqrt_price_x96_d = int(sqrt_price_d * (2 ** 96))
print(f"\n  sqrtPriceX96: {sqrt_price_x96_d}")

print(f"\n\nScenario 2: If Parent is currency0, Derivative is currency1:")
print(f"  Price = Derivative/Parent")
# In this case, we invert the prices
price_lower_inv = 1 / deriv_parent_upper  # When derivative is cheap
price_upper_inv = 1 / deriv_parent_lower  # When derivative is expensive
price_start_inv = 1 / deriv_parent_start

print(f"  Lower price: {price_lower_inv} (derivative per parent)")
print(f"  Upper price: {price_upper_inv} (derivative per parent)")
print(f"  Start price: {price_start_inv} (derivative per parent)")

tick_lower_inv = price_to_tick(price_lower_inv)
tick_upper_inv = price_to_tick(price_upper_inv)
tick_start_inv = price_to_tick(price_start_inv)

tick_lower_inv_aligned = align_tick_to_spacing(tick_lower_inv, tick_spacing_d)
tick_upper_inv_aligned = align_tick_to_spacing(tick_upper_inv, tick_spacing_d)
tick_start_inv_aligned = align_tick_to_spacing(tick_start_inv, tick_spacing_d)

print(f"\n  Raw ticks:")
print(f"    tickLower: {tick_lower_inv} (price: {tick_to_price(tick_lower_inv):.6f})")
print(f"    tickUpper: {tick_upper_inv} (price: {tick_to_price(tick_upper_inv):.6f})")
print(f"    tickStart: {tick_start_inv} (price: {tick_to_price(tick_start_inv):.6f})")

print(f"\n  Aligned to tick spacing {tick_spacing_d}:")
print(f"    tickLower: {tick_lower_inv_aligned} (price: {tick_to_price(tick_lower_inv_aligned):.6f})")
print(f"    tickUpper: {tick_upper_inv_aligned} (price: {tick_to_price(tick_upper_inv_aligned):.6f})")
print(f"    tickStart: {tick_start_inv_aligned} (price: {tick_to_price(tick_start_inv_aligned):.6f})")

sqrt_price_inv = math.sqrt(price_start_inv)
sqrt_price_x96_inv = int(sqrt_price_inv * (2 ** 96))
print(f"\n  sqrtPriceX96: {sqrt_price_x96_inv}")

print("\n" + "=" * 80)
print("\nSUMMARY - RECOMMENDED VALUES")
print("=" * 80)
print("\nParent/ETH Pool (assuming ETH has lower address):")
print(f"  tickLower: {tick_lower_aligned}")
print(f"  tickUpper: {tick_upper_aligned}")
print(f"  sqrtPriceX96: {sqrt_price_x96}")
print(f"  tickSpacing: {tick_spacing}")

print("\nDerivative/Parent Pool:")
print("  (Actual ticks depend on which token has lower address)")
print(f"  If derivative < parent:")
print(f"    tickLower: {tick_lower_d_aligned}")
print(f"    tickUpper: {tick_upper_d_aligned}")
print(f"    sqrtPriceX96: {sqrt_price_x96_d}")
print(f"  If parent < derivative:")
print(f"    tickLower: {tick_lower_inv_aligned}")
print(f"    tickUpper: {tick_upper_inv_aligned}")
print(f"    sqrtPriceX96: {sqrt_price_x96_inv}")
print(f"  tickSpacing: {tick_spacing_d}")