# Test Helper Contracts

This directory contains helper contracts used in testing the RemyVault protocol.

## Available Helpers

### ReentrancyAttacker.sol

A specialized contract designed to test the reentrancy protection mechanisms in the RemyVault protocol.

#### Key Features:

- **Attack Modes**: Configurable to attempt reentrancy during deposit or withdraw operations
- **Callback Exploitation**: Leverages `onERC721Received` callback to attempt reentry
- **Detection**: Includes event emission to track attack attempts
- **Owner Control**: Owner-only functions to configure attack parameters

#### How It Works:

1. **Deposit Attack**: When receiving an NFT during deposit, it tries to call deposit again, which should be blocked by the nonreentrant guard
2. **Withdraw Attack**: Similar concept for withdrawals, though harder to directly test due to safeTransferFrom behavior

#### Usage Example:

```solidity
// Create the attacker
ReentrancyAttacker attacker = new ReentrancyAttacker(
    address(vault),
    address(nft),
    address(token)
);

// Configure the attack
attacker.setTokenId(42);
attacker.setAttackOnDeposit(true);
attacker.approveAll();

// Execute the attack
attacker.attack(42);

// Verify the attack was unsuccessful
// The token balance should be exactly 1000 * 10^18 if reentrancy protection worked
assertEq(token.balanceOf(address(attacker)), 1000 * 10^18);
```

#### Extending For New Attack Vectors:

To test additional attack vectors:

1. Add new attack configuration flags
2. Implement the attack logic in the appropriate callback functions
3. Add verification logic in the test file

The contract is designed to be extensible for testing various security properties of the vault contract.