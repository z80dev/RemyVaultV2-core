# RemyVault: NFT Fractionalization Protocol

RemyVault is a minimalist, gas-efficient NFT fractionalization protocol written in Vyper 0.4.0. The core vault enables users to deposit ERC-721 NFTs and receive fungible ERC-20 tokens representing fractional ownership of those NFTs.

## Overview

RemyVault is designed as a modular, extensible system for NFT financialization. It consists of two main layers:

1. **Core Vault (RemyVault)**: The base layer handling NFT fractionalization
2. **Metavaults**: Specialized vaults built on top that implement specific strategies

This separation of concerns allows the core fractionalization mechanism to remain simple and secure, while enabling complex functionality to be built on top.

## Core Vault

RemyVault Core implements a simple mechanism for NFT fractionalization:

### Purpose
The core vault (RemyVault.vy) serves one fundamental purpose: converting NFTs into fungible ERC20 tokens at a fixed rate.

### Mechanics
- Users deposit NFTs and receive 1000 REMY tokens per NFT
- These tokens are fully backed 1:1 by NFTs in the vault
- Users can always redeem 1000 REMY tokens for an NFT
- This creates a baseline "floor price" unit of account: 1000 REMY = 1 NFT

### Key Properties
- **Simplicity**: The core vault does one thing and does it well
- **Reliability**: No complex price discovery or valuation mechanisms
- **Composability**: Creates a fungible token that other protocols can build upon
- **Redeemability**: Always maintains 1:1 backing of tokens to NFTs
- **Gas Efficient**: Written in Vyper

### Key Functions
```vyper
interface IRemyVault:
    def deposit(tokenIds: DynArray[uint256, 100], recipient: address) -> uint256
    def withdraw(tokenIds: DynArray[uint256, 100], recipient: address) -> uint256
```

``` solidity
interface IRemyVault {
    function deposit(uint256[] calldata tokenIds, address recipient) external returns (uint256);
    function withdraw(uint256[] calldata tokenIds, address recipient) external returns (uint256);
}
```

## Metavault Layer

Metavaults are specialized contracts that build upon the core vault's functionality to implement specific strategies or features. They treat the core vault's exchange rate (1000 REMY = 1 NFT) as a standardized unit of value.

### Example: InventoryMetavault

Our first implementation (InventoryMetavault.vy) demonstrates the power of this architecture. An InventoryMetavault can hold desirable NFT inventory (rare traits, etc.) and sell them at a premium to current floor price.

#### Strategy
- Maintains its own inventory of NFTs
- Sells NFTs at a 10% premium above floor price
- Distributes profits to all depositors

#### Mechanics
1. Users deposit NFTs and receive shares in an ERC4626 vault
2. When someone buys an NFT from inventory:
   - They pay 1100 REMY (1000 REMY floor price + 100 REMY premium)
   - 1000 REMY is retained as backing, replacing the NFT that was purchased.
   - 100 REMY premium is distributed to all depositors via the ERC4626 vault

#### Benefits
- Depositors earn yield from NFT sales
- Buyers get immediate liquidity
- The vault maintains a liquid inventory of NFTs
- Premium pricing is clearly defined relative to floor

### Power of the Metavault Pattern

This architecture enables numerous possible metavault strategies:

1. **Lending Vaults**
   - Use fractionalized NFTs as collateral
   - Implement specific liquidation strategies

2. **Trading Vaults**
   - Algorithmic buying/selling of NFTs
   - Dynamic pricing mechanisms

3. **Yield Vaults**
   - Stake fractionalized NFTs in DeFi protocols
   - Distribute yield to depositors

4. **Index Vaults**
   - Create baskets of different NFT collections
   - Enable broad market exposure

5. **Options Vaults**
   - Write covered calls on NFTs
   - Implement complex derivatives strategies

6. **DerivativeVaults**
   - Issue new NFTs backed by REMY tokens
   - Create derivative collections with custom properties
   - Maintain refundability to original backing asset
   
Each metavault can:
- Implement its own tokenomics
- Define unique value capture mechanisms
- Create specific incentive structures
- Integrate with other DeFi protocols

#### DerivativeVaults

##### Key Mechanics
- Users deposit REMY tokens and receive derivative NFTs
- Custom exchange rates (e.g., 1 derivative NFT = 200 REMY)
- Small refund fee to prevent trait farming
- Fee distribution to derivative collection depositors

##### Applications
- Create "fractional" derivatives (e.g., 5 derivatives per original NFT)
- Create "bundled" derivatives (e.g., 1 derivative representing 5 original NFTs)
- Implement custom traits or generative aspects
- Add utility features to derivative collections

##### Composability
- Derivative collections can use their own InventoryMetavaults
- Derivatives can be used in other DeFi protocols
- Multiple derivative collections can be created from the same base collection
- Derivatives can be programmatically linked to original collection traits

##### Example: BundledCollectionVault
1. Issues 1 "Bundle NFT" for every 5000 REMY (5 original NFTs worth)
2. Each Bundle NFT has unique traits derived from a basket of the original collection
3. Bundles can be "unbundled" back to REMY for a small fee
4. Fees are distributed to Bundle NFT holders who stake in the BundleInventoryMetavault
5. Creates a higher price-point entry into the ecosystem

##### Example: MicroNFTVault
1. Issues 5 "Micro NFTs" for every 1000 REMY (1 original NFT worth)
2. Each Micro NFT has derived traits but at a lower price point
3. Can be redeemed for 200 REMY each (minus small fee)
4. Enables lower-cost participation in the collection
5. Creates more granular market exposure

This pattern demonstrates the recursive composability of the RemyVault architecture - 
not only can new metavaults be built on top of the core vault, but metavaults can 
also be built on top of other metavaults, creating a rich ecosystem of interconnected 
NFT financial products.



## System Benefits

This architectural approach provides several key advantages:

1. **Modularity**
   - Each component has a single responsibility
   - Metavaults can be added without changing core logic
   - Failures are contained within individual vaults

2. **Composability**
   - Core vault provides a stable building block
   - Metavaults can be layered and combined
   - Easy integration with existing DeFi protocols

3. **Flexibility**
   - New strategies can be implemented as metavaults
   - Different risk/reward profiles can be offered
   - Various market participants can be served

4. **Security**
   - Core logic remains simple and auditable
   - Complex strategies don't compromise base layer
   - Clear separation of concerns


## Installation and Testing

This project uses [Foundry](https://book.getfoundry.sh/) for development and testing. If you haven't installed Foundry yet, follow their [installation guide](https://book.getfoundry.sh/getting-started/installation).

```bash
# Build the project
forge build

# Run tests
forge test
```


## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the LICENSE file for details.

---

For more information or to report issues, please open an issue in the GitHub repository.
