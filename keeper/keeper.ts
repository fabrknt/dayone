// Day One keeper: keeps the jump latch's anchor current, settles due requests, liquidates.
//
//   RPC_URL=... POOL=0x... PRIVATE_KEY=0x... node keeper/keeper.ts [--once]
//   (POOL_ABI=v1 for a pool deployed before the pauser role and claim(), e.g. testnet 0x183A…)
//   (REF_COIN=xyz:TSLA, testnet only, for a pool whose reference is a ReporterRef this key writes:
//   pushes HL mainnet's oracle for that market every REF_PUSH_MS, before the tick's reads)
//
// Every tick (TICK_MS, default 1 s; 3 s on the public RPC), after one batched read:
//   1. with MARKET_HOURS=nyse or krx (the pool's pauser key, or the operator's), pause new positions while that
//      exchange is closed: out of hours there is no independent stock price to check the
//      deployer's oracle against. nyse for US stocks, krx for xyz:SKHX and xyz:SMSN;
//      with PRIMARY_HALTS=<symbol> (nyse only) also while Nasdaq's halts feed shows that stock
//      halted (LULD pause, news, market-wide circuit breaker), or the feed is unreadable or stale,
//      for the same reason. The halt state is prebell's (prebell/guard, us-hip3-perp scenario);
//   2. liquidate every open position below its stored maintenance at the current oracle;
//   3. settle every pending open or close whose settleDelay has passed (from activeIds(), so
//      the work is bounded by live positions, not by every id ever issued);
//   4. poke() when the oracle is POKE_AT_FRACTION of maxJumpBps away from the latch's anchor,
//      so the anchor stays close (it only moves in a transaction that succeeds; settle and
//      liquidate move it too). Liquidations go first and pokes last because all RPC requests
//      share one budget (RPC_PER_MIN). Between them, up to CLAIMS_PER_TICK claim()s send queued
//      winners what the queue has paid them.
// A guard breach makes poke/settle/liquidate revert; the keeper logs it and tries again next
// tick. It never tries to get around a breach: waiting is the intended behaviour.
// A halted or delisted market reads as an empty book (0, 0): the keeper calls noteFrozen() every
// minute (the pool restarts the clock after a gap over FROZEN_GAP), and holds liquidations,
// closes, opens and pokes while the guard would refuse the book, until FROZEN_DELAY has passed
// at one price. Once the operator's end is applied it settles every open position at the end price.
import { readFileSync } from "node:fs";
import { randomInt } from "node:crypto";
import {
  createPublicClient, createWalletClient, http, custom, decodeAbiParameters, encodeAbiParameters,
  encodeFunctionData, decodeFunctionResult, parseAbi, parseUnits, keccak256,
  BaseError, ContractFunctionRevertedError, type Address, type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { marketStatus as nyseStatus, CALENDAR_2026, CALENDAR_2027 } from "./campana.mjs";
import { marketStatus as krxStatus } from "./krx.mjs";
import type { Halt } from "prebell/guard";

const ORACLE_PX: Address = "0x0000000000000000000000000000000000000807";
const BBO: Address = "0x000000000000000000000000000000000000080e";
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
let abi = JSON.parse(readFileSync(new URL("../out/LaunchPool.sol/LaunchPool.json", import.meta.url), "utf8")).abi;

const rpc = process.env.RPC_URL ?? "http://127.0.0.1:8545";
const pool = process.env.POOL as Address;
const account = privateKeyToAccount(process.env.PRIVATE_KEY as Hex);
// Every RPC request, reads and sends alike, waits for a slot: at most RPC_PER_MIN a minute, spread
// evenly (HyperEVM's public RPC allows 100 a minute per IP).
const RPC_PER_MIN = Number(process.env.RPC_PER_MIN ?? 90);
// no retries inside the transport: they would bypass the budget; a failed tick retries as a whole
const base = http(rpc, { retryCount: 0 })({});
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
const NYSE_CALENDARS = [CALENDAR_2026, CALENDAR_2027];
const nyseChecked = (ts: number) => {
  const cal = NYSE_CALENDARS.find((c) => ts >= c.validFrom && ts < c.validUntil);
  if (!cal) throw new Error(`no NYSE calendar covers ${ts}`);
  return nyseStatus(ts, cal);
};
const hoursFn = ({ nyse: nyseChecked, krx: krxStatus } as Record<string, (ts: number) => { status: string }>)[marketHours ?? ""];
if (marketHours && !hoursFn) throw new Error(`MARKET_HOURS must be nyse or krx, got ${marketHours}`);
// the primary listing's halts (prebell), read at most every HALTS_EVERY_MS; HALTS_FILE replaces the
// live feed with a saved one (keeper/e2e.sh)
const haltSymbol = process.env.PRIMARY_HALTS;
if (haltSymbol && marketHours !== "nyse") throw new Error("PRIMARY_HALTS needs MARKET_HOURS=nyse (the feed is Nasdaq's)");
// a v1 pool has one pause flag, the operator's too: unpausing it on a clear feed could lift the operator's own pause
if (haltSymbol && process.env.POOL_ABI === "v1") throw new Error("PRIMARY_HALTS needs a pool with a pauser role (not POOL_ABI=v1)");
// prebell is an optional dependency: loaded only for PRIMARY_HALTS, so the keeper runs without it
const prebell = haltSymbol ? await loadPrebell() : undefined;
async function loadPrebell() {
  try {
    const [guard, scenario] = await Promise.all([import("prebell/guard"), import("prebell/scenario")]);
    return { ...guard, scenario: scenario.bundledScenario("us-hip3-perp") };
  } catch (e) {
    throw new Error(`PRIMARY_HALTS needs the prebell package (fabrknt/prebell, not public yet), which is not installed: ${(e as Error).message}`);
  }
}
const HALTS_EVERY_MS = 30_000;
let haltFeed: { halts: Halt[]; fetchedAt: number } | undefined;
let haltsReadMs = -Infinity;
let haltDetail = "";
async function readHalts(): Promise<void> {
  if (Date.now() - haltsReadMs < HALTS_EVERY_MS) return;
  haltsReadMs = Date.now();
  try {
    const xml = process.env.HALTS_FILE
      ? readFileSync(process.env.HALTS_FILE, "utf8")
      : await (await fetch(prebell!.NASDAQ_HALTS_URL, { signal: AbortSignal.timeout(10_000) })).text();
    const f = prebell!.parseNasdaqFeed(xml);
    haltFeed = { halts: f.halts, fetchedAt: f.publishedAt };
  } catch (e) {
    // keep the last feed: it goes stale on its own, and marketStateFor then reads it as halted
    console.log(`${new Date().toISOString()} halts feed unreadable: ${(e as Error).message}`);
  }
}
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
/// Simulate, estimate and send; the hash, or undefined when the work needs big blocks. Throws on a revert.
async function write(address: Address, abi: any, functionName: string, args: unknown[]): Promise<Hex | undefined> {
  const prepared = await prepare(address, abi, functionName, args);
  return prepared && wallet.writeContract({ ...prepared.request, gas: prepared.gas });
}
/// The simulation's request and the padded gas limit; undefined when the work needs big blocks.
async function prepare(address: Address, abi: any, functionName: string, args: unknown[]) {
  const { request } = await pub.simulateContract({ account, address, abi, functionName, args });
  const gas = await pub.estimateContractGas({ account, address, abi, functionName, args });
  if (gas >= SMALL_BLOCK_GAS) {
    console.log(`${new Date().toISOString()} ${functionName}(${args.join(", ")}) NEEDS BIG BLOCKS: estimate ${gas}`);
    return undefined;
  }
  const padded = (gas * 13n) / 10n;
  return { request, gas: padded < SMALL_BLOCK_GAS ? padded : SMALL_BLOCK_GAS - 1n };
}
async function send(functionName: string, args: unknown[] = []): Promise<boolean> {
  // one transaction in flight: HyperEVM's RPC answers nonces at the latest block only, so a second
  // send while a reference push is unmined would reuse its nonce
  if (refPending) return false;
  let hash: Hex | undefined;
  try {
    hash = await write(pool, abi, functionName, args);
    if (!hash) return false;
    const receipt = await pub.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") {
      console.log(`${new Date().toISOString()} ${functionName}(${args.join(", ")}) REVERTED on chain ${hash} (gas ${receipt.gasUsed})`);
      return false;
    }
    console.log(`${new Date().toISOString()} ${functionName}(${args.join(", ")}) ok ${hash}`);
    return true;
  } catch (e) {
    // a failed receipt read (e.g. the RPC's rate limit) after the send says nothing about the tx:
    // it may have gone through. Logged as unknown; the next tick reads the state either way.
    const what = hash ? `sent ${hash}, result unknown` : "skipped";
    console.log(`${new Date().toISOString()} ${functionName}(${args.join(", ")}) ${what}: ${why(e)}`);
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
if (!(POKE_AT > 0 && POKE_AT < 1)) throw new Error(`POKE_AT_FRACTION must be in (0, 1), got ${process.env.POKE_AT_FRACTION}`);
let asset: { perp: number; bbo: number; scale: bigint } | undefined; // fixed at deployment
// POOL_ABI=v1 for pools deployed before the pauser role and claim() (testnet 0x183A…): the
// trading-hours pause is setOpensPaused with the operator key, and settle pays queued winners
// itself. Set explicitly, never guessed from a failed call: an RPC that answers "0x" looks just
// like an old pool, and a wrong guess would stick for the life of the process.
// POOL_ABI=v2 for pools deployed after claim() but before the halted-market exits (no
// noteFrozen(), ended()): the keeper then only holds its sends while the book is empty.
const v1 = process.env.POOL_ABI === "v1";
const v2 = process.env.POOL_ABI === "v2";
if (process.env.POOL_ABI && !v1 && !v2) throw new Error(`POOL_ABI must be v1, v2 or unset, got ${process.env.POOL_ABI}`);
const exits = !v1 && !v2;
const pauseFns = v1 ? { read: "opensPaused", set: "setOpensPaused" } : { read: "hoursPaused", set: "setHoursPaused" };
const claims = !v1;
// a v1 pool's Params has no stressMoveBps at the end
if (v1) abi = abi.map((e: any) => e.name !== "getParams" ? e
  : { ...e, outputs: [{ ...e.outputs[0], components: e.outputs[0].components.filter((c: any) => c.name !== "stressMoveBps") }] });
function intEnv(name: string, dflt: number, max: number) {
  const v = Number(process.env[name] ?? dflt);
  if (!Number.isInteger(v) || v < 1 || v > max) throw new Error(`${name} must be an integer in [1, ${max}], got ${process.env[name]}`);
  return v;
}
const CLAIMS_PER_TICK = intEnv("CLAIMS_PER_TICK", 3, 20); // a long queue drains over several ticks, inside the RPC budget
const OPENS_PER_TICK = intEnv("OPENS_PER_TICK", 5, 50); // pending opens tried per tick, after every close
const CLAIM_SCAN = BigInt(intEnv("CLAIM_SCAN", 50, 200)); // debts read per tick (e2e sets 1 to test the rotation)
let claimFrom = 0n; // every debt below this is fully claimed
// Where the next scan starts; it rotates over the paid part of the queue. A fresh process starts
// at a random debt, not at 0 or a clock-derived one (a restart cadence could resonate with it), so
// a keeper that keeps restarting still reaches every debt behind a claim that always fails.
let scanAt: bigint | undefined;
// A pending open that would not settle (beyond the pool's backing, paused, queued winners) is
// retried after roughly 1, 2, 4 … 64 ticks, jittered so a pile of them does not come due
// together, and at most OPENS_PER_TICK are tried a tick in ticket order: an open gets a ticket
// when first seen and a fresh one each time it is tried, so it is first-come, first-served even
// while new opens keep arriving. A close or liquidation that goes through can make room, so it makes every
// pending open due again (keeping that order).
let tickNo = 0;
const openRetry = new Map<bigint, { at: number; wait: number }>();
const ticket = new Map<bigint, number>();
let nextTicket = 0;
function byTicket(ids: bigint[]): bigint[] {
  // new ones queue in request order (id), not in activeIds() order, which a removal reshuffles
  const unseen = ids.filter((id) => !ticket.has(id)).sort((a, b) => (a < b ? -1 : 1));
  for (const id of unseen) ticket.set(id, nextTicket++);
  return ids.sort((a, b) => ticket.get(a)! - ticket.get(b)!);
}
let refreshedAt = -Infinity;
let FROZEN_DELAY: bigint | undefined;
let FROZEN_GAP: bigint | undefined; // the keeper notes every minute, inside this
let sighting = false; // this tick's exits run on a frozen book
let lastSightingMs = 0;

/// While exits run on a frozen book, a long drain must not let the sighting go older than
/// FROZEN_GAP: the pool would restart the hour. Notes again each minute of wall time; false
/// (skip the exit) when that note fails.
async function keepSighting(): Promise<boolean> {
  if (!sighting || Date.now() - lastSightingMs < 60_000) return true;
  if (!(await send("noteFrozen"))) return false;
  lastSightingMs = Date.now();
  return true;
}

// REF_COIN=xyz:TSLA (testnet only): push HL mainnet's oracle for that market to the pool's
// ReporterRef (src/testnet/ReporterRef.sol) every REF_PUSH_MS, so a testnet oracle that stops or
// drifts from it trips the guard. This key must be the reference's reporter. The reference is
// re-read before each push, so one the operator swaps in (proposeParams) is the one pushed.
// Nothing here stops the rest of the tick: a wrong setup (no reference, another reporter) or a
// failed read or push is logged and retried, every REF_PUSH_MS or after 10 s, while liquidations,
// closes and claims go on; anything that needs a fresh reference is refused by the pool itself.
// A push waits at most REF_WAIT_MS for its receipt. One not mined by then stays pending, and until
// it is resolved the keeper sends nothing else (one transaction in flight; while the chain is not
// mining nothing else would land either) and no second push. It is resolved only by its receipt or
// by its nonce being used (mined, or replaced); never by time, and never by a node saying it does
// not know the transaction (a lagging node says that too): the same signed bytes are broadcast
// again instead, at most once a REF_WAIT_MS. A push the node keeps refusing holds the keeper until
// it is restarted, and says so in the log every time.
const refCoin = process.env.REF_COIN;
const REF_API = process.env.REF_API ?? "https://api.hyperliquid.xyz/info";
const REF_PUSH_MS = intEnv("REF_PUSH_MS", 60_000, 3_600_000);
const REF_WAIT_MS = intEnv("REF_WAIT_MS", 15_000, 120_000);
const refAbi = parseAbi(["function push(uint256 price)", "function reporter() view returns (address)"]);
let refAt: Address | undefined; // the reference last checked to have this key as its reporter
let refDueMs = -Infinity; // next push (or retry) not before this
let refPending: { hash: Hex; nonce: number; signed: Hex; sentMs: number } | undefined;
let refLogged = false; // the first good push is logged, later ones only when they fail

async function refPrice(): Promise<bigint> {
  const dex = refCoin!.includes(":") ? refCoin!.split(":")[0] : "";
  const res = await fetch(REF_API, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ type: "metaAndAssetCtxs", dex }), signal: AbortSignal.timeout(10_000),
  });
  if (!res.ok) throw new Error(`${REF_API} answered ${res.status}`);
  const [meta, ctxs] = await res.json();
  const i = meta.universe.findIndex((a: { name: string }) => a.name === refCoin);
  const px = i < 0 ? undefined : ctxs[i]?.oraclePx;
  if (typeof px !== "string" || !(Number(px) > 0)) throw new Error(`no oracle for ${refCoin} at ${REF_API}`);
  return parseUnits(px, 18);
}

