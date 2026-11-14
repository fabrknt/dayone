import { useCallback, useEffect, useMemo, useState } from "react";
import { maxUint256, type Address, type PublicClient, type WalletClient } from "viem";
import { backingRoom } from "./room";
import { loadConfig, makeClients, poolAbi, legacyPoolAbi, usdcAbi, readMarket, why, type Config, type Market } from "./chain";

const USDC = 1_000_000n;
const ZERO: Address = "0x0000000000000000000000000000000000000000";

type Pos = {
  id: bigint; long: boolean; leverage: number; margin: bigint; entry: bigint; requestedAt: bigint; closing: boolean;
};
type PoolState = {
  poolBalance: bigint; totalDebt: bigint; totalShares: bigint; longOI: bigint; shortOI: bigint;
  openUsed: bigint; closeUsed: bigint; capPerWindow: bigint; capWindow: bigint; maxNet: bigint;
  maxLeverage: number; maxNotional: bigint; feeBps: number; settleDelay: bigint; winHaircutBps: number; winHaircutMinBps: number; haircutFromMoveBps: number; haircutToMoveBps: number; rebateBps: number;
  opensPaused: boolean; graduated: boolean; equity: bigint;
  backing: Backing | null; // null for a pool from before the backing check
};
// What the backing check allows now, and how long the queue has waited.
type Backing = { stressBps: number; up: bigint; down: bigint; roomLong: bigint; roomShort: bigint; oldestAt: bigint | null };
type Claim = { id: bigint; claimable: bigint; waiting: bigint };
type Me = { address: Address; usdc: bigint; allowance: bigint; shares: bigint; positions: Pos[]; claims: Claim[] };

const usd = (v: bigint, dp = 2) => {
  const n = Number(v) / 1e6;
  return "$" + n.toLocaleString(undefined, { minimumFractionDigits: dp, maximumFractionDigits: dp });
};
const px = (v: bigint) => (Number(v) / 1e18).toLocaleString(undefined, { minimumFractionDigits: 3, maximumFractionDigits: 3 });
const bps = (a: bigint, b: bigint) => (b === 0n ? 0 : (Number(a - b) / Number(b)) * 1e4);

function pnl(p: Pos, oracle: bigint): bigint {
  if (p.entry === 0n) return 0n;
  const notional = p.margin * BigInt(p.leverage);
  const move = ((oracle - p.entry) * notional) / p.entry;
  return p.long ? move : -move;
}

async function readPool(pub: PublicClient, pool: Address, oracle: bigint): Promise<PoolState> {
  const r = (fn: string, args: unknown[] = []) => pub.readContract({ address: pool, abi: poolAbi, functionName: fn, args }) as Promise<any>;
  const [poolBalance, totalDebt, totalShares, longOI, shortOI, openUsed, closeUsed, p, opensPaused, graduated, equity] = await Promise.all([
    r("poolBalance"), r("totalDebt"), r("totalShares"), r("longOI"), r("shortOI"), r("openLaneUsed"), r("closeLaneUsed"),
    r("getParams").catch(() => pub.readContract({ address: pool, abi: legacyPoolAbi, functionName: "getParams" })), r("opensPaused"), r("graduated"), r("equity", [oracle]),
  ]);
  const backing = p.stressMoveBps ? await readBacking(r, oracle, Number(p.stressMoveBps), poolBalance, totalDebt) : null;
  return {
    backing,
    poolBalance, totalDebt, totalShares, longOI, shortOI, openUsed, closeUsed,
    maxLeverage: p.maxLeverage, feeBps: p.feeBps, settleDelay: p.settleDelay, capWindow: p.capWindow,
    capPerWindow: p.capPerWindow, maxNotional: p.maxNotional, maxNet: p.maxNetNotional,
    winHaircutBps: p.winHaircutBps, winHaircutMinBps: p.winHaircutMinBps, haircutFromMoveBps: p.haircutFromMoveBps, haircutToMoveBps: p.haircutToMoveBps, rebateBps: p.rebateBps,
    opensPaused, graduated, equity,
  };
}

