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
//   4. with MARKET_HOURS=nyse (operator key only), pause new positions while NYSE is closed:
//      out of hours there is no independent stock price to check the deployer's oracle against.
// A guard breach makes poke/settle/liquidate revert; the keeper logs it and tries again next
// tick. It never tries to get around a breach: waiting is the intended behaviour.
import { readFileSync } from "node:fs";
import {
  createPublicClient, createWalletClient, http, decodeAbiParameters, encodeAbiParameters,
  BaseError, ContractFunctionRevertedError, type Address, type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { marketStatus } from "./campana.mjs";

const ORACLE_PX: Address = "0x0000000000000000000000000000000000000807";
const abi = JSON.parse(readFileSync(new URL("../out/LaunchPool.sol/LaunchPool.json", import.meta.url), "utf8")).abi;

const rpc = process.env.RPC_URL ?? "http://127.0.0.1:8545";
const pool = process.env.POOL as Address;
const account = privateKeyToAccount(process.env.PRIVATE_KEY as Hex);
const pub = createPublicClient({ transport: http(rpc) });
const wallet = createWalletClient({ account, transport: http(rpc) });
const once = process.argv.includes("--once");
const marketHours = process.env.MARKET_HOURS; // "nyse" or unset
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

let lastOracle = -1n;

async function tick() {
  const [dex, index, szDecimals] = await read("asset");
  const perp = dex * 10000 + index;
  const raw = await pub.call({ to: ORACLE_PX, data: encodeAbiParameters([{ type: "uint32" }], [perp]) });
  const [px] = decodeAbiParameters([{ type: "uint64" }], raw.data as Hex);
  const oracle = (px as bigint) * 10n ** (12n + BigInt(szDecimals));
  if (oracle !== lastOracle) {
    if (await send("poke")) lastOracle = oracle;
  }

  if (marketHours === "nyse") {
    const now = Number((await pub.getBlock()).timestamp);
    const shouldPause = marketStatus(now).status === "CLOSED";
    if ((await read("opensPaused")) !== shouldPause) await send("setOpensPaused", [shouldPause]);
  }

  const p = await read("getParams");
  const [maintenanceBps, settleDelay] = [BigInt(p.maintenanceBps), BigInt(p.settleDelay)];
  const now = (await pub.getBlock()).timestamp;
  // only pending and open positions: closed and cancelled ids leave this list on chain
  const ids: bigint[] = await read("activeIds");
  for (const id of ids) {
    const [owner, long, leverage, margin, entry, requestedAt, closing] = await read("positions", [id]);
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
  if (!once) await new Promise((r) => setTimeout(r, 1000));
} while (!once);
