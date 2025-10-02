'use client';

import { useState } from 'react';
import { ConnectWallet } from '@/components/ConnectWallet';
import { VaultInfo } from '@/components/VaultInfo';
import { VaultDeposit } from '@/components/VaultDeposit';
import { VaultWithdraw } from '@/components/VaultWithdraw';
import { DeployVault } from '@/components/DeployVault';

export default function App() {
  const [vaultAddress, setVaultAddress] = useState<`0x${string}` | ''>('');

  return (
    <main className="container">
      <header>
        <h1>wNFT</h1>
        <ConnectWallet />
      </header>

      <section className="section">
        <h2>Deploy New wNFT</h2>
        <DeployVault />
      </section>

      <section className="section">
        <h2>Interact with wNFT</h2>
        <div className="card">
          <div className="form-group">
            <label>wNFT Address:</label>
            <input
              type="text"
              value={vaultAddress}
              onChange={(e) => setVaultAddress(e.target.value as `0x${string}`)}
              placeholder="0x..."
            />
          </div>
        </div>

        {vaultAddress && (
          <>
            <VaultInfo vaultAddress={vaultAddress} />
            <VaultDeposit vaultAddress={vaultAddress} />
            <VaultWithdraw vaultAddress={vaultAddress} />
          </>
        )}
      </section>

      <section className="section">
        <h2>About wNFT</h2>
        <div className="card">
          <p>
            wNFT is a minimalist, gas-efficient NFT fractionalization protocol that lets
            you:
          </p>
          <ul>
            <li>
              <strong>Deposit NFTs:</strong> Deposit your NFTs in a wNFT contract and receive
              fungible ERC20 tokens (1 NFT = 1 token)
            </li>
            <li>
              <strong>Withdraw NFTs:</strong> Burn tokens to retrieve specific NFTs from
              the wNFT contract
            </li>
            <li>
              <strong>Trade wNFTs:</strong> Exchange fractional ownership via AMM
              pools with integrated liquidity
            </li>
          </ul>
        </div>
      </section>
    </main>
  );
}
