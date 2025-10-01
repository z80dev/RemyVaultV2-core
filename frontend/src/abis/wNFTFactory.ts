export const wNFTFactoryAbi = [
  {
    type: 'function',
    name: 'deployVault',
    inputs: [{ name: 'collection', type: 'address', internalType: 'address' }],
    outputs: [{ name: 'vault', type: 'address', internalType: 'address' }],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    name: 'deployDerivativeVault',
    inputs: [
      { name: 'collection', type: 'address', internalType: 'address' },
      { name: 'maxSupply', type: 'uint256', internalType: 'uint256' },
      { name: 'salt', type: 'bytes32', internalType: 'bytes32' },
    ],
    outputs: [{ name: 'vault', type: 'address', internalType: 'address' }],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    name: 'vaultFor',
    inputs: [{ name: 'collection', type: 'address', internalType: 'address' }],
    outputs: [{ name: '', type: 'address', internalType: 'address' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    name: 'isVault',
    inputs: [{ name: 'vault', type: 'address', internalType: 'address' }],
    outputs: [{ name: '', type: 'bool', internalType: 'bool' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    name: 'computeAddress',
    inputs: [{ name: 'collection', type: 'address', internalType: 'address' }],
    outputs: [{ name: '', type: 'address', internalType: 'address' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    name: 'computeDerivativeAddress',
    inputs: [
      { name: 'collection', type: 'address', internalType: 'address' },
      { name: 'maxSupply', type: 'uint256', internalType: 'uint256' },
      { name: 'salt', type: 'bytes32', internalType: 'bytes32' },
    ],
    outputs: [{ name: '', type: 'address', internalType: 'address' }],
    stateMutability: 'view',
  },
  {
    type: 'event',
    name: 'VaultCreated',
    inputs: [
      { name: 'collection', type: 'address', indexed: true, internalType: 'address' },
      { name: 'vault', type: 'address', indexed: true, internalType: 'address' },
    ],
    anonymous: false,
  },
  {
    type: 'error',
    name: 'CollectionAlreadyDeployed',
    inputs: [{ name: 'collection', type: 'address', internalType: 'address' }],
  },
  {
    type: 'error',
    name: 'CollectionAddressZero',
    inputs: [],
  },
  {
    type: 'error',
    name: 'CollectionIsVault',
    inputs: [{ name: 'vault', type: 'address', internalType: 'address' }],
  },
] as const;
