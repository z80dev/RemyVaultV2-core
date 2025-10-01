'use client';

import { useReadContract, useAccount } from 'wagmi';
import { wNFTAbi } from '@/abis';
import { formatUnits } from 'viem';

interface VaultInfoProps {
  vaultAddress: `0x${string}`;
}

export function VaultInfo({ vaultAddress }: VaultInfoProps) {
  const { address } = useAccount();

  const { data: totalSupply } = useReadContract({
    address: vaultAddress,
    abi: wNFTAbi,
    functionName: 'totalSupply',
  });

  const { data: userBalance } = useReadContract({
    address: vaultAddress,
    abi: wNFTAbi,
    functionName: 'balanceOf',
    args: address ? [address] : undefined,
  });

  const { data: erc721Address } = useReadContract({
    address: vaultAddress,
    abi: wNFTAbi,
    functionName: 'erc721',
  });

  return (
    <div className="card">
      <h3>Vault Information</h3>
      <div className="info-grid">
        <div className="info-item">
          <span className="label">Vault Address:</span>
          <span className="value">
            {vaultAddress.slice(0, 6)}...{vaultAddress.slice(-4)}
          </span>
        </div>
        <div className="info-item">
          <span className="label">NFT Collection:</span>
          <span className="value">
            {erc721Address
              ? `${erc721Address.slice(0, 6)}...${erc721Address.slice(-4)}`
              : 'Loading...'}
          </span>
        </div>
        <div className="info-item">
          <span className="label">Total Supply:</span>
          <span className="value">
            {totalSupply !== undefined
              ? formatUnits(totalSupply, 18)
              : 'Loading...'}
          </span>
        </div>
        {address && (
          <div className="info-item">
            <span className="label">Your Balance:</span>
            <span className="value">
              {userBalance !== undefined
                ? formatUnits(userBalance, 18)
                : 'Loading...'}
            </span>
          </div>
        )}
      </div>
    </div>
  );
}
