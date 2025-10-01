export const wNFTMinterAbi = [
  {
    type: 'constructor',
    inputs: [
      { name: 'erc721_', type: 'address', internalType: 'address' },
      { name: 'maxSupply_', type: 'uint256', internalType: 'uint256' },
    ],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    name: 'maxSupply',
    inputs: [],
    outputs: [{ name: '', type: 'uint256', internalType: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    name: 'mintedCount',
    inputs: [],
    outputs: [{ name: '', type: 'uint256', internalType: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    name: 'mint',
    inputs: [
      { name: 'count', type: 'uint256', internalType: 'uint256' },
      { name: 'recipient', type: 'address', internalType: 'address' },
    ],
    outputs: [{ name: 'tokenIds', type: 'uint256[]', internalType: 'uint256[]' }],
    stateMutability: 'nonpayable',
  },
  {
    type: 'event',
    name: 'DerivativeMint',
    inputs: [
      { name: 'account', type: 'address', indexed: true, internalType: 'address' },
      { name: 'count', type: 'uint256', indexed: false, internalType: 'uint256' },
      { name: 'tokenIds', type: 'uint256[]', indexed: false, internalType: 'uint256[]' },
    ],
    anonymous: false,
  },
  {
    type: 'error',
    name: 'MintZeroCount',
    inputs: [],
  },
  {
    type: 'error',
    name: 'MintLimitExceeded',
    inputs: [],
  },
  {
    type: 'error',
    name: 'RecipientZero',
    inputs: [],
  },
] as const;
