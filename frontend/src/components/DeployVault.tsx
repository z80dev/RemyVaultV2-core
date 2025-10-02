'use client';

import { useState } from 'react';
import { useWriteContract, useWaitForTransactionReceipt } from 'wagmi';
import { wNFTFactoryAbi } from '@/abis';
import { CONTRACTS } from '@/config/contracts';

export function DeployVault() {
  const [collectionAddress, setCollectionAddress] = useState('');

  const { data: hash, writeContract, isPending } = useWriteContract();

  const { isLoading: isConfirming, isSuccess, data: receipt } = useWaitForTransactionReceipt({
    hash,
  });

  const handleDeploy = () => {
    if (!collectionAddress.trim()) return;

    writeContract({
      address: CONTRACTS.wNFTFactory,
      abi: wNFTFactoryAbi,
      functionName: 'create',
      args: [collectionAddress as `0x${string}`],
    });
  };

  return (
    <div className="card">
      <h3>Deploy New Vault</h3>
      <div className="form-group">
        <label>NFT Collection Address:</label>
        <input
          type="text"
          value={collectionAddress}
          onChange={(e) => setCollectionAddress(e.target.value)}
          placeholder="0x..."
          disabled={isPending || isConfirming}
        />
      </div>
      <button
        onClick={handleDeploy}
        disabled={!collectionAddress.trim() || isPending || isConfirming}
      >
        {isPending ? 'Confirming...' : isConfirming ? 'Deploying...' : 'Deploy Vault'}
      </button>
      {isSuccess && (
        <p className="success">
          Vault deployed successfully! Check transaction for vault address.
        </p>
      )}
    </div>
  );
}
