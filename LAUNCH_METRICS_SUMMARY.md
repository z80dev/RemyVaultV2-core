# Derivative Launch Metrics - Quick Reference

## How to Run Tests with Detailed Metrics

```bash
# Run the comprehensive scenario test
uv run forge test --match-test testDerivativeLaunchScenarios -vv

# Run the single detailed test
uv run forge test --match-test testCreateDerivativeDeploysArtifacts -vv

# Run all tests with logging
uv run forge test -vv
```

## Metrics Captured in Tests

### Pre-Launch Configuration
- **Max Supply**: Number of NFTs in the derivative collection
- **Target Liquidity**: Desired liquidity parameter for Uniswap V3 position
- **Parent Token Contribution**: Amount of parent tokens offered for liquidity
- **Tick Range**: [tickLower, tickUpper] defining price boundaries
- **Tick Width**: Total range width in ticks
- **Initial SqrtPriceX96**: Starting price (79228162514264337593543950336 = 1:1)
- **Fee Tier**: Uniswap pool fee in basis points (3000 = 0.3%)

### Post-Launch Token Flows
- **Parent Tokens Consumed**: Amount actually used from contribution
- **Parent Tokens Refunded**: Amount returned to creator
- **Parent Utilization (bps)**: Percentage of contribution used (in basis points)
- **Derivative Total Supply**: Total tokens minted (maxSupply × 1e18)
- **Derivative to Recipient**: Tokens sent to NFT owner/recipient
- **Derivative in Pool**: Tokens retained for liquidity provision
- **Derivative Retained in Pool %**: Percentage of supply in the pool

### Pool Liquidity State
- **Actual Liquidity**: Liquidity amount successfully added to pool
- **Liquidity Efficiency (bps)**: How much of target was achieved (10000 = 100%)
- **Pool SqrtPriceX96**: Final pool price after liquidity addition
- **Price Maintained**: Whether price equals initial target
- **Derivative is Currency0**: Token ordering in the pool
- **Effective Tick Lower/Upper**: Actual ticks used (may be inverted)

## Quick Metrics Analysis from Test Results

### At 1:1 Price Point (All Scenarios)

| Metric | Observed Value | Notes |
|--------|---------------|-------|
| Liquidity Efficiency | 100% | Perfect match with target |
| Parent Utilization | 0% | Minimal consumption at balanced price |
| Price Stability | 100% | No slippage on initialization |
| Derivative Distribution | ~99% to recipient, ~1% in pool | Most supply available for sale |

### Range Width Impact (at 1:1 price)

| Range Type | Tick Width | Parent Token Need | Capital Efficiency |
|------------|------------|-------------------|-------------------|
| Narrow     | 120        | Minimal           | Maximum           |
| Medium     | 240        | Minimal           | Very High         |
| Wide       | 600        | Minimal           | High              |
| Very Wide  | 1200       | Minimal           | Moderate          |
| Ultra Wide | 2400       | Minimal           | Lower             |

**Note:** Parent token requirements increase with range width, but remain minimal at 1:1 price due to balanced pool initialization.

### Scale Impact

| Size | Liquidity | Max Supply | Gas Cost (approx) | Use Case |
|------|-----------|------------|-------------------|----------|
| Small | 1K | 10 NFTs | ~1-2M gas | Testing, small editions |
| Medium | 100K | 50 NFTs | ~2-3M gas | Community launches |
| Large | 10M | 200 NFTs | ~3-5M gas | Major collections |

## Common Launch Configurations

### Conservative (Low Risk)
```solidity
tickLower: -600
tickUpper: 600
liquidity: 100000
parentContribution: 50 * 1e18
maxSupply: 50
```
- Wide price tolerance (±6%)
- Suitable for uncertain pricing
- Lower capital efficiency but higher safety

### Balanced (Medium Risk)
```solidity
tickLower: -120
tickUpper: 120
liquidity: 100000
parentContribution: 20 * 1e18
maxSupply: 50
```
- Standard range (±1.2%)
- Good balance of efficiency and safety
- Recommended for most launches

### Aggressive (High Risk, High Efficiency)
```solidity
tickLower: -60
tickUpper: 60
liquidity: 100000
parentContribution: 20 * 1e18
maxSupply: 50
```
- Narrow range (±0.6%)
- Maximum capital efficiency
- Requires active monitoring
- Best for derivatives with expected tight peg

## Interpreting the Metrics

### Liquidity Efficiency
- **10000 bps (100%)**: Perfect - all target liquidity added
- **9000-9999 bps (90-99.9%)**: Excellent - minor rounding
- **<9000 bps (<90%)**: Issue - investigate parameters

### Parent Utilization
- **0-1000 bps (0-10%)**: Normal at balanced price
- **1000-5000 bps (10-50%)**: Expected for asymmetric ranges
- **>5000 bps (>50%)**: High consumption - verify parameters

### Price Stability
- **true**: Ideal - no slippage on initialization
- **false**: Warning - check configuration

### Derivative Distribution
- **>95% to recipient**: Normal - most supply available
- **50-95% to recipient**: Moderate pool retention
- **<50% to recipient**: High liquidity position

## Files for Reference

- `test/DerivativeFactory.t.sol`: Main test file with logging
- `DERIVATIVE_LAUNCH_ANALYSIS.md`: Detailed analysis document
- `DERIVATIVE_LAUNCH_TEST_OUTPUT.txt`: Raw test output with all metrics
- Current file: Quick reference guide

## Key Insights

1. **Price Matters Most**: At 1:1, parent token usage is minimal. At other prices, usage increases significantly.

2. **Range Width is Flexible**: Choose based on risk tolerance, not technical constraints.

3. **Liquidity Scales Linearly**: 10x liquidity requires ~10x tokens (approximately).

4. **No Slippage on Init**: Pool initialization is precise with no price impact.

5. **Most Supply Goes to Recipient**: Pool only retains what's needed for liquidity.

## Next Steps for Analysis

To get more complete metrics, consider testing:
- [ ] Non-1:1 starting prices (e.g., 0.5:1, 2:1)
- [ ] Asymmetric ranges (e.g., -240 to 0)
- [ ] Post-launch swap impact
- [ ] Gas costs for different configurations
- [ ] Multiple liquidity positions
- [ ] Different fee tiers (500, 3000, 10000 bps)