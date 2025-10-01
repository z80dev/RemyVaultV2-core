'use client';

import { useState } from 'react';
import { useAccount, useWriteContract, useWaitForTransactionReceipt } from 'wagmi';
import { wNFTAbi } from '@/abis';

interface VaultWithdrawProps {
  vaultAddress: `0x${string}`;
}

export function VaultWithdraw({ vaultAddress }: VaultWithdrawProps) {
  const { address } = useAccount();
  const [tokenIds, setTokenIds] = useState<string>('');

  const { data: hash, writeContract, isPending } = useWriteContract();

  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({
    hash,
  });

  const handleWithdraw = () => {
    if (!address || !tokenIds.trim()) return;

    const ids = tokenIds.split(',').map(id => BigInt(id.trim()));

    writeContract({
      address: vaultAddress,
      abi: wNFTAbi,
      functionName: 'withdraw',
      args: [ids, address],
    });
  };

  return (
    <div className="card">
      <h3>Withdraw NFTs</h3>
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
        onClick={handleWithdraw}
        disabled={!address || !tokenIds.trim() || isPending || isConfirming}
      >
        {isPending ? 'Confirming...' : isConfirming ? 'Processing...' : 'Withdraw'}
      </button>
      {isSuccess && <p className="success">Withdrawal successful!</p>}
    </div>
  );
}
