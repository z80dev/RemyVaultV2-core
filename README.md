# RemyVault: NFT Fractionalization Protocol

RemyVault is a minimalist, gas-efficient NFT fractionalization protocol written in Vyper 0.4.0. The core vault enables users to deposit ERC-721 NFTs and receive fungible ERC-20 tokens representing fractional ownership of those NFTs.

## Overview

RemyVault is designed as a modular, extensible system for NFT financialization. It consists of two main layers:

1. **Core Vault (RemyVault)**: The base layer handling NFT fractionalization
2. **Metavaults**: Specialized vaults built on top that implement specific strategies

This separation of concerns allows the core fractionalization mechanism to remain simple and secure, while enabling complex functionality to be built on top.

## Key Advantages

### For NFT Holders
- **Instant Liquidity**: Convert illiquid NFTs into tradable tokens
- **Yield Generation**: Earn premiums from NFT sales in InventoryMetavault
- **Partial Exposure**: Maintain exposure to NFT collections without 100% allocation

### For Traders
- **Reduced Barriers**: Trade fractional NFT positions with smaller capital requirements
- **Enhanced Liquidity**: Access deeper liquidity for popular NFT collections
- **Arbitrage Opportunities**: Exploit price differences between whole NFTs and fractions

### For Protocols
- **Composable Building Block**: Integrate fractionalized NFTs into existing DeFi products
- **New Market Mechanics**: Enable new types of NFT-related financial instruments
- **Standardized Value Units**: Use REMY tokens as consistent units of account

## Core Vault

``` mermaid
flowchart LR
    User([User])
    RemyVault[(RemyVault)]
    
    User -- 1\. Deposit ERC721 NFT #123 --> RemyVault
    RemyVault -- 2\. Mint & return 1000 REMY tokens --> User
    
    %% Styling
    classDef user fill:#f9f9f9,stroke:#333,stroke-width:2px
    classDef vault fill:#d0f0c0,stroke:#006400,stroke-width:2px
    
    class User user
    class RemyVault vault
```

`

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

## Metavault Ecosystem

Metavaults extend the core functionality through specialized strategies:

### Implemented Metavaults
#### InventoryMetavault
- **Strategy**: Sell NFTs at premium pricing with profit distribution
- **Premium Rate**: 10% markup on NFT floor price (configurable)
- **Profit Mechanism**: Premiums distributed to all depositors via ERC4626 shares
- **ERC4626 Compliance**: Full implementation of the tokenized vault standard

### Planned Metavaults

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
   
## Uniswap V4 Integration

RemyVault includes a custom Uniswap V4 hook that enables native NFT trading directly through Uniswap liquidity pools:

- **Direct NFT Trading**: Trade NFTs through token swaps with standard AMM logic
- **Buy/Sell Functionality**: Buy NFTs using any token supported by Uniswap
- **Inventory Management**: Automatic listing and management of NFTs in pools
- **Fee Collection**: Configurable fees for buying operations
- **Gas Efficiency**: Optimized trading paths for reduced gas costs

This integration creates completely new NFT trading mechanisms not possible in traditional marketplaces:
- Automated price discovery 
- Concentrated liquidity for NFT collections
- Arbitrage opportunities between fractional tokens and NFTs

## Technical Implementation

### Core Technology Stack
- **Language**: Vyper 0.4.0 for gas-efficient and secure smart contracts
- **Architecture**: Modular design with clear separation of concerns
- **Standards**: ERC20, ERC721, ERC4626 compliant implementations
- **Testing Framework**: Comprehensive Foundry test suite with 100% coverage

### Security Features
- Nonreentrant guards protecting against reentrancy attacks
- Access control for privileged operations
- Protocol-controlled token minting/burning with strict validation
- Proper checks-effects-interactions pattern implementation
- Invariant-based testing to verify fundamental protocol properties

## Smart Contract Documentation

### RemyVault.vy
The base layer fractionalization mechanism.

**Key Functions:**
- `deposit(tokenIds: DynArray[uint256, 100], recipient: address) -> uint256`: Deposit NFTs and receive REMY tokens
- `withdraw(tokenIds: DynArray[uint256, 100], recipient: address) -> uint256`: Redeem REMY tokens for NFTs
- `quoteDeposit(count: uint256) -> uint256`: Calculate tokens received for depositing NFTs
- `quoteWithdraw(count: uint256) -> uint256`: Calculate tokens required to withdraw NFTs

### InventoryMetavault.vy
Premium NFT sales strategy with profit distribution.

**Key Functions:**
- `deposit(token_ids: DynArray[uint256, 100], receiver: address) -> uint256`: Deposit NFTs and receive stMV shares
- `withdraw(token_ids: DynArray[uint256, 100], receiver: address) -> uint256`: Deposit stMV shares and receive NFTs
- `purchase(token_ids: DynArray[uint256, 100]) -> uint256`: Buy NFTs at premium pricing
- `redeem(shares_amount: uint256, receiver: address) -> uint256`: Redeem shares for assets

### RemyVaultHook.sol
Uniswap V4 integration for NFT trading.

**Key Functions:**
- `sellNFTs(tokenIds: uint256[])`: Sell NFTs to receive vault tokens
- `buyNFTs(tokenIds: uint256[])`: Buy NFTs using vault tokens plus ETH fee

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
