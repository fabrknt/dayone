import {
  createPublicClient, createWalletClient, custom, http, defineChain, decodeAbiParameters, encodeAbiParameters,
  BaseError, ContractFunctionRevertedError, type Address, type Hex, type PublicClient,
  type WalletClient, type Chain,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import poolArtifact from "../../out/LaunchPool.sol/LaunchPool.json";

export const poolAbi = poolArtifact.abi;
export const usdcAbi = [
  { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "allowance", stateMutability: "view", inputs: [{ type: "address" }, { type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "approve", stateMutability: "nonpayable", inputs: [{ type: "address" }, { type: "uint256" }], outputs: [{ type: "bool" }] },
  { type: "function", name: "mint", stateMutability: "nonpayable", inputs: [{ type: "address" }, { type: "uint256" }], outputs: [] },
] as const;

export type Config = {
  rpc: string;
  chainId: number;
  pool: Address;
  usdc: Address;
  market: string;
  devKey?: Hex; // local playground only
};

const TESTNET: Omit<Config, "pool" | "usdc"> = {
  rpc: "https://rpc.hyperliquid-testnet.xyz/evm",
  chainId: 998,
  market: "xyz:TSLA (HyperEVM testnet)",
};

/// ?net=testnet&pool=0x..&usdc=0x.. for testnet; otherwise the local playground's public/local.json.
export async function loadConfig(): Promise<Config> {
  const q = new URLSearchParams(location.search);
  if (q.get("net") === "testnet") {
    return { ...TESTNET, pool: q.get("pool") as Address, usdc: q.get("usdc") as Address };
  }
  const r = await fetch("/local.json", { cache: "no-store" });
  if (!r.ok) throw new Error("No local playground found. Run ./keeper/dev.sh, or open ?net=testnet&pool=…&usdc=…");
  return r.json();
}

export function makeChain(c: Config): Chain {
  return defineChain({
    id: c.chainId,
    name: c.chainId === 998 ? "HyperEVM testnet" : "Local",
    nativeCurrency: { name: "HYPE", symbol: "HYPE", decimals: 18 },
    rpcUrls: { default: { http: [c.rpc] } },
  });
}

export function makeClients(c: Config): { pub: PublicClient; wallet: () => Promise<WalletClient> } {
  const chain = makeChain(c);
  const pub = createPublicClient({ chain, transport: http(c.rpc) }) as PublicClient;
  const wallet = async () => {
    if (c.devKey) return createWalletClient({ chain, account: privateKeyToAccount(c.devKey), transport: http(c.rpc) });
    const eth = (window as any).ethereum;
    if (!eth) throw new Error("No browser wallet found");
    const [addr] = await eth.request({ method: "eth_requestAccounts" });
    try {
      await eth.request({ method: "wallet_switchEthereumChain", params: [{ chainId: "0x" + c.chainId.toString(16) }] });
    } catch {
      await eth.request({
        method: "wallet_addEthereumChain",
        params: [{ chainId: "0x" + c.chainId.toString(16), chainName: chain.name, rpcUrls: [c.rpc], nativeCurrency: chain.nativeCurrency }],
      });
    }
    return createWalletClient({ chain, account: addr as Address, transport: custom(eth) });
  };
  return { pub, wallet };
}

// HLPriceGuard.Breach, in order
export const BREACH = ["None", "EmptyBook", "Spread", "MarkOracle", "MidOracle", "RefStale", "RefOracle", "Jump"];
export const BREACH_TEXT: Record<string, string> = {
  EmptyBook: "the HL book is empty or crossed",
  Spread: "the HL spread is too wide",
  MarkOracle: "HL's mark is too far from the oracle",
  MidOracle: "HL's book mid is too far from the oracle",
  RefStale: "the independent reference price is stale",
  RefOracle: "the oracle disagrees with the independent reference",
  Jump: "the oracle jumped too far since the last accepted price",
};

export function why(e: unknown): string {
  if (e instanceof BaseError) {
    const r = e.walk((x) => x instanceof ContractFunctionRevertedError);
    if (r instanceof ContractFunctionRevertedError && r.data) {
      const { errorName, args = [] } = r.data;
      if (errorName === "Breach") {
        const name = BREACH[Number(args[0])];
        return `Paused: ${BREACH_TEXT[name] ?? name} (${args[1]} bp, limit ${args[2]})`;
      }
      if (errorName === "BudgetExceeded") return "This minute's settlement cap is used up; it settles next minute.";
      if (errorName === "NetExposureExceeded") return "The pool's net exposure limit is reached on this side.";
      if (errorName === "OpensClosed") return "New positions are paused (out of trading hours, or graduated).";
      if (errorName === "RedeemBlocked") return "Not redeemable right now: winners are queued, or the pool is holding its reserve.";
      return `${errorName}(${args.join(", ")})`;
    }
    return e.shortMessage;
  }
  return e instanceof Error ? e.message : String(e);
}

export type Market = {
  oracle: bigint; mark: bigint; bid: bigint; ask: bigint; // 1e18
  guard: string | null; // null = prices accepted right now
};

/// Read HL prices for the pool's asset, and whether the guard would accept them now
/// (a simulated poke(): its revert is the guard's verdict).
export async function readMarket(pub: PublicClient, pool: Address, from: Address): Promise<Market> {
  const [dex, index, sz] = (await pub.readContract({ address: pool, abi: poolAbi, functionName: "asset" })) as [number, number, number];
  const perp = dex * 10000 + index;
  const bboIdx = dex === 0 ? index : 100000 + dex * 10000 + index;
  const scale = 10n ** (12n + BigInt(sz));
  const call = async (to: Address, idx: number, n: number) => {
    const r = await pub.call({ to, data: encodeAbiParameters([{ type: "uint32" }], [idx]) });
    return decodeAbiParameters(Array(n).fill({ type: "uint64" }), r.data as Hex) as bigint[];
  };
  const [[oracle], [mark], [bid, ask]] = await Promise.all([
    call("0x0000000000000000000000000000000000000807", perp, 1),
    call("0x0000000000000000000000000000000000000806", perp, 1),
    call("0x000000000000000000000000000000000000080e", bboIdx, 2),
  ]);
  let guard: string | null = null;
  try {
    await pub.simulateContract({ account: from, address: pool, abi: poolAbi, functionName: "poke" });
  } catch (e) {
    guard = why(e);
  }
  return { oracle: oracle * scale, mark: mark * scale, bid: bid * scale, ask: ask * scale, guard };
}
