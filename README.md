# wNFT: NFT Fractionalization Protocol

wNFT is a minimalist, gas-efficient NFT fractionalization protocol that enables permissionless conversion between ERC-721 NFTs and fungible ERC-20 tokens at a fixed 1:1 ratio (1 NFT = 1e18 tokens).

## Overview

The protocol consists of two core components:

1. **wNFT** – Fractionalization contract that handles NFT deposits and withdrawals, minting/burning ERC-20 tokens
2. **wNFTFactory** – Factory contract that deploys deterministic wNFT instances for any ERC-721 collection

The design prioritizes simplicity and composability. Each wNFT contract is a standalone fractionalization primitive that can be integrated into AMMs, lending protocols, or other DeFi systems.

## How wNFT Works

### Core Mechanics

The wNFT contract implements a straightforward deposit/withdraw cycle:

**Deposit**: Users transfer NFTs into the wNFT contract and receive fungible ERC-20 tokens in return. Each deposited NFT mints exactly 1e18 tokens (18 decimals, mirroring standard ERC-20 conventions).

**Withdraw**: Users burn tokens to retrieve specific NFTs from the contract. Withdrawing requires burning 1e18 tokens per NFT.

### Key Properties

- **Fixed Exchange Rate**: Always 1e18 tokens per NFT, hardcoded as `UNIT`
- **Permissionless**: No owner or admin; anyone can deposit or withdraw
- **Non-custodial**: Users maintain full control through token ownership
- **Deterministic**: Token supply always equals (NFT count × 1e18)
- **Composable**: Standard ERC-20 interface enables DeFi integration
- **Auditable**: Events track every deposit/withdrawal for reconciliation

### Example Flow

```solidity
// 1. Deposit 3 NFTs (tokenIds: 42, 100, 200)
nft.setApprovalForAll(address(wNFT), true);
uint256[] memory tokenIds = [42, 100, 200];
wNFT.deposit(tokenIds, msg.sender);
// Result: User receives 3e18 wNFT tokens

// 2. Later, withdraw 1 specific NFT
uint256[] memory withdrawIds = [42];
wNFT.withdraw(withdrawIds, msg.sender);
// Result: User burns 1e18 tokens, receives NFT #42
```

### Technical Details

**Token Minting**: Uses Solady's gas-optimized ERC-20 implementation with EIP-2612 permit support for gasless approvals.

**NFT Transfers**: Uses `safeTransferFrom` on withdrawal to ensure recipient contracts can handle ERC-721 tokens. On deposit, uses standard `transferFrom` after checking approval.

**Reentrancy Protection**: Follows checks-effects-interactions pattern. Withdraw burns tokens before transferring NFTs, preventing reentrancy attacks.

**Metadata**: Each wNFT automatically generates a name and symbol by prefixing the underlying collection's metadata (e.g., "Wrapped CryptoPunks" → "wCryptoPunks").

## wNFTFactory

### Purpose

The factory deploys wNFT contracts deterministically using CREATE2, ensuring that each ERC-721 collection has exactly one canonical wNFT contract with a predictable address.

### Key Features

**Deterministic Deployment**: Uses the collection address as the CREATE2 salt, so the wNFT address can be computed before deployment:

```solidity
address predictedAddress = factory.computeAddress(collectionAddress);
// Deploy creates contract at this exact address
address deployed = factory.create(collectionAddress);
assert(deployed == predictedAddress);
```

**One-Per-Collection Invariant**: The factory maintains a `wNFTFor` mapping that prevents duplicate deployments:

```solidity
mapping(address => address) public wNFTFor;  // collection → wNFT
mapping(address => bool) public iswNFT;      // prevents circular references
```

**Circular Reference Prevention**: A wNFT contract itself cannot be used as a collection for another wNFT, preventing confusing nested structures.

### Usage

```solidity
// Deploy a new wNFT for CryptoPunks
address wNFTAddress = factory.create(0xb47e3cd837dDF8e4c57F05d70Ab865de6e193BBB);

// Query existing deployments
address existing = factory.wNFTFor(collectionAddress);
bool isWNFT = factory.iswNFT(someAddress);
```

### Interface

```solidity
interface IwNFTFactory {
    // Deploy a new wNFT contract for the given collection
    function create(address collection) external returns (address wNFTAddr);

    // Compute the address before deployment
    function computeAddress(address collection) external view returns (address);

    // Query deployed wNFT for a collection
    function wNFTFor(address collection) external view returns (address);

    // Check if an address is a wNFT contract
    function iswNFT(address addr) external view returns (bool);
}

event wNFTCreated(address indexed collection, address indexed wNFT);
```

## Benefits

### For NFT Holders
- **Instant Liquidity**: Convert illiquid NFTs into fungible tokens
- **Partial Exposure**: Sell fractions while maintaining some exposure
- **Composability**: Use tokens as collateral, in liquidity pools, or for yield farming

