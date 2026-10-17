// Day One keeper: keeps the jump latch's anchor current, settles due requests, liquidates.
//
//   RPC_URL=... POOL=0x... PRIVATE_KEY=0x... node keeper/keeper.ts [--once]
//
// Every tick (1 s):
//   1. read the oracle (0x807); if it changed, call poke() so the latch compares against a
//      recent price (its anchor only moves in a transaction that succeeds);
//   2. settle every pending open or close whose settleDelay has passed (from activeIds(), so
//      the work is bounded by live positions, not by every id ever issued);
//   3. liquidate every open position below maintenance at the current oracle;
//   4. with MARKET_HOURS=nyse or krx (operator key only), pause new positions while that
//      exchange is closed: out of hours there is no independent stock price to check the
//      deployer's oracle against. nyse for US stocks, krx for xyz:SKHX and xyz:SMSN.
// A guard breach makes poke/settle/liquidate revert; the keeper logs it and tries again next
// tick. It never tries to get around a breach: waiting is the intended behaviour.
import { readFileSync } from "node:fs";
import {
  createPublicClient, createWalletClient, http, decodeAbiParameters, encodeAbiParameters,
  encodeFunctionData, decodeFunctionResult, parseAbi,
  BaseError, ContractFunctionRevertedError, type Address, type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { marketStatus as nyseStatus } from "./campana.mjs";
import { marketStatus as krxStatus } from "./krx.mjs";

const ORACLE_PX: Address = "0x0000000000000000000000000000000000000807";
// Public RPCs rate-limit per request, so each tick reads everything through Multicall3 (deployed
// at the usual address on HyperEVM mainnet and testnet): one call for the oracle, block time,
// active ids and pause flag, and one more for the positions when there are any.
const MULTICALL3: Address = "0xcA11bde05977b3631167028862bE2a173976CA11";
const mcAbi = parseAbi([
  "struct Call3 { address target; bool allowFailure; bytes callData; }",
  "struct Result { bool success; bytes returnData; }",
  "function aggregate3(Call3[] calls) view returns (Result[])",
  "function getCurrentBlockTimestamp() view returns (uint256)",
]);
const TICK_MS = Number(process.env.TICK_MS ?? 1000);
const abi = JSON.parse(readFileSync(new URL("../out/LaunchPool.sol/LaunchPool.json", import.meta.url), "utf8")).abi;

const rpc = process.env.RPC_URL ?? "http://127.0.0.1:8545";
const pool = process.env.POOL as Address;
const account = privateKeyToAccount(process.env.PRIVATE_KEY as Hex);
const pub = createPublicClient({ transport: http(rpc) });
const wallet = createWalletClient({ account, transport: http(rpc) });
const once = process.argv.includes("--once");
const marketHours = process.env.MARKET_HOURS; // "nyse", "krx" or unset
const hoursFn = ({ nyse: nyseStatus, krx: krxStatus } as Record<string, (ts: number) => { status: string }>)[marketHours ?? ""];
if (marketHours && !hoursFn) throw new Error(`MARKET_HOURS must be nyse or krx, got ${marketHours}`);
// HLPriceGuard.Breach, in order
const BREACH = ["None", "EmptyBook", "Spread", "MarkOracle", "MidOracle", "RefStale", "RefOracle", "Jump"];

const read = (functionName: string, args: unknown[] = []) =>
  pub.readContract({ address: pool, abi, functionName, args }) as Promise<any>;

function why(e: unknown): string {
  if (e instanceof BaseError) {
    const r = e.walk((x) => x instanceof ContractFunctionRevertedError);
    if (r instanceof ContractFunctionRevertedError) {
      const d = r.data;
      if (d?.errorName === "Breach" && d.args) {
        const [reason, observed, limit] = d.args as [number, bigint, bigint];
        return `Breach ${BREACH[Number(reason)]}: ${observed} over ${limit}`;
      }
      return d ? `${d.errorName}(${(d.args ?? []).join(", ")})` : r.shortMessage;
    }
    return e.shortMessage;
  }
  return String(e);
}

/// Simulate first so a revert (breach, too early, not liquidatable) costs no gas.
async function send(functionName: string, args: unknown[] = []): Promise<boolean> {
  try {
    const { request } = await pub.simulateContract({ account, address: pool, abi, functionName, args });
    const hash = await wallet.writeContract(request);
    await pub.waitForTransactionReceipt({ hash });
    console.log(`${new Date().toISOString()} ${functionName}(${args.join(", ")}) ok ${hash}`);
    return true;
  } catch (e) {
    console.log(`${new Date().toISOString()} ${functionName}(${args.join(", ")}) skipped: ${why(e)}`);
    return false;
  }
}

/// One eth_call for several reads; a failed sub-call throws, so the tick retries as a whole.
async function batch(calls: { target: Address; data: Hex }[]): Promise<Hex[]> {
  const results = await pub.readContract({
    address: MULTICALL3, abi: mcAbi, functionName: "aggregate3",
    args: [calls.map((c) => ({ target: c.target, allowFailure: false, callData: c.data }))],
  });
  return results.map((x) => x.returnData);
}
const poolCall = (functionName: string, args: unknown[] = []) =>
  ({ target: pool, data: encodeFunctionData({ abi, functionName, args }) });
const poolResult = (functionName: string, data: Hex) =>
  decodeFunctionResult({ abi, functionName, data }) as any;

let lastOracle = -1n;
let asset: { perp: number; scale: bigint } | undefined; // fixed at deployment
let params: { maintenanceBps: bigint; settleDelay: bigint; at: number } | undefined;

async function tick() {
  if (!asset) {
    const [dex, index, szDecimals] = await read("asset");
    asset = { perp: dex * 10000 + index, scale: 10n ** (12n + BigInt(szDecimals)) };
  }
  if (!params || Date.now() - params.at > 60_000) { // params change only after paramsDelay
    const p = await read("getParams");
    params = { maintenanceBps: BigInt(p.maintenanceBps), settleDelay: BigInt(p.settleDelay), at: Date.now() };
  }
  const [rawPx, rawNow, rawIds, rawPaused] = await batch([
    { target: ORACLE_PX, data: encodeAbiParameters([{ type: "uint32" }], [asset.perp]) },
    { target: MULTICALL3, data: encodeFunctionData({ abi: mcAbi, functionName: "getCurrentBlockTimestamp" }) },
    poolCall("activeIds"),
    poolCall("opensPaused"),
  ]);
  const [px] = decodeAbiParameters([{ type: "uint64" }], rawPx);
  const oracle = (px as bigint) * asset.scale;
  const now = decodeFunctionResult({ abi: mcAbi, functionName: "getCurrentBlockTimestamp", data: rawNow });
  // only pending and open positions: closed and cancelled ids leave this list on chain
  const ids = poolResult("activeIds", rawIds) as bigint[];

  if (oracle !== lastOracle) {
    if (await send("poke")) lastOracle = oracle;
  }

  if (hoursFn) {
    const shouldPause = hoursFn(Number(now)).status === "CLOSED";
    if (poolResult("opensPaused", rawPaused) !== shouldPause) await send("setOpensPaused", [shouldPause]);
  }

  const { maintenanceBps, settleDelay } = params;
  const rows = ids.length ? await batch(ids.map((id) => poolCall("positions", [id]))) : [];
  for (const [i, id] of ids.entries()) {
    const [owner, long, leverage, margin, entry, requestedAt, closing] = poolResult("positions", rows[i]);
    if (owner === "0x0000000000000000000000000000000000000000") continue;
    if ((entry === 0n || closing) && now >= requestedAt + settleDelay) {
      await send("settle", [id]);
      continue;
    }
    if (entry !== 0n) {
      const notional = margin * BigInt(leverage);
      const move = ((oracle - entry) * notional) / entry;
      const equity = margin + (long ? move : -move);
      if (equity < (notional * maintenanceBps) / 10000n) await send("liquidate", [id]);
    }
  }
}

do {
  try {
    await tick();
  } catch (e) {
    console.log(`${new Date().toISOString()} tick failed: ${why(e)}`);
  }
  if (!once) await new Promise((r) => setTimeout(r, TICK_MS));
} while (!once);
