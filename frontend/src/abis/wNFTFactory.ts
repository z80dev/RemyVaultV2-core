export const wNFTFactoryAbi = [
  {
    type: 'function',
    name: 'computeAddress',
    inputs: [{ name: 'collection', type: 'address', internalType: 'address' }],
    outputs: [{ name: '', type: 'address', internalType: 'address' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    name: 'create',
    inputs: [{ name: 'collection', type: 'address', internalType: 'address' }],
    outputs: [{ name: 'wNFTAddr', type: 'address', internalType: 'address' }],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    name: 'iswNFT',
    inputs: [{ name: '', type: 'address', internalType: 'address' }],
    outputs: [{ name: '', type: 'bool', internalType: 'bool' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    name: 'wNFTFor',
    inputs: [{ name: '', type: 'address', internalType: 'address' }],
    outputs: [{ name: '', type: 'address', internalType: 'address' }],
    stateMutability: 'view',
  },
  {
    type: 'event',
    name: 'wNFTCreated',
    inputs: [
      { name: 'collection', type: 'address', indexed: true, internalType: 'address' },
      { name: 'wNFT', type: 'address', indexed: true, internalType: 'address' },
    ],
    anonymous: false,
  },
  {
    type: 'error',
    name: 'CollectionAddressZero',
    inputs: [],
  },
  {
    type: 'error',
    name: 'CollectionAlreadyDeployed',
    inputs: [{ name: 'collection', type: 'address', internalType: 'address' }],
  },
  {
    type: 'error',
    name: 'CollectionIswNFT',
    inputs: [{ name: 'wNFT', type: 'address', internalType: 'address' }],
  },
] as const;
