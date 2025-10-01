'use client';

import { useState } from 'react';
import { useAccount, useWriteContract, useWaitForTransactionReceipt } from 'wagmi';
import { wNFTMinterAbi } from '@/abis';

interface MintDerivativeProps {
  vaultAddress: `0x${string}`;
}

export function MintDerivative({ vaultAddress }: MintDerivativeProps) {
  const { address } = useAccount();
  const [count, setCount] = useState('1');

  const { data: hash, writeContract, isPending } = useWriteContract();

  const { isLoading: isConfirming, isSuccess } = useWaitForTransactionReceipt({
    hash,
  });

  const handleMint = () => {
    if (!address || !count) return;

    writeContract({
      address: vaultAddress,
      abi: wNFTMinterAbi,
      functionName: 'mint',
      args: [BigInt(count), address],
    });
  };

  return (
    <div className="card">
      <h3>Mint Derivative NFTs</h3>
      <div className="form-group">
        <label>Number of NFTs to mint:</label>
        <input
          type="number"
          min="1"
          value={count}
          onChange={(e) => setCount(e.target.value)}
          disabled={isPending || isConfirming}
        />
      </div>
      <button
        onClick={handleMint}
        disabled={!address || !count || isPending || isConfirming}
      >
        {isPending ? 'Confirming...' : isConfirming ? 'Minting...' : 'Mint'}
      </button>
      {isSuccess && <p className="success">Minted successfully!</p>}
      <p className="info-text">
        Note: This burns vault tokens to mint NFTs. Make sure you have sufficient balance.
      </p>
    </div>
  );
}