function refMined(hash: Hex, status: string) {
  if (status !== "success") console.log(`${new Date().toISOString()} reference push REVERTED on chain ${hash}`);
  else if (!refLogged) console.log(`${new Date().toISOString()} reference push ok ${hash} (later pushes are logged only when they fail)`);
  refLogged ||= status === "success";
}

/// Whether the pending push is still unresolved. A read that fails leaves it pending; one the node
/// does not know is broadcast again, unchanged.
async function refStillPending(): Promise<boolean> {
  const p = refPending!;
  try {
    const r = await pub.getTransactionReceipt({ hash: p.hash });
    refMined(p.hash, r.status);
    return false;
  } catch {}
  try {
    if ((await pub.getTransactionCount({ address: account.address, blockTag: "latest" })) > p.nonce) {
      console.log(`${new Date().toISOString()} reference push ${p.hash}: nonce ${p.nonce} used, receipt not found`);
      return false;
    }
    await pub.getTransaction({ hash: p.hash });
    return true;
  } catch (e) {
    if (!(e instanceof BaseError && e.name === "TransactionNotFoundError")) return true;
  }
  if (Date.now() - p.sentMs < REF_WAIT_MS) return true;
  p.sentMs = Date.now();
  try {
    await wallet.sendRawTransaction({ serializedTransaction: p.signed });
    console.log(`${new Date().toISOString()} reference push ${p.hash} unknown to the node; broadcast again`);
  } catch (e) {
    console.log(`${new Date().toISOString()} reference push ${p.hash} unknown to the node, and broadcasting it again failed: ${why(e)}; other sends stay held`);
  }
  return true;
}