/// How much more each side can open before a stressBps move would owe more than the balance
/// (the pool's profitBound: every long counted from the lowest long entry, every short from the
/// highest short entry), and when the oldest unpaid winner was queued.
async function readBacking(r: (fn: string, args?: unknown[]) => Promise<any>, oracle: bigint, stressBps: number, balance: bigint, totalDebt: bigint): Promise<Backing> {
  const [[up, down], longMin, shortMax, longCount, shortCount, longUnits, shortUnits, count, paid]: bigint[][] & any = await Promise.all([
    r("stressOwed", [oracle]), r("longEntryMin"), r("shortEntryMax"), r("longCount"), r("shortCount"), r("longUnits"), r("shortUnits"),
    r("debtCount"), r("debtPaid"),
  ]);
  const s = BigInt(stressBps);
  const stressed = [(oracle * (10_000n + s)) / 10_000n + 1n, (oracle * (10_000n - s)) / 10_000n];
  const st = { oracle, balance, totalDebt, stressed, longMin, shortMax, longCount, shortCount, longUnits, shortUnits };
  let oldestAt: bigint | null = null;
  const key = `${count}:${paid}`;
  if (totalDebt > 0n && oldestCache.key === key) oldestAt = oldestCache.at;
  else if (totalDebt > 0n) {
    // the queue is paid in order: the oldest unpaid entry is the first whose end is past debtPaid
    let lo = 0n, hi: bigint = count - 1n;
    while (lo < hi) {
      const mid = (lo + hi) / 2n;
      const [, , start, amount] = await r("debts", [mid]);
      if (start + amount > paid) hi = mid; else lo = mid + 1n;
    }
    oldestAt = (await r("debts", [lo]))[1];
    oldestCache = { key, at: oldestAt };
  }
  return { stressBps, up, down, roomLong: backingRoom(st, true), roomShort: backingRoom(st, false), oldestAt };
}
// the oldest unpaid entry only changes when the queue grows or is paid
let oldestCache: { key: string; at: bigint | null } = { key: "", at: null };

/// The caller's queued winnings among the newest CLAIM_WINDOW queue entries. Re-read only when
/// the queue grows, is paid or something is claimed.
const CLAIM_WINDOW = 200n;
let claimsCache: { key: string; claims: Claim[] } = { key: "", claims: [] };
async function readClaims(r: (fn: string, args?: unknown[]) => Promise<any>, address: Address): Promise<Claim[]> {
  let count: bigint, paid: bigint, unclaimed: bigint;
  try { [count, paid, unclaimed] = await Promise.all([r("debtCount"), r("debtPaid"), r("unclaimed")]); } catch { return []; } // a pool from before claim()
  const key = `${address}:${count}:${paid}:${unclaimed}`;
  if (claimsCache.key === key) return claimsCache.claims;
  const from = count > CLAIM_WINDOW ? count - CLAIM_WINDOW : 0n;
  const ids: bigint[] = [];
  for (let i = from; i < count; i++) ids.push(i);
  const rows = await Promise.all(ids.map((i) => r("debts", [i])));
  const mine = ids.filter((_, k) => (rows[k][0] as string).toLowerCase() === address.toLowerCase() && rows[k][3] > rows[k][4]);
  const claimable = await Promise.all(mine.map((i) => r("claimable", [i]))) as bigint[];
  const claims = mine.map((id, k) => {
    const row = rows[ids.indexOf(id)];
    return { id, claimable: claimable[k], waiting: (row[3] as bigint) - (row[4] as bigint) - claimable[k] };
  });
  claimsCache = { key, claims };
  return claims;
}