### For Traders
- **Fractional Trading**: Trade exposure without buying entire NFTs
- **Deeper Markets**: More granular price discovery
- **Arbitrage**: Balance prices between wNFT tokens and NFT floor prices

### For Developers
- **Simple Integration**: Standard ERC-20 interface
- **Predictable Addresses**: CREATE2 deployment enables address precomputation
- **No Upgrades**: Immutable contracts, no admin keys
- **Deterministic Supply**: Token supply is always verifiable on-chain

## wNFT Interface

```solidity
interface IwNFT {
    // Deposit NFTs and mint tokens to recipient
    function deposit(uint256[] calldata tokenIds, address recipient)
        external returns (uint256 mintedAmount);

    // Burn tokens and withdraw NFTs to recipient
    function withdraw(uint256[] calldata tokenIds, address recipient)
        external returns (uint256 burnedAmount);

    // Calculate tokens minted for N NFTs (returns N × 1e18)
    function quoteDeposit(uint256 count) external pure returns (uint256);

    // Calculate tokens burned for N NFTs (returns N × 1e18)
    function quoteWithdraw(uint256 count) external pure returns (uint256);

    // Get underlying NFT collection address
    function erc721() external view returns (address);

    // Get token address (same as wNFT contract address)
    function erc20() external view returns (address);

    // Fixed mint/burn amount per NFT
    function UNIT() external view returns (uint256);
}

event Deposit(address indexed recipient, uint256[] tokenIds, uint256 erc20Amt);
event Withdraw(address indexed recipient, uint256[] tokenIds, uint256 erc20Amt);
```

## Technical Implementation

### Core Technology Stack
- **Language**: Solidity 0.8.26 (Cancun EVM)
- **ERC-20 Implementation**: Solady (gas-optimized)
- **EIP-712 Support**: Native permit signatures for gasless approvals
- **Deployment**: CREATE2 for deterministic addresses
- **Testing**: Foundry with comprehensive test coverage

### Security Design
- **No Upgrades**: Contracts are immutable once deployed
- **No Admin Keys**: Fully permissionless operation
- **Inventory-Backed**: Token supply is always backed 1:1 by escrowed NFTs
- **Reentrancy Safe**: Burns tokens before external calls on withdrawal
- **Invariant Testing**: Automated tests verify supply always equals inventory
- **Event Tracking**: All state changes emit events for off-chain monitoring

### Gas Optimization
- Uses Solady's assembly-optimized ERC-20 implementation
- Batch deposits/withdrawals in single transaction
- Minimal storage reads through immutable collection reference
- Efficient EIP-712 domain separator caching

## Installation and Testing

This project uses [Foundry](https://book.getfoundry.sh/) for development and testing.

```bash
# Clone the repository
git clone https://github.com/yourusername/wnft
cd wnft

# Install dependencies
forge install

# Build contracts
forge build

# Run test suite
forge test

# Run tests with gas reporting
forge test --gas-report

# Run specific test file
forge test --match-contract wNFTTest
```

## Advanced: Derivatives Ecosystem

Beyond the core wNFT and factory, the protocol includes advanced tooling for creating derivative NFT collections with integrated liquidity:

### DerivativeFactory

Orchestrates deployment of derivative NFT collections with automatic Uniswap V4 pool creation and liquidity provisioning. Creates:
- New ERC-721 collection (`wNFTNFT`)
- Derivative wNFT contract (`MinterwNFT`)
- Root pool (ETH/ParentToken) and child pool (ParentToken/DerivativeToken)
- Initial liquidity seeding with fee-sharing hierarchy

### MinterwNFT

Variant of wNFT that pre-mints its full token supply at construction. Users burn tokens to mint derivative NFTs, enabling supply-capped derivative collections.

### wNFTHook

Uniswap V4 hook that captures trading fees and distributes them across a pool hierarchy:
- **Fee Structure**: 10% total fee on swaps
- **Fee Splitting**: 75% to child pools, 25% to parent pools
- **Topology**: Root pools pair with ETH, child pools connect to parent tokens
- **Distribution**: Fees donated back to pools to reward liquidity providers

### wNFTNFT

Enumerable ERC-721 implementation with minter permissions for derivative collections. Supports batch minting/burning and per-token URI customization.

### Use Cases

**Derivative Collections**: Launch new NFT collections (e.g., "Mutant" variants) that inherit liquidity from parent collections.

**Cross-Collection Trading**: Trade between parent and derivative tokens within Uniswap V4 pools.

**Fee Income**: Liquidity providers earn fees across the hierarchical pool network.

**Note**: These contracts are production-ready but represent advanced use cases. Most integrations only need the core wNFT and wNFTFactory contracts.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the LICENSE file for details.

---

For more information or to report issues, please open an issue in the GitHub repository.