async function pushRef() {
  const t = Date.now();
  if (refPending) {
    if (await refStillPending()) return;
    console.log(`${new Date().toISOString()} reference push ${refPending.hash} resolved; sends resume`);
    refPending = undefined;
  }
  if (t < refDueMs) return;
  refDueMs = t + 10_000; // a retry, unless this push goes out
  try {
    const at = (await read("refSource")) as Address;
    if (BigInt(at) === 0n) throw new Error("the pool has no reference source");
    if (at !== refAt) {
      const reporter = await pub.readContract({ address: at, abi: refAbi, functionName: "reporter" });
      if (reporter.toLowerCase() !== account.address.toLowerCase()) throw new Error(`the reference ${at} has reporter ${reporter}, not this key`);
      if (refAt) console.log(`${new Date().toISOString()} reference changed: ${refAt} -> ${at}`);
      refAt = at;
    }
  } catch (e) {
    refDueMs = t + REF_PUSH_MS;
    console.log(`${new Date().toISOString()} REFERENCE NOT PUSHED (REF_COIN=${refCoin}): ${why(e)}`);
    return;
  }
  let price: bigint;
  try {
    price = await refPrice();
  } catch (e) {
    console.log(`${new Date().toISOString()} reference read failed: ${why(e)}`);
    return;
  }
  let hash: Hex;
  let signed: Hex;
  let nonce: number;
  try {
    const prepared = await prepare(refAt, refAbi, "push", [price]);
    if (!prepared) return;
    // signed here, with its nonce fixed, so the hash is known before it is broadcast: a broadcast
    // whose answer is lost still counts as in flight, and the same bytes can be broadcast again
    nonce = await pub.getTransactionCount({ address: account.address, blockTag: "latest" });
    const tx = await wallet.prepareTransactionRequest({
      account, chain: null, to: refAt, data: encodeFunctionData({ abi: refAbi, functionName: "push", args: [price] }), gas: prepared.gas, nonce,
    });
    signed = await wallet.signTransaction(tx as any);
    hash = keccak256(signed);
  } catch (e) {
    console.log(`${new Date().toISOString()} push(${price}) skipped: ${why(e)}`);
    return;
  }
  refDueMs = t + REF_PUSH_MS;
  try {
    await wallet.sendRawTransaction({ serializedTransaction: signed });
  } catch (e) {
    refPending = { hash, nonce, signed, sentMs: t };
    console.log(`${new Date().toISOString()} reference push ${hash} broadcast without a clear answer (${why(e)}); holding other sends until it is resolved`);
    return;
  }
  try {
    const r = await pub.waitForTransactionReceipt({ hash, timeout: REF_WAIT_MS });
    refMined(hash, r.status);
  } catch {
    refPending = { hash, nonce, signed, sentMs: Date.now() };
    console.log(`${new Date().toISOString()} reference push ${hash} not mined within ${REF_WAIT_MS} ms; holding other sends until it is resolved`);
  }
}

