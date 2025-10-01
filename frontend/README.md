# wNFT Protocol Frontend

A Next.js frontend application for interacting with the wNFT Protocol on Base Mainnet.

## Features

- **Wallet Connection**: Connect via RainbowKit with support for popular wallets
- **Vault Management**: Deploy new vaults for NFT collections
- **NFT Fractionalization**: Deposit NFTs to receive fungible tokens
- **NFT Redemption**: Burn tokens to withdraw specific NFTs
- **Derivative Minting**: Mint derivative NFTs from vault tokens
- **Real-time Data**: View vault information, balances, and transaction status

## Getting Started

### Prerequisites

- Node.js 18+
- npm or yarn
- A Web3 wallet (MetaMask, Coinbase Wallet, etc.)

### Installation

1. Install dependencies:
```bash
npm install
```

2. Create environment file:
```bash
cp .env.example .env.local
```

3. Get a WalletConnect Project ID:
   - Visit https://cloud.walletconnect.com
   - Create a new project
   - Copy your Project ID to `.env.local`

### Configuration

#### Update Contract Addresses

Before using the app, update the contract addresses in `src/config/contracts.ts` with your deployed contract addresses:

```typescript
export const CONTRACTS = {
  wNFTFactory: '0xYourFactoryAddress',
  DerivativeFactory: '0xYourDerivativeFactoryAddress',
  wNFTHook: '0xYourHookAddress',
  PoolManager: '0xYourPoolManagerAddress',
} as const;
```

#### Update WalletConnect Project ID

In `src/config/wagmi.ts`, replace `YOUR_PROJECT_ID` with your actual WalletConnect Project ID:

```typescript
export const config = getDefaultConfig({
  appName: 'wNFT Protocol',
  projectId: 'YOUR_WALLETCONNECT_PROJECT_ID',
  chains: [base],
  transports: {
    [base.id]: http(),
  },
});
```

### Running the App

Development mode:
```bash
npm run dev
```

Production build:
```bash
npm run build
npm start
```

Open [http://localhost:3000](http://localhost:3000) in your browser.

## Usage

### Deploying a Vault

1. Connect your wallet
2. Navigate to "Deploy New Vault"
3. Enter the NFT collection address
4. Click "Deploy Vault"
5. Confirm the transaction in your wallet

### Depositing NFTs

1. Enter a deployed vault address
2. Enter comma-separated token IDs (e.g., `1, 2, 3`)
3. Click "Deposit"
4. Approve the NFT transfer if prompted
5. Confirm the transaction

### Withdrawing NFTs

1. Enter the vault address
2. Enter token IDs to withdraw
3. Ensure you have enough vault tokens
4. Click "Withdraw"
5. Confirm the transaction

### Minting Derivatives

1. Enter a derivative vault address
2. Check "Is this a derivative vault?"
3. Enter the number of NFTs to mint
4. Click "Mint"
5. Confirm the transaction

## Project Structure

```
frontend/
├── src/
│   ├── abis/              # Contract ABIs
│   │   ├── wNFT.ts
│   │   ├── wNFTFactory.ts
│   │   ├── DerivativeFactory.ts
│   │   └── wNFTMinter.ts
│   ├── app/               # Next.js app directory
│   │   ├── layout.tsx
│   │   ├── page.tsx
│   │   ├── providers.tsx
│   │   └── globals.css
│   ├── components/        # React components
│   │   ├── ConnectWallet.tsx
│   │   ├── VaultInfo.tsx
│   │   ├── VaultDeposit.tsx
│   │   ├── VaultWithdraw.tsx
│   │   ├── DeployVault.tsx
│   │   └── MintDerivative.tsx
│   └── config/            # Configuration files
│       ├── wagmi.ts       # Wagmi/Viem config
│       └── contracts.ts   # Contract addresses
├── package.json
├── tsconfig.json
└── next.config.js
```

## Technologies

- **Next.js 14**: React framework with App Router
- **TypeScript**: Type-safe development
- **Wagmi**: React hooks for Ethereum
- **Viem**: TypeScript Ethereum library
- **RainbowKit**: Wallet connection UI
- **TanStack Query**: Async state management

## Network Configuration

This app is configured for Base Mainnet by default. To add additional networks, modify `src/config/wagmi.ts`:

```typescript
import { base, baseSepolia } from 'wagmi/chains';

export const config = getDefaultConfig({
  // ...
  chains: [base, baseSepolia],
  transports: {
    [base.id]: http(),
    [baseSepolia.id]: http(),
  },
});
```

## Troubleshooting

### Wallet Connection Issues

- Ensure you're on the Base network
- Clear browser cache and reconnect wallet
- Try a different wallet provider

### Transaction Failures

- Check you have sufficient ETH for gas
- Verify contract addresses are correct
- Ensure NFTs are approved for the vault

### Build Errors

- Delete `node_modules` and `.next` directories
- Run `npm install` again
- Check Node.js version (18+)

## Contributing

Contributions are welcome! Please open an issue or submit a pull request.

## License

MIT
