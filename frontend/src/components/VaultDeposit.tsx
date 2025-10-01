'use client';

import { useState } from 'react';
import { useAccount, useWriteContract, useWaitForTransactionReceipt } from 'wagmi';
import { parseUnits } from 'viem';
import { wNFTAbi } from '@/abis';

interface VaultDepositProps {
  vaultAddress: `0x${string}`;
}

export function VaultDeposit({ vaultAddress }: VaultDepositProps) {
  const { address } = useAccount();
  const [tokenIds, setTokenIds] = useState<string>('');

  const { data: hash, writeContract, isPending } = useWriteContract();

  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({
    hash,
  });

  const handleDeposit = () => {
    if (!address || !tokenIds.trim()) return;

    const ids = tokenIds.split(',').map(id => BigInt(id.trim()));

    writeContract({
      address: vaultAddress,
      abi: wNFTAbi,
      functionName: 'deposit',
      args: [ids, address],
    });
  };

  return (
    <div className="card">
      <h3>Deposit NFTs</h3>
      <div className="form-group">
        <label>Token IDs (comma-separated):</label>
        <input
          type="text"
          value={tokenIds}
          onChange={(e) => setTokenIds(e.target.value)}
          placeholder="1, 2, 3"
          disabled={isPending || isConfirming}
        />
      </div>
      <button
        onClick={handleDeposit}
        disabled={!address || !tokenIds.trim() || isPending || isConfirming}
      >
        {isPending ? 'Confirming...' : isConfirming ? 'Processing...' : 'Deposit'}
      </button>
      {isSuccess && <p className="success">Deposit successful!</p>}
    </div>
  );
}
