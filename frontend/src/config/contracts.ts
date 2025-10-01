// Contract addresses on Base Mainnet
// TODO: Replace with actual deployed contract addresses
export const CONTRACTS = {
  wNFTFactory: '0x0000000000000000000000000000000000000000' as `0x${string}`,
  DerivativeFactory: '0x0000000000000000000000000000000000000000' as `0x${string}`,
  wNFTHook: '0x0000000000000000000000000000000000000000' as `0x${string}`,
  PoolManager: '0x0000000000000000000000000000000000000000' as `0x${string}`,
} as const;

export type ContractName = keyof typeof CONTRACTS;
