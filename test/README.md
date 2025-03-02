# RemyVaultV2 Test Suite

This directory contains the comprehensive test suite for the RemyVault protocol.

## Overview

The RemyVault protocol is a vault system allowing users to deposit ERC721 tokens (NFTs) and receive ERC20 tokens in return at a fixed exchange rate. The core invariant of the system is that the total ERC20 token supply always equals the number of NFTs held by the vault multiplied by the UNIT value (1000 * 10^18).

## Test Files

- **RemyVault.t.sol**: Main test file covering all core functionality and security properties
- **helpers/ReentrancyAttacker.sol**: Helper contract used to test reentrancy protection

## Test Categories

The test suite covers several key categories:

1. **Basic Functionality Tests**
   - Deposit/withdraw single tokens
   - Batch operations
   - Token balances and transfers

2. **Edge Cases**
   - Empty arrays
   - Max token limits
   - Different recipient addresses

3. **Security Tests**
   - Reentrancy protection
   - Proper authorization checks
   - Approval requirements

4. **Invariant Tests**
   - Token supply relationship to NFT balance

## Running Tests

```bash
# Run all tests
forge test

# Run specific test
forge test --match-test testDeposit

# Run with verbose output
forge test -vv

# Run with gas reporting
forge test --gas-report
```

## Security Focus

The test suite includes specialized tests for reentrancy vulnerabilities:

- **Deposit Reentrancy**: Testing attempts to call deposit again during the deposit process
- **Withdrawal Reentrancy**: Testing proper token burning and NFT transfer during withdrawals

## Extending the Test Suite

When adding new features to the protocol, be sure to:

1. Add tests for the new functionality
2. Verify edge cases and failure modes
3. Confirm the core invariant is maintained

The `ReentrancyAttacker` contract can be extended to test other attack vectors as needed.
