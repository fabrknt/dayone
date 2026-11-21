# Choosing the numbers for your market

The pool's safety rests on a handful of parameters (`LaunchPool.Params` and `HLPriceGuard.Bounds`
in the constructor). `script/DeployTestnet.s.sol` shows them for xyz:TSLA on testnet, with mock
USDC as collateral and the mark, mid and reference bounds off (the testnet book sits far from its
oracle); a real deployment needs real collateral and those bounds on (section 5). This page says
where each number comes from. Every number below is a starting point to check against your own
book, not a guarantee. The method and data behind them are in hl-price-guard's
`lib/hl-price-guard/docs/safe-limits.md`.

## 1. Settlement cap per minute: from the book's depth
`capPerWindow` over `capWindow` (60 s) bounds how much notional can settle in any minute, opens
and closes separately. In the replay of Papertrade's 2026-10-10 incident, a cap on what can settle
is the measure that turns the push from profitable to loss-making (a scenario estimate, not a
bound: safe-limits §4); choosing the oracle over the book's price cut the take only 15%.

    cap per minute ~= 0.27 * depth10 / k

`depth10` is the depth within 10 bp of mid on the thinner side of the book (take a low percentile,
p10, since a push picks a thin moment) and `k` a safety factor (3 in the examples). Measure your
market with hl-price-guard's `lib/hl-price-guard/measure/safe_caps.py`; safe-limits §4 has a table for the xyz markets
(xyz:TSLA came to about $30K–50K a minute in October 2026). 0.27 rests on one incident on one asset,
so leave margin.

`maxNotional` (one position) must not exceed the cap: a position larger than the cap can never
settle.

## 2. Seed and stress move: how much interest the pool can carry
A new position settles only if, after a `stressMoveBps` move either way, the pool could still pay
every winner from its balance. Each side is counted gross: a move up must be payable to every
long, a move down to every short, and a short never offsets a long. With entries near the current
price:

    notional the seed backs, per side ~= seed / stressMoveBps

A $10,000 seed at 10% backs about $100,000 of longs and, separately, about $100,000 of shorts.
Older entries far from the price use up more room. Pick `stressMoveBps` from the largest move you
expect between two keeper ticks that matters: an earnings gap or the open after a weekend for a
stock perp. It cannot go under 5% off a local chain (`MIN_STRESS_BPS`).

For xyz:TSLA, the testnet pool at 10%: from 2010-06-29 to 2026-11-20 TSLA's move from one close to
the next open passed 10% on 26 of 4,125 closures (17 weeknights, 6 weekends, 3 holidays), at most
+25.7% (2013-05-09) and −14.9% (2020-09-08). On those closures the backing check no longer
promises that every winner is paid from the balance; whether any profit actually waits in the
FIFO queue depends on the open interest, the entries and the balance at the time. 17% would have
covered every weekend and holiday since 2010; only weeknights went further. These are the moves
of a price held across the closure, and xyz's oracle out of hours is not that, so they bound the
size of the gap rather than predict the move between two keeper ticks. Per-name tables (p99 and
the largest fall and rise for each closure type, for SPY, QQQ, NVDA, MSTR and others; every move
over 10%) and the script are in
[fabrknt/research `2026-11-21-lender-thresholds`](https://github.com/fabrknt/research/tree/9e88cc6/2026-11-21-lender-thresholds)
(`results/closures.csv`, `results/exceedances.csv`).

`maxNetNotional` is a different limit: it caps |long − short| open interest, what one move can
cost the pool in the end. The backing check is usually the tighter of the two while the pool is
small.

Moves past the stress size are the one case where future losers pay today's winners (the FIFO
queue). If that is not acceptable for your market, see "Not done" in the README: capping each
position's profit at notional × `stressMoveBps` makes the backing exact.

## 3. Jump latch
`maxJumpBps` is the largest move from the last accepted oracle the pool takes before it waits for
a `rearm`: wide enough that ordinary updates never trip it, narrow enough that a bad update like
SK Hynix's (2026-07-27, `cases/skhx-20260727` in hl-price-guard) does. On xyz the deployer's oracle
moved at most 66 bp within 90 s in our sample (safe-limits §3), so 200 bp is a first estimate.
There is no script yet that measures this per market: `lib/hl-price-guard/measure/normal_gaps.py` reports
mark–oracle, mid–oracle and the spread, not the oracle's own steps.

## 4. Fees, haircut and rebate
Keep `rebateBps` under `winHaircutMinBps` (the contract enforces it): that is what makes washing
between two of your own accounts lose money. The defaults (rebate 12%, haircut 30% falling to 15%
between a 0.25% and a 1% move) follow Papertrade's curve.

## 5. Price bounds and an independent reference
`maxMarkOracleBps`, `maxMidOracleBps` and `maxSpreadBps` reject a read when HL's own prices
disagree. Set each 2–3 times above its normal maximum on your market (safe-limits §2,
`lib/hl-price-guard/measure/normal_gaps.py`; xyz:TSLA's mid–oracle p99 was 38.5 bp in the opening hour).

They cannot catch a wrong oracle, because on HIP-3 one deployer posts it and the book follows.
That needs `maxRefOracleBps` against a price from outside Hyperliquid, updated in the same
transaction (`PythRef` in hl-price-guard; Pyth's update data needs a Hermes API key). For stocks a
first estimate is 150 bp in trading hours (safe-limits §3). The testnet example leaves it at 0.

## 6. Trading hours and halts
For a stock perp, run the keeper with `MARKET_HOURS=nyse` (or `krx`) so new positions pause while
there is no listed price to check the oracle against. `PRIMARY_HALTS=<symbol>` also pauses them
during a Nasdaq halt; it needs the `prebell` package, which is not public yet.