async function tick() {
  tickNo++;
  sighting = false;
  // before the reads, so a settle this tick sees the fresh reference; it never throws
  if (refCoin) await pushRef().catch((e) => console.log(`${new Date().toISOString()} reference: ${why(e)}`));
  // a push still unmined holds every other send (see pushRef); the tick has nothing else to do
  if (refPending) return;
  // started now, so it overlaps the chain reads; a feed slower than them still delays the tick,
  // liquidations included, by at most its 10 s timeout
  const halts = haltSymbol ? readHalts() : undefined;
  if (!asset) {
    const [dex, index, szDecimals] = await read("asset");
    asset = { perp: dex * 10000 + index, bbo: dex === 0 ? index : 100000 + dex * 10000 + index, scale: 10n ** (12n + BigInt(szDecimals)) };
  }
  const [rawPx, rawBbo, rawNow, rawIds, rawPaused, rawParams, rawLatch, rawUnclaimed, rawEnded, rawFrozenPx, rawFrozenAt, rawSeenAt] = await batch([
    { target: ORACLE_PX, data: encodeAbiParameters([{ type: "uint32" }], [asset.perp]) },
    { target: BBO, data: encodeAbiParameters([{ type: "uint32" }], [asset.bbo]) },
    { target: MULTICALL3, data: encodeFunctionData({ abi: mcAbi, functionName: "getCurrentBlockTimestamp" }) },
    poolCall("activeIds"),
    poolCall(pauseFns.read), // with a pauser role, the operator's own pause is separate and the keeper never clears it
    poolCall("getParams"), // every tick: a delay cut by applyParams must take effect at once
    poolCall("latch"),
    ...(claims ? [poolCall("unclaimed")] : []),
    ...(exits ? [poolCall("ended"), poolCall("frozenPx"), poolCall("frozenAt"), poolCall("frozenSeenAt")] : []),
  ]);
  const [px] = decodeAbiParameters([{ type: "uint64" }], rawPx);
  const oracle = (px as bigint) * asset.scale;
  const now = decodeFunctionResult({ abi: mcAbi, functionName: "getCurrentBlockTimestamp", data: rawNow });
  const [bid, ask] = decodeAbiParameters([{ type: "uint64" }, { type: "uint64" }], rawBbo);
  // as HLPriceGuard refuses it: every guarded read reverts
  const emptyBook = oracle === 0n || bid === 0n || ask <= bid;
  const halted = oracle !== 0n && bid === 0n && ask === 0n; // the shape noteFrozen() counts
  const ended = exits && (poolResult("ended", rawEnded) as boolean);
  let exitsHeld = emptyBook; // exits would revert
  if (exits && !ended) {
    const frozenPx = poolResult("frozenPx", rawFrozenPx) as bigint;
    const frozenAt = poolResult("frozenAt", rawFrozenAt) as bigint;
    const seenAt = poolResult("frozenSeenAt", rawSeenAt) as bigint;
    if (halted) {
      FROZEN_DELAY ??= await read("FROZEN_DELAY");
      FROZEN_GAP ??= await read("FROZEN_GAP");
      // the note this tick restarts the clock when the price moved or the last sighting is too old
      const restarts = frozenPx !== oracle || now > seenAt + FROZEN_GAP!;
      const noted = restarts || now >= seenAt + 60n ? await send("noteFrozen") : true;
      if (restarts || now >= seenAt + 60n) lastSightingMs = Date.now();
      exitsHeld = restarts || !noted || now < frozenAt + FROZEN_DELAY!;
      sighting = halted && !exitsHeld;
    } else if (frozenPx !== 0n) await send("noteFrozen"); // any other book, live or not: clear the clock
  }
  // only pending and open positions: closed and cancelled ids leave this list on chain
  const ids = poolResult("activeIds", rawIds) as bigint[];

  const p = poolResult("getParams", rawParams);
  const [anchor] = poolResult("latch", rawLatch) as [bigint, bigint];
  const moved = anchor === 0n ? Infinity : Number(((oracle > anchor ? oracle - anchor : anchor - oracle) * 1_000_000n) / anchor) / 100;

  // while opens should be paused the keeper settles none itself, even if setting the pause failed
  let opensHeld = false;
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
    if (haltSymbol) {
      // judged at chain time, the feed by its own publication time; a missing or stale feed is a halt
      await halts;
      const st = prebell!.marketStateFor(prebell!.scenario, haltSymbol, Number(now), haltFeed);
      if (st.detail !== haltDetail) console.log(`${new Date().toISOString()} ${haltSymbol} primary market: ${st.halted ? `halted (${st.detail})` : "trading"}`);
      haltDetail = st.detail;
      if (st.halted) shouldPause = true;
    }
    opensHeld = shouldPause;
    if (poolResult(pauseFns.read, rawPaused) !== shouldPause) await send(pauseFns.set, [shouldPause]);
  }

  const settleDelay = BigInt(p.settleDelay);
  const rows = ids.length ? await batch(ids.map((id) => poolCall("positions", [id]))) : [];
  const liquidations: bigint[] = [];
  const closes: bigint[] = [];
  const opens: bigint[] = [];
  for (const [i, id] of ids.entries()) {
    // maintenance is the one stored with the position when it was opened, as the contract uses
    const [owner, long, leverage, margin, entry, requestedAt, closing, , , maintenanceBps] = poolResult("positions", rows[i]);
    if (owner === "0x0000000000000000000000000000000000000000") continue;
    if (ended) {
      // every open position settles at the end price; pending opens can only be cancelled
      if (entry !== 0n && now >= requestedAt + settleDelay) closes.push(id);
      continue;
    }
    if (exitsHeld) continue;
    if ((entry === 0n || closing) && now >= requestedAt + settleDelay) {
      if (closing) closes.push(id);
      else if ((openRetry.get(id)?.at ?? 0) <= tickNo) opens.push(id);
      continue;
    }
    if (entry !== 0n) {
      const notional = margin * BigInt(leverage);
      // as the pool rounds: PnL toward minus infinity and the maintenance level up; a v1 pool
      // truncates both, so a boundary position is not simulated on every tick for nothing
      const x = (long ? oracle - entry : entry - oracle) * notional;
      const pnl = x / entry - (!v1 && x < 0n && x % entry !== 0n ? 1n : 0n);
      const maintenance = (notional * BigInt(maintenanceBps) + (v1 ? 0n : 9999n)) / 10000n;
      if (margin + pnl < maintenance) liquidations.push(id);
    }
  }
  byTicket(opens);
  // the order matters when the RPC budget is tight: what protects the pool first
  let roomMade = false;
  for (const id of liquidations) if ((await keepSighting()) && (await send("liquidate", [id]))) roomMade = true;
  for (const id of closes) if ((await keepSighting()) && (await send("settle", [id]))) roomMade = true;
  if (roomMade) {
    for (const r of openRetry.values()) r.at = 0;
    // opens skipped this tick for their backoff are due now too
    for (const [i, id] of ids.entries()) {
      const [owner, , , , entry, requestedAt] = poolResult("positions", rows[i]);
      if (owner !== "0x0000000000000000000000000000000000000000" && entry === 0n && now >= requestedAt + settleDelay && !opens.includes(id)) opens.push(id);
    }
    byTicket(opens);
  }
  for (const id of emptyBook || opensHeld ? [] : opens.slice(0, OPENS_PER_TICK)) {
    ticket.set(id, nextTicket++);
    if (await send("settle", [id])) {
      openRetry.delete(id);
      continue;
    }
    const wait = Math.min((openRetry.get(id)?.wait ?? 0.5) * 2, 64);
    openRetry.set(id, { at: tickNo + wait + randomInt(Math.ceil(wait / 2) + 1), wait });
    // a close may have left the entry bounds looser than the open positions need
    if (!v1 && tickNo - refreshedAt >= 100) {
      refreshedAt = tickNo;
      await send("refreshEntryBounds");
    }
  }
  for (const id of openRetry.keys()) if (!ids.includes(id)) openRetry.delete(id); // cancelled or settled elsewhere
  for (const id of ticket.keys()) if (!ids.includes(id)) ticket.delete(id);
  const settlements = [...closes, ...opens];
  let claimed = 0;
  if (rawUnclaimed && poolResult("unclaimed", rawUnclaimed) > 0n) claimed = await sendClaims();
  if (!emptyBook && moved >= Number(p.maxJumpBps) * POKE_AT && liquidations.length + settlements.length + claimed === 0) await send("poke");
}

