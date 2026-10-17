import { useCallback, useEffect, useMemo, useState } from "react";
import { maxUint256, type Address, type PublicClient, type WalletClient } from "viem";
import { loadConfig, makeClients, poolAbi, usdcAbi, readMarket, why, type Config, type Market } from "./chain";

const USDC = 1_000_000n;
const ZERO: Address = "0x0000000000000000000000000000000000000000";

type Pos = {
  id: bigint; long: boolean; leverage: number; margin: bigint; entry: bigint; requestedAt: bigint; closing: boolean;
};
type PoolState = {
  poolBalance: bigint; totalDebt: bigint; totalShares: bigint; longOI: bigint; shortOI: bigint;
  openUsed: bigint; closeUsed: bigint; capPerWindow: bigint; capWindow: bigint; maxNet: bigint;
  maxLeverage: number; maxNotional: bigint; feeBps: number; settleDelay: bigint; winHaircutBps: number; rebateBps: number;
  opensPaused: boolean; graduated: boolean; equity: bigint;
};
type Me = { address: Address; usdc: bigint; allowance: bigint; shares: bigint; positions: Pos[] };

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
    r("getParams"), r("opensPaused"), r("graduated"), r("equity", [oracle]),
  ]);
  return {
    poolBalance, totalDebt, totalShares, longOI, shortOI, openUsed, closeUsed,
    maxLeverage: p.maxLeverage, feeBps: p.feeBps, settleDelay: p.settleDelay, capWindow: p.capWindow,
    capPerWindow: p.capPerWindow, maxNotional: p.maxNotional, maxNet: p.maxNetNotional,
    winHaircutBps: p.winHaircutBps, rebateBps: p.rebateBps,
    opensPaused, graduated, equity,
  };
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
  return { address, usdc: usdc as bigint, allowance: allowance as bigint, shares, positions };
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
    const t = setInterval(refresh, 2000);
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
  const fee = pool ? (notional * BigInt(pool.feeBps)) / 10000n : 0n;

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
  const status = !market ? null : market.guard ? "paused" : pool?.graduated ? "graduated" : pool?.opensPaused ? "closed" : "live";

  return (
    <div className="shell">
      <Header market={cfg.market} />

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
                Winners keep {pool ? 100 - pool.winHaircutBps / 100 : 70}% of profit; losers get pool shares worth {pool ? pool.rebateBps / 100 : 20}% of their loss.
              </p>
            </>
          )}
          {note && <div className="note">{note}</div>}
        </section>

        <section className="card">
          <h2>Pool</h2>
          <div className="facts">
            <span>Balance</span><span className="mono">{pool ? usd(pool.poolBalance) : "—"}</span>
            <span>Owed to winners (queue)</span><span className="mono">{pool ? usd(pool.totalDebt) : "—"}</span>
            <span>Equity after open profits</span><span className="mono">{pool ? usd(pool.equity) : "—"}</span>
            <span>Long / short open</span><span className="mono">{pool ? `${usd(pool.longOI, 0)} / ${usd(pool.shortOI, 0)}` : "—"}</span>
          </div>
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

      {me && me.positions.length > 0 && (
        <section className="card">
          <h2>Your positions</h2>
          <table>
            <thead><tr><th>#</th><th>Side</th><th>Size</th><th>Entry</th><th>PnL at oracle</th><th>Status</th><th></th></tr></thead>
            <tbody>
              {me.positions.map((p) => {
                const v = market ? pnl(p, market.oracle) : 0n;
                const st = p.entry === 0n ? "settling" : p.closing ? "closing" : "open";
                return (
                  <tr key={String(p.id)}>
                    <td className="mono">{String(p.id)}</td>
                    <td className={p.long ? "long" : "short"}>{p.long ? "Long" : "Short"} {p.leverage}x</td>
                    <td className="mono">{usd(p.margin * BigInt(p.leverage), 0)}</td>
                    <td className="mono">{p.entry ? px(p.entry) : "—"}</td>
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
          <li><b>Losses fund the pool.</b> Losers get pool shares worth {pool ? pool.rebateBps / 100 : 20}% of what they lost; winners give {pool ? pool.winHaircutBps / 100 : 30}% of profit to the pool. Profit the pool can't pay yet is queued and paid from later losses.</li>
        </ol>
      </section>

      <footer className="fine">
        Prices are Hyperliquid's oracle for this HIP-3 market, read on HyperEVM and checked against the book, an independent
        reference and the last accepted price. Test deployment: test USDC only.
      </footer>
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
