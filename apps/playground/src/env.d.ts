/// <reference types="vite/client" />
import type { EIP1193Provider } from 'viem';

declare global {
  interface Window {
    // Injected by MetaMask and other EIP-1193 wallets.
    ethereum?: EIP1193Provider;
  }
}

export {};
