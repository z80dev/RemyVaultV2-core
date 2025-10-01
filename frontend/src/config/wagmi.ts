import { http, createConfig } from 'wagmi';
import { base } from 'wagmi/chains';
import { getDefaultConfig } from '@rainbow-me/rainbowkit';

export const config = getDefaultConfig({
  appName: 'wNFT Protocol',
  projectId: 'YOUR_PROJECT_ID', // Get from WalletConnect Cloud
  chains: [base],
  transports: {
    [base.id]: http(),
  },
});
