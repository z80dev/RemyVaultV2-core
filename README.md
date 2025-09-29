# RemyVault: NFT Fractionalization Protocol

RemyVault is a minimalist, gas-efficient NFT fractionalization protocol. The current core vault lives in Solidity (`RemyVault`) and lets users deposit ERC-721 NFTs to mint fungible ERC-20 tokens that track vault ownership.

## Overview

The system focuses on two production components:

1. **Core Vault (`RemyVault`)** – handles the NFT ↔ ERC20 mint/burn cycle
2. **Derivative & Liquidity Tooling** – `DerivativeFactory`, `RemyVaultNFT`, `MinterRemyVault`, and the Uniswap V4 hook wire the vault into on-chain markets

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

- `DerivativeFactory` mints new `RemyVaultNFT` collections and pairs them with freshly deployed `MinterRemyVault` instances.
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

RemyVault includes a custom Uniswap V4 hook (`RemyVaultHook`) that enables fractional token trading with hierarchical fee distribution:

- **Hierarchical Liquidity Pools**: Root pools (ETH/VaultToken) and child pools (ParentToken/DerivativeToken) form a fee-sharing network
- **Automatic Fee Distribution**: 10% fees on trades, split 75/25 between child and parent pools when hierarchies exist
- **Pool Topology Enforcement**: Root pools must include ETH; child pools share exactly one token with their parent
- **Fee Routing**: Captured fees are donated back to pools to reward liquidity providers
- **Gas Efficiency**: Optimized fee calculations with minimal overhead

This integration enables new DeFi primitives:
- **Automated Price Discovery**: AMM mechanics determine vault token prices against ETH and other tokens
- **Concentrated Liquidity**: Uniswap V4's tick ranges allow precise liquidity positioning for NFT collections
- **Cross-Collection Arbitrage**: Trade between parent and derivative vault tokens within the pool hierarchy
- **Passive Fee Income**: Liquidity providers earn from trading fees across the vault token ecosystem

**Note**: NFT fractionalization and redemption occur through vault `deposit`/`withdraw` functions. The hook manages token trading and fee routing within Uniswap pools.

## Technical Implementation

### Core Technology Stack
- **Languages**: Solidity for the core vault and derivative tooling, plus Vyper 0.4.3 for lightweight mocks used in tests
- **Architecture**: Modular design with clear separation of concerns
- **Standards**: ERC20, ERC721, ERC4626 compliant implementations where applicable
- **Testing Framework**: Comprehensive Foundry test suite with deterministic builds

### Security Posture
- The Solidity vault mirrors WETH-style semantics: minting and burning are guarded only by real inventory
- Factories deploy vaults deterministically via CREATE2 with no upgrade hooks or owner keys
- Derivative tooling (factories, hooks) layers ownership where needed for routing and pool management
- Invariant-based Foundry tests assert that ERC20 supply always matches escrowed NFT count
*Legacy migration contracts now live in the separate `RemyVaultV1Migration` repository.*

## Smart Contract Documentation

### RemyVault.sol
Solidity vault that locks a collection, mints `UNIT` (1e18) REMY per NFT deposit, burns on withdrawal, and exposes deterministic quoting helpers to enforce the 1:1 backing invariant. Deposit and withdraw events mirror each inventory mutation for downstream accounting. Extends `RemyVaultEIP712` to provide ERC20 functionality with EIP-2612 permit support for gasless approvals.

### RemyVaultFactory.sol
Factory contract that deploys deterministic `RemyVault` instances using CREATE2, keyed by ERC721 collection address. Enforces one-vault-per-collection invariant and prevents circular references (a vault cannot be used as a collection for another vault). Provides address prediction before deployment and supports both standard `RemyVault` and derivative `MinterRemyVault` deployments. The factory maintains `vaultFor` mapping (collection → vault) and `isVault` flag to prevent vault address reuse.

### MinterRemyVault.sol
Derivative vault variant extending `RemyVault` that pre-mints its full token supply (maxSupply × 1e18) at construction. Users burn vault tokens to mint new derivative NFTs (via `RemyVaultNFT`). Enforces supply caps through `mintedCount` tracking. Supports the standard deposit/withdraw cycle for derivative NFTs, enabling recursive fractionalization patterns.

### DerivativeFactory.sol
Orchestrates full derivative ecosystem deployment: creates NFT collections (`RemyVaultNFT`), deploys derivative vaults (`MinterRemyVault`), registers root pools (ETH/ParentToken) and child pools (ParentToken/DerivativeToken) in Uniswap V4, and seeds initial liquidity. Manages ownership transfer, minter permissions, and token distribution. Handles refunds when liquidity provisioning consumes less than provided. Requires hook ownership to configure fee-sharing hierarchy.

### RemyVaultHook.sol
Uniswap V4 hook extending `BaseHook` that captures fees on swaps involving vault tokens and distributes them across the pool hierarchy. Implements:
- **Fee Structure**: 10% total fee (1000 bps) on trades
- **Fee Splitting**: Child pools retain 75%, parent pools receive 25% when hierarchies exist
- **Pool Topology**: Root pools must pair with ETH; child pools cannot use ETH and must share exactly one token with their parent
- **Fee Distribution**: Fees donated back to pools to reward liquidity providers

**Note**: The hook manages fee routing between pools, not direct NFT trading within Uniswap. NFT↔token conversion happens through vault deposit/withdraw functions.

### RemyVaultNFT.sol
Enumerable ERC721 with minter permission system for derivative NFT collections. Supports batch minting/burning, per-token URI customization, and base URI management. Implements ERC721Enumerable through internal tracking (`_allTokens`, `_ownedTokens`) for efficient iteration. Ownership and minter permissions independently manageable for flexible collection governance.

### Migration Tooling
Contracts that interact with RemyVault V1 (e.g., the migrator and rescue router) have moved to the dedicated [`RemyVaultV1Migration`](../RemyVaultV1Migration) repository so this codebase can remain focused on the V2 primitive and new ecosystem modules.

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
