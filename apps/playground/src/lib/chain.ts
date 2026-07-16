import {
  createPublicClient,
  createWalletClient,
  custom,
  http,
  fallback,
  encodeAbiParameters,
  parseAbiParameters,
} from 'viem';
import { baseSepolia } from 'viem/chains';
import type { Address, Hex } from 'viem';
import { compileIntent } from './asp';

// ── Base Sepolia (chainId 84532) on-chain constants ──────────────────────────
export const CHAIN_ID = 84532;
export const CHAIN_ID_HEX: Hex = '0x14a34';
export const PROCESSOR: Address = '0x0fdFB12E72b08289F1374E69aCa39D69A279fdcE';
export const TRANSFER_ADAPTER: Address = '0x6cA85B548d3512E355B63Fb390dBD197CF72d5eA';
export const USDC: Address = '0x036CbD53842c5426634e7929541eC2318f3dCF7e';
export const AGENTIC_WALLET: Address = '0xe403ba51f5132cf8d95fc4e37356bf0f894a4ab3';
export const SOOTH_MARKET: Address = '0x80334C47F3DcE19FcFE7dB1AEce7423D32C4ccB1';
export const RPC_PRIMARY = 'https://sepolia.base.org';
export const RPC_FALLBACK = 'https://base-sepolia-rpc.publicnode.com';
export const EXPLORER_TX = 'https://sepolia.basescan.org/tx/';

const processorAbi = [
  {
    name: 'nonces',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ type: 'address' }],
    outputs: [{ type: 'uint256' }],
  },
  {
    name: 'execute',
    type: 'function',
    stateMutability: 'payable',
    inputs: [{ type: 'bytes' }],
    outputs: [],
  },
] as const;

const erc20Abi = [
  {
    name: 'allowance',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ type: 'address' }, { type: 'address' }],
    outputs: [{ type: 'uint256' }],
  },
  {
    name: 'approve',
    type: 'function',
    stateMutability: 'nonpayable',
    inputs: [{ type: 'address' }, { type: 'uint256' }],
    outputs: [{ type: 'bool' }],
  },
] as const;

function readClient() {
  return createPublicClient({
    chain: baseSepolia,
    transport: fallback([http(RPC_PRIMARY), http(RPC_FALLBACK)]),
  });
}

function getProvider() {
  const eth = window.ethereum;
  if (!eth) {
    throw new Error('No injected wallet found. Install MetaMask to continue.');
  }
  return eth;
}

// ── Wallet connection + network ──────────────────────────────────────────────
export async function connectWallet(): Promise<Address> {
  const eth = getProvider();
  const accounts = await eth.request({ method: 'eth_requestAccounts' });
  const account = accounts[0];
  if (!account) {
    throw new Error('Wallet returned no account.');
  }
  await ensureBaseSepolia();
  return account;
}

export async function currentChainId(): Promise<number> {
  const eth = getProvider();
  const hex = await eth.request({ method: 'eth_chainId' });
  return parseInt(hex, 16);
}

export async function ensureBaseSepolia(): Promise<void> {
  const eth = getProvider();
  if ((await currentChainId()) === CHAIN_ID) return;
  try {
    await eth.request({
      method: 'wallet_switchEthereumChain',
      params: [{ chainId: CHAIN_ID_HEX }],
    });
  } catch (err) {
    if (isUnknownChainError(err)) {
      await eth.request({
        method: 'wallet_addEthereumChain',
        params: [
          {
            chainId: CHAIN_ID_HEX,
            chainName: 'Base Sepolia',
            rpcUrls: [RPC_PRIMARY],
            nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 },
            blockExplorerUrls: ['https://sepolia.basescan.org'],
          },
        ],
      });
    } else {
      throw err;
    }
  }
}

// MetaMask returns 4902 when the target chain is not yet added to the wallet.
function isUnknownChainError(err: unknown): boolean {
  return (
    typeof err === 'object' &&
    err !== null &&
    'code' in err &&
    (err as { code?: number }).code === 4902
  );
}

// ── Execute flow (scenario A: wait-then-transfer) ────────────────────────────
export type ExecPhase =
  | 'preparing'
  | 'approving'
  | 'signing'
  | 'executing'
  | 'success'
  | 'error';

export interface ExecState {
  phase: ExecPhase;
  message: string;
  txHash?: Hex;
  approveTxHash?: Hex;
}

// Recompiles the intent against the signer + on-chain nonce, handles the USDC
// approval if needed, signs the digest, and submits execute() to the processor.
export async function executeTransferScenario(
  account: Address,
  recipient: Address,
  amount: bigint,
  onState: (s: ExecState) => void,
): Promise<void> {
  const eth = getProvider();
  const publicClient = readClient();
  const walletClient = createWalletClient({ chain: baseSepolia, transport: custom(eth) });

  onState({ phase: 'preparing', message: 'Reading on-chain nonce and compiling a fresh intent…' });

  const nonce = await publicClient.readContract({
    address: PROCESSOR,
    abi: processorAbi,
    functionName: 'nonces',
    args: [account],
  });

  // Re-compile so toSign is bound to THIS signer and nonce.
  const intent = await compileIntent({
    chain: CHAIN_ID,
    initiator: account,
    nonce: Number(nonce),
    conditions: [{ type: 'waitTime', timestamp: 1 }],
    actions: [{ type: 'transfer', token: USDC, to: recipient, amount: amount.toString() }],
  });

  const allowance = await publicClient.readContract({
    address: USDC,
    abi: erc20Abi,
    functionName: 'allowance',
    args: [account, TRANSFER_ADAPTER],
  });

  if (allowance < amount) {
    onState({ phase: 'approving', message: 'Approve USDC for the TransferAdapter in your wallet…' });
    const approveHash = await walletClient.writeContract({
      address: USDC,
      abi: erc20Abi,
      functionName: 'approve',
      args: [TRANSFER_ADAPTER, amount],
      account,
      chain: baseSepolia,
    });
    onState({
      phase: 'approving',
      message: 'Waiting for the approval to confirm…',
      approveTxHash: approveHash,
    });
    await publicClient.waitForTransactionReceipt({ hash: approveHash });
  }

  onState({ phase: 'signing', message: 'Sign the intent digest (personal_sign) in your wallet…' });
  const signature = await walletClient.signMessage({
    account,
    message: { raw: intent.toSign as Hex },
  });

  // This is exactly the argument W3CashProcessor.execute(bytes) expects.
  const signedPayload = encodeAbiParameters(parseAbiParameters('(bytes, address, uint256, bytes)'), [
    [intent.instruction as Hex, account, BigInt(intent.nonce), signature],
  ]);

  onState({ phase: 'executing', message: 'Submitting execute() to the W3Cash processor…' });
  const hash = await walletClient.writeContract({
    address: PROCESSOR,
    abi: processorAbi,
    functionName: 'execute',
    args: [signedPayload],
    account,
    chain: baseSepolia,
  });
  onState({ phase: 'executing', message: 'Waiting for the transaction to confirm…', txHash: hash });

  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== 'success') {
    onState({ phase: 'error', message: 'The execute() transaction reverted on-chain.', txHash: hash });
    return;
  }
  onState({
    phase: 'success',
    message: 'Intent executed on-chain — the transfer fired the moment the gate opened.',
    txHash: hash,
  });
}
