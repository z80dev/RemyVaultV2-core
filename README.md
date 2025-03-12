# RemyVault: NFT Fractionalization Protocol

RemyVault is a minimalist, gas-efficient NFT fractionalization protocol written in Vyper 0.4.0. The core vault enables users to deposit ERC-721 NFTs and receive fungible ERC-20 tokens representing fractional ownership of those NFTs.

## Core Overview

RemyVault Core implements a simple mechanism for NFT fractionalization:

1. Users deposit their NFTs into the vault
2. For each NFT, they receive 1000 ERC-20 tokens (with 18 decimals of precision)
3. These tokens can be traded, transferred, or used in DeFi protocols
4. Token holders can redeem their tokens for NFTs at any time

### Key Features

- **Simple Deposit/Withdraw**: Straightforward mechanics for fractionalization and redemption
- **Batch Operations**: Support for depositing and withdrawing multiple NFTs in a single transaction
- **Gas Efficient**: Written in Vyper 

### How It Works

#### Deposit
When a user deposits an NFT:
1. The NFT(s) is transferred to the vault
2. The vault mints 1000 ERC-20 tokens (with 18 decimals) per deposited NFT to the recipient
3. A `Minted` event is emitted with details

#### Withdrawal
To withdraw an NFT:
1. User must have 1000 ERC-20 tokens per NFT they wish to withdraw
2. Tokens are transferred to the vault and burned
3. The NFT is transferred to the recipient
4. A `Redeemed` event is emitted

### Key Functions
```vyper
interface IRemyVault:
    def deposit(tokenId: uint256, recipient: address)
    def batchDeposit(tokenIds: DynArray[uint256, 100], recipient: address) -> uint256
    def withdraw(tokenId: uint256, recipient: address)
    def batchWithdraw(tokenIds: DynArray[uint256, 100], recipient: address) -> uint256
```

``` solidity
interface IRemyVault {
    function deposit(uint256 tokenId, address recipient) external;
    function batchDeposit(uint256[] calldata tokenIds, address recipient) external returns (uint256);
    function withdraw(uint256 tokenId, address recipient) external;
    function batchWithdraw(uint256[] calldata tokenIds, address recipient) external returns (uint256);
}
```


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
