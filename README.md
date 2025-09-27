# RemyVault: NFT Fractionalization Protocol

RemyVault is a minimalist, gas-efficient NFT fractionalization protocol. The current core vault lives in Solidity (`RemyVault`) and lets users deposit ERC-721 NFTs to mint fungible ERC-20 tokens that track vault ownership.

## Overview

The system focuses on two production components:

1. **Core Vault (`RemyVault`)** – handles the NFT ↔ ERC20 mint/burn cycle
2. **Derivative & Liquidity Tooling** – `DerivativeFactory`, `RemyVaultNFT`, `DerivativeRemyVault`, and the Uniswap V4 hook wire the vault into on-chain markets

The separation keeps the fractionalization layer small while still enabling new collections and liquidity strategies to launch through the derivative factory.

## Key Advantages

### For NFT Holders
- **Instant Liquidity**: Convert illiquid NFTs into fungible REMY tokens
- **Partial Exposure**: Stay long NFTs without committing an entire token

### For Traders
- **Deeper Markets**: Trade fractional exposure instead of whole tokens
- **Arbitrage Windows**: Balance price between the vault token and on-chain pools

### For Protocols
- **Composable Primitive**: Integrate REMY as a staked or collateral asset
- **Deterministic Supply**: The vault always mints 1e18 REMY per NFT and burns on redemption

## Core Vault

`RemyVault` implements the ground-level fractionalization mechanics:

### Purpose
The vault converts NFTs into fungible ERC20 tokens at a fixed 1e18 REMY per NFT. It maintains the reverse operation so every ERC20 unit can unlock the underlying inventory.

### Mechanics
- Depositing transfers NFTs into the vault and mints REMY for the recipient
- Withdrawing burns REMY from the caller before safely returning each NFT
- Quoting functions expose deterministic pricing (`UNIT = 1e18`)

### Key Properties
- **Permissionless**: No owner or privileged address; anyone can deposit or withdraw against inventory
- **Simplicity**: Focuses solely on deposit/withdraw logic
- **Reliability**: No price or oracle dependency, only inventory-backed accounting
- **Composability**: Downstream contracts can reason about REMY supply deterministically
- **Traceability**: Emits structured `Deposit`/`Withdraw` events for off-chain reconciliation

### Interface
```solidity
interface IRemyVault {
    function deposit(uint256[] calldata tokenIds, address recipient) external returns (uint256);
    function withdraw(uint256[] calldata tokenIds, address recipient) external returns (uint256);
    function quoteDeposit(uint256 count) external pure returns (uint256);
    function quoteWithdraw(uint256 count) external pure returns (uint256);
}
```

## Derivative Factory & Vault NFTs

The derivative toolchain extends the vault without modifying core logic:

- `DerivativeFactory` mints new `RemyVaultNFT` collections and pairs them with freshly deployed `DerivativeRemyVault` instances.
- Root and child pools are registered with `RemyVaultHook` to share liquidity across Uniswap V4 markets.
- Metadata and minter permissions are configured at deployment time so launch scripts can tailor new drops.

These pieces let integrators spin up their own NFT wrappers while inheriting the redemption guarantees of the base vault.

## System Benefits

A trimmed surface area keeps the protocol auditable while still supporting growth:

1. **Modularity** – Core vault code stays unchanged while derivative tooling evolves independently
2. **Composability** – REMY tokens can flow into AMMs, staking contracts, or collateral systems
3. **Flexibility** – New derivative collections or hooks can launch with factory calls instead of redeploying the base logic
4. **Security** – Fewer contracts reduce the attack surface and simplify auditing

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
- **Languages**: Solidity for the core vault and derivative tooling, Vyper 0.4.3 for legacy routers and migration helpers
- **Architecture**: Modular design with clear separation of concerns
- **Standards**: ERC20, ERC721, ERC4626 compliant implementations where applicable
- **Testing Framework**: Comprehensive Foundry test suite with deterministic builds

### Security Posture
- The Solidity vault mirrors WETH-style semantics: minting and burning are guarded only by real inventory
- Factories deploy vaults deterministically via CREATE2 with no upgrade hooks or owner keys
- Derivative tooling (factories, hooks) layers ownership where needed for routing and pool management
- Invariant-based Foundry tests assert that ERC20 supply always matches escrowed NFT count
- Migration and rescue flows interact with legacy RemyVault V1 strictly through interfaces in this repo

## Smart Contract Documentation

### RemyVault.sol
Solidity vault that locks a collection, mints `UNIT` (1e18) REMY per NFT deposit, burns on withdrawal, and exposes deterministic quoting helpers to enforce the 1:1 backing invariant. Deposit and withdraw events mirror each inventory mutation for downstream accounting.

### RescueRouterV2.vy
Updated router used by v2 flows. Adds direct token-for-NFT swaps (`swap_tokens_for_nfts`), richer quoting helpers, internal mint fee accounting, and improved ETH refund logic while retaining staking, unstaking, and Uniswap V3 bridging routines.

### Migrator.vy
Bridges users from RemyVault v1 to v2. It pulls REMY v1, redeems available NFTs through `RescueRouterV2`, deposits them into the new vault to mint REMY v2, and forwards any leftover balance 1:1. Emits detailed migration events and enforces balance invariants.

### RemyVaultHook.sol
Uniswap V4 hook extending `BaseHook` to let liquidity pools swap NFTs against REMY directly. Manages hook permissions, validates pools, tracks NFT inventory, and exposes manual controls (`sellNFTs`, `buyNFTs`, `addNFTsToInventory`, `collectETHFees`, etc.) so operators can seed or drain inventory and adjust fees.

### Test Helpers
`src/mock/` contains lightweight ERC-20 and ERC-721 mocks for Foundry tests, and `src/interfaces/` ships the minimal ABI surfaces (ERC standards plus project-specific interfaces) consumed across the ecosystem.

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
