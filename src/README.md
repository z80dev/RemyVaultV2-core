# RemyVaultHook for Uniswap v4

## Overview

RemyVaultHook is a Uniswap v4 hook that enables trading NFTs through a liquidity pool by leveraging RemyVault's NFT tokenization system. It allows users to buy and sell NFTs using standard token swaps, creating a seamless trading experience that benefits from Uniswap's concentrated liquidity.

## Key Features

- **NFT Trading on Uniswap**: Trade NFTs directly through Uniswap v4 liquidity pools
- **Managed NFT Inventory**: Hook maintains its own inventory of NFTs available for purchase
- **ETH Fee Collection**: Buy fees are collected in ETH, no sell fees to enable free token trading
- **Direct Trading**: External functions for direct buying/selling of NFTs from the hook

## How It Works

### Trading Flow

1. **Buying NFTs**:
   - Users swap tokens for vault tokens through a Uniswap v4 pool
   - The hook transfers an NFT from its inventory to the user
   - A buy fee is collected in ETH

2. **Selling NFTs**:
   - Users can sell NFTs to the hook using the `sellNFTs` function
   - The NFTs are deposited into RemyVault to mint vault tokens
   - User receives full payment in vault tokens (no sell fee)

### Inventory Management

The hook maintains its own inventory of NFTs available for trading, which can be:
- Added by the owner using `addNFTsToInventory`
- Redeemed from RemyVault using `redeemNFTsFromVault`
- Acquired from users who sell NFTs to the hook

## Security Considerations

- The hook enforces permissions to ensure only authorized users can manage inventory and fees
- Fees are collected in vault tokens and can be withdrawn by the owner or fee recipient
- NFT transfer functions include safety checks to prevent unauthorized access

## Contract Structure

- **RemyVaultHook.sol**: Main hook implementation
- **RemyVaultSol.sol**: Core vault contract for NFT fractionalization
- **IRemyVault.sol**: Interface to interact with RemyVault

## Setup and Deployment

1. Deploy RemyVault if not already deployed
2. Generate a valid hook address using HookMiner
3. Deploy RemyVaultHook with required parameters:
   - Pool Manager address
   - RemyVault address
   - Fee recipient address
   - Buy and sell fee percentages

## Integration with Uniswap v4

The hook works with Uniswap v4 pools that include the vault token as one of the pair currencies. It implements these hook callbacks:
- `beforeInitialize`: Validates pool setup
- `beforeSwap`: Prepares for token swaps
- `afterSwap`: Handles NFT transfers after swaps

## Fee Structure

- **Buy Fee**: Applied when users buy NFTs from the hook (default: 2.5%)
- **No Sell Fee**: Selling NFTs to the hook incurs no fee to enable free ERC20 trading
- Fees are collected in ETH and can be withdrawn using `collectETHFees`

## Example Usage

```solidity
// Buy NFTs directly from the hook
function buyNFTsExample(RemyVaultHook hook, uint256[] memory tokenIds) external {
    // Approve tokens for the hook
    IERC20(hook.vaultToken()).approve(address(hook), 10 ether);
    
    // Buy NFTs from the hook and pay ETH fee
    uint256 ethFee = 0.1 ether; // Calculated based on token amount and fee percentage
    hook.buyNFTs{value: ethFee}(tokenIds);
}

// Sell NFTs to the hook
function sellNFTsExample(RemyVaultHook hook, uint256[] memory tokenIds) external {
    // Approve NFTs for the hook
    IERC721(hook.nftCollection()).setApprovalForAll(address(hook), true);
    
    // Sell NFTs to the hook
    hook.sellNFTs(tokenIds);
}
```

## License

MIT License