/// Sends up to CLAIMS_PER_TICK winners their paid part. Each tick reads up to CLAIM_SCAN debts,
/// carrying on from where the last tick stopped; on reaching the unpaid part (or the end) it
/// wraps to claimFrom within the same tick. So a debt whose claim keeps failing is retried on
/// later passes but never holds up the ones after it.
async function sendClaims(): Promise<number> {
  const [rawCount, rawPaid] = await batch([poolCall("debtCount"), poolCall("debtPaid")]);
  const count = poolResult("debtCount", rawCount) as bigint;
  const paid = poolResult("debtPaid", rawPaid) as bigint;
  if (count <= claimFrom) return 0;
  // a fresh process starts at a random debt: restarts at any cadence still reach every one
  if (scanAt === undefined) scanAt = claimFrom + BigInt(randomInt(Number(count - claimFrom > 1_000_000n ? 1_000_000n : count - claimFrom)));
  if (scanAt < claimFrom || scanAt >= count) scanAt = claimFrom;
  let budget = CLAIM_SCAN;
  let sent = 0;
  let wrapped = false;
  let pos = scanAt;
  while (budget > 0n && sent < CLAIMS_PER_TICK) {
    const end = pos + budget < count ? pos + budget : count;
    const ids: bigint[] = [];
    for (let i = pos; i < end; i++) ids.push(i);
    const rows = ids.length ? await batch(ids.map((i) => poolCall("debts", [i]))) : [];
    let front = pos === claimFrom; // only a scan from the fully claimed prefix can extend it
    let next = end;
    let atUnpaid = false;
    let examined = 0n;
    for (const [k, i] of ids.entries()) {
      const [, , start, amount, done] = poolResult("debts", rows[k]) as [Address, bigint, bigint, bigint, bigint];
      examined++; // only what was looked at counts against the budget, so a wrap still has some
      if (start >= paid) {
        atUnpaid = true; // the queue is paid in order: nothing from here on is paid yet
        break;
      }
      if (sent === CLAIMS_PER_TICK) {
        next = i; // out of claims this tick: start here next time
        break;
      }
      const upTo = paid - start < amount ? paid - start : amount;
      let claimedAll = done === amount;
      if (upTo > done && (await send("claim", [i]))) {
        sent++;
        claimedAll = upTo === amount;
      }
      if (front && claimedAll) claimFrom = i + 1n;
      else front = false;
    }
    budget -= examined;
    if (sent === CLAIMS_PER_TICK && !atUnpaid && next < end) {
      pos = next;
      break;
    }
    if (atUnpaid || next >= count) {
      // wrap to the front, once a tick; stop if this pass already started there
      if (wrapped || pos === claimFrom) {
        pos = claimFrom;
        break;
      }
      wrapped = true;
      pos = claimFrom;
    } else pos = next;
  }
  scanAt = pos >= count ? claimFrom : pos;
  return sent;
}

do {
  try {
    await tick();
  } catch (e) {
    console.log(`${new Date().toISOString()} tick failed: ${why(e)}`);
  }
  if (!once) await new Promise((r) => setTimeout(r, TICK_MS));
} while (!once);