async function readMe(pub: PublicClient, c: Config, address: Address): Promise<Me> {
  const r = (fn: string, args: unknown[] = []) => pub.readContract({ address: c.pool, abi: poolAbi, functionName: fn, args }) as Promise<any>;
  const [usdc, allowance, shares, ids] = await Promise.all([
    pub.readContract({ address: c.usdc, abi: usdcAbi, functionName: "balanceOf", args: [address] }),
    pub.readContract({ address: c.usdc, abi: usdcAbi, functionName: "allowance", args: [address, c.pool] }),
    r("shares", [address]),
    r("activeIds") as Promise<bigint[]>,
  ]);
  const raw = await Promise.all(ids.map((id) => r("positions", [id])));
  const positions = raw
    .map((p: any, i) => ({ id: ids[i], owner: p[0] as Address, long: p[1], leverage: Number(p[2]), margin: p[3], entry: p[4], requestedAt: p[5], closing: p[6] }))
    .filter((p) => p.owner.toLowerCase() === address.toLowerCase());
  return { address, usdc: usdc as bigint, allowance: allowance as bigint, shares, positions, claims: await readClaims(r, address) };
}

export default function App() {
  const [cfg, setCfg] = useState<Config | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [wallet, setWallet] = useState<WalletClient | null>(null);
  const [market, setMarket] = useState<Market | null>(null);
  const [pool, setPool] = useState<PoolState | null>(null);
  const [me, setMe] = useState<Me | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const [long, setLong] = useState(true);
  const [margin, setMargin] = useState("1000");
  const [lev, setLev] = useState(10);

  useEffect(() => { loadConfig().then(setCfg).catch((e) => setErr(String(e.message ?? e))); }, []);
  const clients = useMemo(() => (cfg ? makeClients(cfg) : null), [cfg]);
  const address = (wallet?.account?.address ?? null) as Address | null;

  const refresh = useCallback(async () => {
    if (!cfg || !clients) return;
    try {
      const m = await readMarket(clients.pub, cfg.pool, address ?? ZERO);
      setMarket(m);
      setPool(await readPool(clients.pub, cfg.pool, m.oracle));
      if (address) setMe(await readMe(clients.pub, cfg, address));
      setErr(null);
    } catch (e) {
      setErr(why(e));
    }
  }, [cfg, clients, address]);

  useEffect(() => {
    refresh();
    const t = setInterval(refresh, 5000);
    return () => clearInterval(t);
  }, [refresh]);

  const connect = async () => {
    try { setWallet(await clients!.wallet()); } catch (e) { setNote(why(e)); }
  };

  const tx = async (label: string, address: Address, abi: any, functionName: string, args: unknown[] = []) => {
    if (!wallet || !clients) return;
    setBusy(label); setNote(null);
    try {
      const { request } = await clients.pub.simulateContract({ account: wallet.account!, address, abi, functionName, args });
      const hash = await wallet.writeContract(request as any);
      await clients.pub.waitForTransactionReceipt({ hash });
      await refresh();
      return true;
    } catch (e) {
      setNote(why(e));
      return false;
    } finally {
      setBusy(null);
    }
  };

  const marginUnits = BigInt(Math.max(0, Math.floor(Number(margin) || 0))) * USDC;
  const notional = marginUnits * BigInt(lev);
  const fee = pool ? (notional * BigInt(pool.feeBps) + 9999n) / 10000n : 0n; // rounded up, as the pool does

  const open = async () => {
    if (!cfg || !me) return;
    if (me.allowance < marginUnits + fee && !(await tx("Approving", cfg.usdc, usdcAbi, "approve", [cfg.pool, maxUint256]))) return;
    if (await tx("Requesting", cfg.pool, poolAbi, "requestOpen", [long, marginUnits, lev])) {
      setNote(`Requested. It settles at the oracle after ${pool?.settleDelay ?? 3n} s, when the keeper next runs.`);
    }
  };

  if (err && !cfg) return <div className="shell"><Header /><div className="card warn">{err}</div></div>;
  if (!cfg) return <div className="shell"><Header /></div>;

  const mid = market ? (market.bid + market.ask) / 2n : 0n;
  const net = pool ? (pool.longOI > pool.shortOI ? pool.longOI - pool.shortOI : pool.shortOI - pool.longOI) : 0n;
  const sharePrice = pool && pool.totalShares > 0n ? (pool.equity * 10n ** 18n) / pool.totalShares : 0n;
  const myShareValue = me && pool && pool.totalShares > 0n ? (me.shares * pool.equity) / pool.totalShares : 0n;
  const status = !market ? null : market.guard ? "paused" : pool?.graduated ? "graduated" : pool?.opensPaused ? "closed"
    : pool?.backing && pool.totalDebt > 0n ? "queued" : "live";

  return (
    <div className="shell">
      <Header market={cfg.market} />
      {err && <div className="card warn">Could not read the pool: {err}</div>}

      <section className="ticker card">
        <div>
          <div className="label">Oracle (settles here)</div>
          <div className="big mono">{market ? px(market.oracle) : "—"}</div>
        </div>
        <div>
          <div className="label">HL book mid</div>
          <div className="mono">{market ? px(mid) : "—"} <span className="dim">({market ? bps(mid, market.oracle).toFixed(1) : "—"} bp)</span></div>
        </div>
        <div>
          <div className="label">Mark</div>
          <div className="mono">{market ? px(market.mark) : "—"}</div>
        </div>
        <div className={`pill ${status ?? ""}`}>
          {status === "live" && "Live"}
          {status === "paused" && "Price check failed: waiting"}
          {status === "closed" && "New positions paused"}
          {status === "queued" && "New positions stopped: winners waiting to be paid"}
          {status === "graduated" && "Graduated: closes only"}
        </div>
        {market?.guard && <div className="guard">{market.guard}</div>}
      </section>

      <div className="grid">
        <section className="card">
          <h2>Trade</h2>
          {!address ? (
            <button className="primary" onClick={connect}>{cfg.devKey ? "Use the dev wallet" : "Connect wallet"}</button>
          ) : (
            <>
              <div className="row between">
                <span className="dim mono">{address.slice(0, 6)}…{address.slice(-4)}</span>
                <span className="mono">{me ? usd(me.usdc) : "—"} USDC</span>
              </div>
              <button className="ghost" disabled={!!busy} onClick={() => tx("Minting", cfg.usdc, usdcAbi, "mint", [address, 10_000n * USDC])}>
                {busy === "Minting" ? "Minting…" : "Get 10,000 test USDC"}
              </button>
              <div className="seg">
                <button className={long ? "on long" : ""} onClick={() => setLong(true)}>Long</button>
                <button className={!long ? "on short" : ""} onClick={() => setLong(false)}>Short</button>
              </div>
              <label>Margin (USDC)<input className="mono" value={margin} onChange={(e) => setMargin(e.target.value)} inputMode="decimal" /></label>
              <label>Leverage: {lev}x<input type="range" min={1} max={pool?.maxLeverage ?? 20} value={lev} onChange={(e) => setLev(Number(e.target.value))} /></label>
              <div className="facts">
                <span>Size</span><span className="mono">{usd(notional, 0)}</span>
                <span>Open fee</span><span className="mono">{usd(fee)}</span>
                <span>Max size</span><span className="mono">{pool ? usd(pool.maxNotional, 0) : "—"}</span>
              </div>
              <button className="primary" disabled={!!busy || status !== "live" || marginUnits === 0n} onClick={open}>
                {busy ? `${busy}…` : long ? "Open long" : "Open short"}
              </button>
              <p className="fine">
                Two steps: you request now, and it settles at the oracle once {String(pool?.settleDelay ?? 3n)} s have passed.
                Winners keep {pool ? 100 - pool.winHaircutBps / 100 : 70}% of profit on small moves, rising to {pool ? 100 - pool.winHaircutMinBps / 100 : 85}% once the price has moved {pool ? pool.haircutToMoveBps / 100 : 1}%; losers get pool shares worth {pool ? pool.rebateBps / 100 : 12}% of their loss. These are the terms for new positions; each position keeps the terms it was opened with.
              </p>
            </>
          )}
          {note && <div className="note">{note}</div>}
        </section>

        <section className="card">
          <h2>Pool</h2>
          <div className="facts">
            <span>Payable now</span><span className="mono">{pool ? usd(pool.poolBalance) : "—"}</span>
            <span>Owed to winners (queue)</span><span className="mono">{pool ? usd(pool.totalDebt) : "—"}</span>
            {pool?.backing?.oldestAt && <><span>Oldest waiting</span><span className="mono">{since(pool.backing.oldestAt)}</span></>}
            <span>Equity after open profits</span><span className="mono">{pool ? usd(pool.equity) : "—"}</span>
            <span>Long / short open</span><span className="mono">{pool ? `${usd(pool.longOI, 0)} / ${usd(pool.shortOI, 0)}` : "—"}</span>
          </div>
          {pool?.backing && <BackingView b={pool.backing} queued={pool.totalDebt > 0n} />}
          <Meter label="Net exposure" used={net} cap={pool?.maxNet ?? 0n} />
          <Meter label="Opens, last minute" used={pool?.openUsed ?? 0n} cap={pool?.capPerWindow ?? 0n} />
          <Meter label="Closes, last minute" used={pool?.closeUsed ?? 0n} cap={pool?.capPerWindow ?? 0n} />
          <p className="fine">
            The per-minute cap is the main defence: on replay of Papertrade's 10-10 incident it made the price push cost more than it paid.
          </p>
          {me && me.shares > 0n && (
            <div className="shares">
              <div className="row between"><span>Your shares</span><span className="mono">{usd(myShareValue)}</span></div>
              <button className="ghost" disabled={!!busy} onClick={() => tx("Redeeming", cfg.pool, poolAbi, "redeem", [me.shares])}>Redeem</button>
            </div>
          )}
          {pool && pool.totalShares > 0n && <p className="fine">Share value: {(Number(sharePrice) / 1e18).toFixed(4)} USDC per share unit.</p>}
        </section>
      </div>

      {me && me.claims.length > 0 && (
        <section className="card">
          <h2>Your queued winnings</h2>
          <p className="fine">Profit the pool could not pay when you closed, among the newest {String(CLAIM_WINDOW)} queue entries (an older one can be received with claim(id) directly). Later losses and the operator's capital pay the queue in order; what has been paid is yours to receive (the keeper usually sends it for you).</p>
          <table>
            <thead><tr><th className="wide-only">#</th><th>Ready</th><th>Still waiting</th><th></th></tr></thead>
            <tbody>
              {me.claims.map((c) => (
                <tr key={String(c.id)}>
                  <td className="mono wide-only">{String(c.id)}</td>
                  <td className="mono up">{usd(c.claimable)}</td>
                  <td className="mono">{usd(c.waiting)}</td>
                  <td>{c.claimable > 0n && <button className="ghost small" disabled={!!busy} onClick={() => tx("Receiving", cfg.pool, poolAbi, "claim", [c.id])}>Receive</button>}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      )}

      {me && me.positions.length > 0 && (
        <section className="card">
          <h2>Your positions</h2>
          <table>
            <thead><tr><th className="wide-only">#</th><th>Side</th><th>Size</th><th className="wide-only">Entry</th><th>PnL at oracle</th><th>Status</th><th></th></tr></thead>
            <tbody>
              {me.positions.map((p) => {
                const v = market ? pnl(p, market.oracle) : 0n;
                const st = p.entry === 0n ? "settling" : p.closing ? "closing" : "open";
                return (
                  <tr key={String(p.id)}>
                    <td className="mono wide-only">{String(p.id)}</td>
                    <td className={p.long ? "long" : "short"}>{p.long ? "Long" : "Short"} {p.leverage}x</td>
                    <td className="mono">{usd(p.margin * BigInt(p.leverage), 0)}</td>
                    <td className="mono wide-only">{p.entry ? px(p.entry) : "—"}</td>
                    <td className={`mono ${v >= 0n ? "up" : "down"}`}>{p.entry ? usd(v) : "—"}</td>
                    <td>{st}</td>
                    <td>
                      {st === "open" && <button className="ghost small" disabled={!!busy} onClick={() => tx("Closing", cfg.pool, poolAbi, "requestClose", [p.id])}>Close</button>}
                      {st === "settling" && <button className="ghost small" disabled={!!busy} onClick={() => tx("Cancelling", cfg.pool, poolAbi, "cancelOpen", [p.id])}>Cancel</button>}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </section>
      )}

      <section className="card how">
        <h2>How it works</h2>
        <ol>
          <li><b>New listings have thin books.</b> Day One takes the other side of your trade while the HL book fills up, and steps back once it is deep enough.</li>
          <li><b>Fills at the oracle, two steps.</b> You request, and it fills at the next price once {String(pool?.settleDelay ?? 3n)} s have passed, so nobody can trade on a price they already know.</li>
          <li><b>It stops rather than fill at a bad price.</b> If the oracle jumps, disagrees with HL's book or with an outside price, every fill and liquidation waits.</li>
          {pool?.backing ? (
            <li><b>It only takes what it can pay.</b> The operator puts in starting capital. A new position is accepted only if, after a {pool.backing.stressBps / 100}% move either way, the pool could still pay every winner from its balance, and nothing new opens while any winner is waiting to be paid. Moves larger than that can still leave winners waiting.</li>
          ) : (
            <li><b>This pool has no backing check.</b> It was deployed before that check existed: new positions are limited only by the caps below, not by what the pool can pay.</li>
          )}
          <li><b>Losses add to the pool.</b> Losers get pool shares worth {pool ? pool.rebateBps / 100 : 12}% of what they lost; winners give the pool {pool ? pool.winHaircutBps / 100 : 30}% of profit on small moves, falling to {pool ? pool.winHaircutMinBps / 100 : 15}% on moves of {pool ? pool.haircutToMoveBps / 100 : 1}% or more. Profit the pool can't pay yet is queued and paid from later losses.</li>
        </ol>
      </section>

      <footer className="fine">
        Prices are Hyperliquid's oracle for this HIP-3 market, read on HyperEVM and checked against the book, an independent
        reference and the last accepted price. Test deployment: test USDC only.
      </footer>
    </div>
  );
}

function since(at: bigint): string {
  const s = Math.max(0, Math.floor(Date.now() / 1000) - Number(at));
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60);
  return h > 0 ? `${h} h ${m} min` : `${m} min`;
}

function BackingView({ b, queued }: { b: Backing; queued: boolean }) {
  return (
    <div className="backing">
      {queued ? (
        <div className="note">New positions are stopped until the winners in the queue are paid.</div>
      ) : (
        <div className="facts">
          <span>Backing room, new longs</span><span className="mono">about {usd(b.roomLong, 0)}</span>
          <span>Backing room, new shorts</span><span className="mono">about {usd(b.roomShort, 0)}</span>
        </div>
      )}
      <p className="fine">
        Owed after a {b.stressBps / 100}% move: {usd(b.up, 0)} up, {usd(b.down, 0)} down. New positions are accepted only while both stay within the balance. The room is for one new position at today's price; the caps below and the price at settlement also apply.
      </p>
    </div>
  );
}

function Header({ market }: { market?: string }) {
  return (
    <header className="top">
      <div className="brand">Day One</div>
      <div className="tag">Trade every HIP-3 listing from day one</div>
      {market && <div className="market mono">{market}</div>}
    </header>
  );
}

function Meter({ label, used, cap }: { label: string; used: bigint; cap: bigint }) {
  const pct = cap === 0n ? 0 : Math.min(100, Number((used * 10000n) / cap) / 100);
  return (
    <div className="meter">
      <div className="row between"><span>{label}</span><span className="mono dim">{usd(used, 0)} / {usd(cap, 0)}</span></div>
      <div className="bar"><div style={{ width: `${pct}%` }} className={pct > 80 ? "hot" : ""} /></div>
    </div>
  );
}
