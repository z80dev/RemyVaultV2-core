'use client';

import { useState } from 'react';
import { ConnectWallet } from '@/components/ConnectWallet';
import { VaultInfo } from '@/components/VaultInfo';
import { VaultDeposit } from '@/components/VaultDeposit';
import { VaultWithdraw } from '@/components/VaultWithdraw';
import { DeployVault } from '@/components/DeployVault';
import { MintDerivative } from '@/components/MintDerivative';

export default function App() {
  const [vaultAddress, setVaultAddress] = useState<`0x${string}` | ''>('');
  const [isDerivativeVault, setIsDerivativeVault] = useState(false);

  return (
    <main className="container">
      <header>
        <h1>wNFT Protocol</h1>
        <p className="subtitle">NFT Fractionalization on Base</p>
        <ConnectWallet />
      </header>

      <section className="section">
        <h2>Deploy New Vault</h2>
        <DeployVault />
      </section>

      <section className="section">
        <h2>Interact with Vault</h2>
        <div className="card">
          <div className="form-group">
            <label>Vault Address:</label>
            <input
              type="text"
              value={vaultAddress}
              onChange={(e) => setVaultAddress(e.target.value as `0x${string}`)}
              placeholder="0x..."
            />
          </div>
          <div className="form-group checkbox-group">
            <label>
              <input
                type="checkbox"
                checked={isDerivativeVault}
                onChange={(e) => setIsDerivativeVault(e.target.checked)}
              />
              Is this a derivative vault?
            </label>
          </div>
        </div>

        {vaultAddress && (
          <>
            <VaultInfo vaultAddress={vaultAddress} />
            {isDerivativeVault ? (
              <MintDerivative vaultAddress={vaultAddress} />
            ) : (
              <>
                <VaultDeposit vaultAddress={vaultAddress} />
                <VaultWithdraw vaultAddress={vaultAddress} />
              </>
            )}
          </>
        )}
      </section>

      <section className="section">
        <h2>About wNFT Protocol</h2>
        <div className="card">
          <p>
            wNFT is a minimalist, gas-efficient NFT fractionalization protocol that lets
            you:
          </p>
          <ul>
            <li>
              <strong>Deposit NFTs:</strong> Lock your NFTs in a vault and receive
              fungible ERC-20 tokens (1 NFT = 1e18 tokens)
            </li>
            <li>
              <strong>Withdraw NFTs:</strong> Burn tokens to retrieve specific NFTs from
              the vault
            </li>
            <li>
              <strong>Create Derivatives:</strong> Launch new collections with custom
              tokenomics and Uniswap V4 liquidity pools
            </li>
            <li>
              <strong>Trade Fractions:</strong> Exchange fractional ownership via AMM
              pools with hierarchical fee distribution
            </li>
          </ul>
          <p className="info-text">
            Note: Contract addresses are currently placeholders. Update them in{' '}
            <code>src/config/contracts.ts</code> after deployment.
          </p>
        </div>
      </section>
    </main>
  );
}
