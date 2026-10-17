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
  createPublicClient, createWalletClient, http, custom, decodeAbiParameters, encodeAbiParameters,
  encodeFunctionData, decodeFunctionResult, parseAbi,
  BaseError, ContractFunctionRevertedError, type Address, type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { marketStatus as nyseStatus, CALENDAR_2026 as NYSE_2026 } from "./campana.mjs";
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
// Every RPC request, reads and sends alike, waits for a slot: at most RPC_PER_MIN a minute, spread
// evenly (HyperEVM's public RPC allows 100 a minute per IP).
const RPC_PER_MIN = Number(process.env.RPC_PER_MIN ?? 90);
const base = http(rpc)({});
let nextSlot = 0;
const limited = custom({
  async request(args) {
    const now = Date.now();
    const at = Math.max(now, nextSlot);
    nextSlot = at + 60_000 / RPC_PER_MIN;
    if (at > now) await new Promise((r) => setTimeout(r, at - now));
    return base.request(args);
  },
});
const pub = createPublicClient({ transport: limited });
const wallet = createWalletClient({ account, transport: limited });
const once = process.argv.includes("--once");
const marketHours = process.env.MARKET_HOURS; // "nyse", "krx" or unset
// campana.mjs does not check its own range; krx.mjs throws outside it. Both end up the same here.
const nyseChecked = (ts: number) => {
  if (ts < NYSE_2026.validFrom || ts >= NYSE_2026.validUntil) throw new Error(`NYSE calendar ${NYSE_2026.version} does not cover ${ts}`);
  return nyseStatus(ts);
};
const hoursFn = ({ nyse: nyseChecked, krx: krxStatus } as Record<string, (ts: number) => { status: string }>)[marketHours ?? ""];
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

/// Simulate first so a revert (breach, too early, not liquidatable) costs no gas. The gas limit
/// is the estimate plus 30%: on HyperEVM testnet an exact estimate ran out of gas (a settle used
/// 285,766 of 285,766). Passing the limit makes viem skip its own estimate, so this adds no request.
/// The limit stays under the 2M small-block cap; work estimated above it needs big blocks and is
/// logged, not sent. Only a receipt with status success counts as done.
const SMALL_BLOCK_GAS = 2_000_000n;
async function send(functionName: string, args: unknown[] = []): Promise<boolean> {
  try {
    const { request } = await pub.simulateContract({ account, address: pool, abi, functionName, args });
    const gas = await pub.estimateContractGas({ account, address: pool, abi, functionName, args });
    if (gas >= SMALL_BLOCK_GAS) {
      console.log(`${new Date().toISOString()} ${functionName}(${args.join(", ")}) NEEDS BIG BLOCKS: estimate ${gas}`);
      return false;
    }
    const padded = (gas * 13n) / 10n;
    const limit = padded < SMALL_BLOCK_GAS ? padded : SMALL_BLOCK_GAS - 1n;
    const hash = await wallet.writeContract({ ...request, gas: limit });
    const receipt = await pub.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") {
      console.log(`${new Date().toISOString()} ${functionName}(${args.join(", ")}) REVERTED on chain ${hash} (gas ${receipt.gasUsed})`);
      return false;
    }
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

// poke only when the oracle has moved this share of maxJumpBps from the latch's anchor: enough to
// keep the anchor close (settle and liquidate move it too), without a transaction per update
const POKE_AT = Number(process.env.POKE_AT_FRACTION ?? 0.25);
let asset: { perp: number; scale: bigint } | undefined; // fixed at deployment

async function tick() {
  if (!asset) {
    const [dex, index, szDecimals] = await read("asset");
    asset = { perp: dex * 10000 + index, scale: 10n ** (12n + BigInt(szDecimals)) };
  }
  const [rawPx, rawNow, rawIds, rawPaused, rawParams, rawLatch] = await batch([
    { target: ORACLE_PX, data: encodeAbiParameters([{ type: "uint32" }], [asset.perp]) },
    { target: MULTICALL3, data: encodeFunctionData({ abi: mcAbi, functionName: "getCurrentBlockTimestamp" }) },
    poolCall("activeIds"),
    poolCall("opensPaused"),
    poolCall("getParams"), // every tick: a delay cut by applyParams must take effect at once
    poolCall("latch"),
  ]);
  const [px] = decodeAbiParameters([{ type: "uint64" }], rawPx);
  const oracle = (px as bigint) * asset.scale;
  const now = decodeFunctionResult({ abi: mcAbi, functionName: "getCurrentBlockTimestamp", data: rawNow });
  // only pending and open positions: closed and cancelled ids leave this list on chain
  const ids = poolResult("activeIds", rawIds) as bigint[];

  const p = poolResult("getParams", rawParams);
  const [anchor] = poolResult("latch", rawLatch) as [bigint, bigint];
  const moved = anchor === 0n ? Infinity : Number(((oracle > anchor ? oracle - anchor : anchor - oracle) * 1_000_000n) / anchor) / 100;
  if (moved >= Number(p.maxJumpBps) * POKE_AT) await send("poke");

  if (hoursFn) {
    // Outside the calendar the keeper cannot tell open from closed, so it keeps opens paused
    // and carries on settling and liquidating; the calendar needs renewing.
    let shouldPause: boolean;
    try {
      shouldPause = hoursFn(Number(now)).status === "CLOSED";
    } catch (e) {
      console.log(`${new Date().toISOString()} CALENDAR EXPIRED, opens stay paused: ${(e as Error).message}`);
      shouldPause = true;
    }
    if (poolResult("opensPaused", rawPaused) !== shouldPause) await send("setOpensPaused", [shouldPause]);
  }

  const settleDelay = BigInt(p.settleDelay);
  const rows = ids.length ? await batch(ids.map((id) => poolCall("positions", [id]))) : [];
  for (const [i, id] of ids.entries()) {
    // maintenance is the one stored with the position when it was opened, as the contract uses
    const [owner, long, leverage, margin, entry, requestedAt, closing, , , maintenanceBps] = poolResult("positions", rows[i]);
    if (owner === "0x0000000000000000000000000000000000000000") continue;
    if ((entry === 0n || closing) && now >= requestedAt + settleDelay) {
      await send("settle", [id]);
      continue;
    }
    if (entry !== 0n) {
      const notional = margin * BigInt(leverage);
      const move = ((oracle - entry) * notional) / entry;
      const equity = margin + (long ? move : -move);
      if (equity < (notional * BigInt(maintenanceBps)) / 10000n) await send("liquidate", [id]);
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
