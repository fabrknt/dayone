# Day One — Fabrknt Labs

Private. Research and a reference implementation, not a product. Not offered to traders.
It studies how to make a newly listed HIP-3 perp tradable from day one without inviting the attacks
a thin book invites: initial liquidity, price anomalies, exposure caps and stop conditions.
Part of Fabrknt for HIP-3 (fabrknt.com/hip3/labs/day-one); it moves forward only when an operator
(design partner) has a concrete need for it.

The mechanism studied: a loss-funded counterparty pool for a newly listed HIP-3 perp, run by the
market's deployer while the book is thin, and retired once it is deep enough.

- **Loss-funded.** Starts empty; traders' losses and fees fill it. Profits the pool cannot pay yet
  wait in a FIFO queue, paid from later losses (the Papertrade model).
- **Rebates and haircut.** Losers get pool shares worth `rebateBps` of their loss (default 20%);
  winners give `winHaircutBps` of their profit to the pool (default 30%). rebate < haircut is
  enforced, which is what makes washing between two own accounts lose money.
- **Shares priced high, redeemed low.** New shares are priced at `shareValuation()` = balance +
  open positions' margin − queued debt, the most today's positions can bring in (each loses at
  most its margin). Redemption pays out of `equity()`, which reserves, per side, that side's PnL
  plus its margin, so open losses never offset open winners. The first mint locks the rest of the
  valuation in shares the contract holds, so no early holder owns the pool.
- **Settlement.** Two-step: request, then anyone settles after `settleDelay` at HL's oracle read
  through hl-price-guard's `HLPriceGuard` (bounds, an independent reference, a jump latch). Any
  breach makes settlement and liquidation wait.
- **Caps.** Opens and closes each have a rolling notional cap (`ExposureBudget.Rolling`), so opens
  cannot use up the budget due closes need; net open interest is capped too. On replay of
  Papertrade's 10-10 incident, the per-minute cap is what made the push unprofitable; choosing the
  oracle over the BBO cut it only 15%.
- **Operator limits.** Parameter, bounds and reference changes take effect `paramsDelay` after
  they are proposed; raising the cap or changing its window also needs opens paused. Each
  position keeps the fee, haircut and maintenance it was opened with. `rearm` (after a real gap
  trips the latch), pausing opens and `graduate()` are immediate.
- **Hygiene.** A minimum position size, an on-chain list of active ids for keepers, a reentrancy
  guard, and the optimizer on (16.8 KB runtime, under the 24 KB limit).

Design, replay results and competitors: `docs/design.md` (Japanese).

## Layout
- `src/LaunchPool.sol`, `test/LaunchPool.t.sol` (25 tests, including one regression per review
  finding: `test_r1_*`, `test_r2_*`)
- `lib/hl-price-guard`: price reading and caps from HL Price Guard (`fabrknt/hl-price-guard`), as a
  submodule pinned to one commit. Policy: pin only tagged versions, and move to a newer tag on purpose
  (`git -C lib/hl-price-guard checkout vX.Y.Z`, then run the tests), never to its latest commit.
  Today the pin is `5d78517`, which is untagged; moving it to `v0.2.1` is pending (`v0.2.0` has a
  `Rolling.reconfigure` bug). Changes to the library are made
  in that repo; it does not depend on Day One.
- `keeper/keeper.ts`: pokes on each oracle change, settles due requests, liquidates; with
  `MARKET_HOURS=nyse` it pauses new positions while NYSE is closed (`keeper/campana.mjs`).
  `keeper/e2e.sh` runs it end to end on anvil with the precompiles mocked at their real addresses.

## Web UI
`web/`: trade, pool and positions in one page (Vite + React + viem).
- Local: `./keeper/dev.sh` (anvil, mock precompiles, pool, keeper, a moving price), then
  `cd web && npm install && npm run dev`. The dev wallet is anvil's key 1.
  `echo 0.85 > /tmp/dayone-shock` replays an SK Hynix-style bad update: the page shows the pause.
- Testnet: `?net=testnet&pool=0x…&usdc=0x…` with a browser wallet.

## Review
Codex reviews each change that moves money, and proves each finding with a PoC test before it is
fixed (PoCs live in throwaway worktrees, not in this repo).

| Round | Verdict | Findings |
|---|---|---|
| 1 (e362390) | CHANGES | 6, all fixed in f93543b: cross-side netting in equity, first loser owning the pool, fees repriced under pending requests, opens blocking closes, rounding, unbounded keeper scan |
| 2 (f93543b) | CHANGES | share pricing reopened (first mint could skip the lock), cap raises blockable forever; fixed in 2558cd0, plus a reentrancy guard |
| 3 (2558cd0) | CHANGES | share pricing reopened again (repeated wash pairs diluted the lock); redesigned in b92ae5a: shares priced at `shareValuation()`; maintenance stored per position |
| 4 (b92ae5a) | interrupted | Codex usage limit. The three round 3 attacks were rerun and are closed (a five-pair wash nets −$18,644 after redeeming); the independent check of the upper-bound claim is still to do |

## Not done
Review round 4 to completion; testnet deployment (prepared: `docs/testnet.md`, needs a funded key
with big blocks on); market-hours calendars other than NYSE (KRX for xyz:SKHX and xyz:SMSN); audit.

`forge test` (25 tests); `npm install && ./keeper/e2e.sh` (8 checks).
