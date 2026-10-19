// Runs keeper.ts's real sendClaims (extracted, types stripped) against an in-memory queue: a
// claim that always fails at the head, restarts every tick, a mostly unpaid queue, partial
// payments and growth (Codex rounds 9-9c). node keeper/claims.test.mjs
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
import { randomInt } from "node:crypto";
const src = readFileSync(process.argv[2] ?? new URL("./keeper.ts", import.meta.url), "utf8");
const fn = src.slice(src.indexOf("async function sendClaims"), src.indexOf("\n}\n", src.indexOf("async function sendClaims")) + 2);
const js = stripTypeScriptTypes(fn);

function makeKeeper(q, opts) {
  const env = { CLAIM_SCAN: BigInt(opts.scan), CLAIMS_PER_TICK: opts.per, claimFrom: 0n, scanAt: undefined };
  const factory = new Function("q", "randomInt", "env", `
    let CLAIM_SCAN = env.CLAIM_SCAN, CLAIMS_PER_TICK = env.CLAIMS_PER_TICK, claimFrom = 0n, scanAt = undefined;
    const poolCall = (f, a = []) => ({ f, a });
    const poolResult = (f, r) => r;
    const batch = async (calls) => calls.map((c) => c.f === "debtCount" ? BigInt(q.debts.length) : c.f === "debtPaid" ? q.paid : (() => { const d = q.debts[Number(c.a[0])]; return [d.to, d.start, d.amount, d.done]; })());
    const send = async (f, [i]) => { const d = q.debts[Number(i)]; if (d.blocked) return false; const up = q.paid - d.start < d.amount ? q.paid - d.start : d.amount; d.done = up; return true; };
    ${js}
    return sendClaims;`);
  return factory(q, randomInt, env);
}
function queue(n, paidUpTo, blocked = []) {
  const debts = [];
  for (let i = 0; i < n; i++) debts.push({ to: "x", start: BigInt(i * 10), amount: 10n, done: 0n, blocked: blocked.includes(i) });
  return { debts, paid: BigInt(paidUpTo) };
}
const claimable = (q) => q.debts.filter((d) => !d.blocked && (q.paid - d.start > d.done) && d.done < d.amount).length;
let fails = 0;
function report(name, ok) { console.log(`${ok ? "ok  " : "FAIL"} ${name}`); if (!ok) fails++; }

// 1. restart every tick (fresh closure each time), blocked head, scan 1: worst case
for (const [n, scan] of [[2, 1], [51, 50], [200, 1]]) {
  const q = queue(n, n * 10, [0]);
  let t = 0;
  while (claimable(q) && t < 5000) { await makeKeeper(q, { scan, per: 3 })(); t++; }
  report(`restart every tick, blocked head, ${n} debts, scan ${scan}: done in ${t} restarts`, claimable(q) === 0);
}
// 2. mostly unpaid queue, restarts: 1000 debts, only first 5 paid
{
  const q = queue(1000, 50, [0]);
  let t = 0;
  while (claimable(q) && t < 100) { await makeKeeper(q, { scan: 50, per: 3 })(); t++; }
  report(`mostly unpaid (5 of 1000 paid), restart every tick: done in ${t}`, claimable(q) === 0);
}
// 3. long-running, partial payments and growth between ticks
{
  const q = queue(10, 0, [3]);
  const k = makeKeeper(q, { scan: 4, per: 2 });
  for (let t = 0; t < 200; t++) {
    q.paid += 7n; // partial payments
    if (t % 5 === 0) q.debts.push({ to: "x", start: BigInt(q.debts.length * 10), amount: 10n, done: 0n, blocked: false });
    await k();
  }
  const total = BigInt(q.debts.length * 10);
  if (q.paid > total) q.paid = total;
  for (let t = 0; t < 200 && claimable(q); t++) await k();
  report(`long-running with partial payments and growth: ${claimable(q)} left`, claimable(q) === 0);
}
process.exit(fails ? 1 : 0);
