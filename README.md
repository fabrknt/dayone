# Day One — Fabrknt Labs

Private. Research and a reference implementation, not a product. Not offered to traders.
Deployed on HyperEVM testnet against xyz:TSLA (2026-10-17, `docs/testnet.md`).
It studies how to make a newly listed HIP-3 perp tradable from day one without inviting the attacks
a thin book invites: initial liquidity, price anomalies, exposure caps and stop conditions.
Part of Fabrknt for HIP-3 (fabrknt.com/hip3/labs/day-one); it moves forward only when an operator
(design partner) has a concrete need for it.

The mechanism studied: a loss-funded counterparty pool for a newly listed HIP-3 perp, run by the
market's deployer while the book is thin, and retired once it is deep enough.

- **Loss-funded.** Starts empty; traders' losses and fees fill it. Profits the pool cannot pay yet
  wait in a FIFO queue, paid from later losses (the Papertrade model).
- **Rebates and haircut.** Losers get pool shares worth `rebateBps` of their loss (default 12%).
  Winners give the pool a share of their profit that falls with the size of the price move:
  `winHaircutBps` (30%) up to `haircutFromMoveBps` (0.25%), `winHaircutMinBps` (15%) from
  `haircutToMoveBps` (1%), linear in between (as Papertrade does: high on small wins, about 10%
  past a 1% move). It is measured on the price move, not on return on margin, so leverage cannot
  buy a lower rate. Each position keeps the curve and the rebate in force at its request. rebate < the curve's
  floor is
  enforced, which is what makes washing between two own accounts lose money.
- **Shares priced high, redeemed low.** New shares are priced at `shareValuation()` = balance +
  open positions' margin + pending opens' margin and fee − queued debt, the most today's
  positions and requests can bring in (each loses at most its margin). Redemption pays out of
  `equity()`, which reserves, per side, that side's PnL plus its margin, so open losses never
  offset open winners. The first mint locks the rest of the
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
  guard, and the optimizer on (18.3 KB runtime, under the 24 KB limit).

Design, replay results and competitors: `docs/design.md` (Japanese).

## Layout
- `src/LaunchPool.sol`, `test/LaunchPool.t.sol` (36 tests, including regressions for review
  findings: `test_r1_*` to `test_r4_*`)
- `lib/hl-price-guard`: price reading and caps from HL Price Guard (`fabrknt/hl-price-guard`), as a
  submodule pinned to one commit. Policy: pin only tagged versions, and move to a newer tag on purpose
  (`git -C lib/hl-price-guard checkout vX.Y.Z`, then run the tests), never to its latest commit.
  The pin is `v0.2.1` (f18cdd4); `v0.2.0` has a `Rolling.reconfigure` bug. Changes to the library are made
  in that repo; it does not depend on Day One.
- `keeper/keeper.ts`: pokes on each oracle change, settles due requests, liquidates, reading
  through Multicall3 so a public RPC's rate limit holds (`TICK_MS`, default 1 s); with
  `MARKET_HOURS=nyse` or `krx` it pauses new positions while that exchange is closed
  (`keeper/campana.mjs` for NYSE; `keeper/krx.mjs` for xyz:SKHX and xyz:SMSN: 09:00-15:30 KST,
  the 2026 calendar with its 17 weekday closures and the CSAT shift on 11-19, and it refuses dates
  outside the calendar instead of guessing; tests in `keeper/krx.test.mjs`).
  `keeper/e2e.sh` runs it end to end on anvil with the precompiles mocked at their real addresses.
  `deploy/cohost/` runs it as a systemd service on an existing Linux host.

## Web UI
`web/`: trade, pool and positions in one page (Vite + React + viem).
- Local: `./keeper/dev.sh` (anvil, mock precompiles, pool, keeper, a moving price), then
  `cd web && npm install && npm run dev`. anvil's key 0 is the operator and keeper, key 1 the
  page's dev wallet, key 2 moves the mock price (separate keys, so they never race on a nonce).
  `echo 0.85 > /tmp/dayone-shock` replays an SK Hynix-style bad update: the page shows the pause.
- Testnet: `?net=testnet&pool=0x…&usdc=0x…` with a browser wallet. The current deployment's
  addresses are in `docs/testnet.md`.
- Phone width: under 480 px the positions table drops its id and entry columns so Close and
  Cancel stay in view, and inputs are 16 px so iOS Safari does not zoom (checked at 390 px).

## Review
Codex reviews each change that moves money, and proves each finding with a PoC test before it is
fixed (PoCs live in throwaway worktrees, not in this repo).

| Round | Verdict | Findings |
|---|---|---|
| 1 (e362390) | CHANGES | 6, all fixed in f93543b: cross-side netting in equity, first loser owning the pool, fees repriced under pending requests, opens blocking closes, rounding, unbounded keeper scan |
| 2 (f93543b) | CHANGES | share pricing reopened (first mint could skip the lock), cap raises blockable forever; fixed in 2558cd0, plus a reentrancy guard |
| 3 (2558cd0) | CHANGES | share pricing reopened again (repeated wash pairs diluted the lock); redesigned in b92ae5a: shares priced at `shareValuation()`; maintenance stored per position |
| 4 (b92ae5a) | CHANGES | round 3's three attacks closed (a five-pair wash nets −$18,644 after redeeming). New: a pending open's fee was outside the valuation, so a rebate minted before two high-fee requests settled redeemed $9,836 for a $3 loss; fixed in 58972d4 (`pendingOpens` in the valuation). Rebate starvation judged a fairness issue, not extraction |
| 5 (58972d4) | APPROVE | round 4 PoC closed (the attacker redeems $0.20 for a $3 loss); `pendingOpens` accounting checked on every path, including reverts in settle, pause and graduation; donations and rounding dust are never booked, so cannot be redeemed. No new findings |
| 6 (adbeca4) | CHANGES | keeper and host scripts, no contract change. An expired market-hours calendar aborted the whole tick (settle and liquidate too); a 60 s params cache delayed settlements; install.sh could take over another project's paths, had no rollback and trusted a shared Node. Fixed in 2dbae7c |
| 6b–6e | CHANGES | install.sh only, narrowing each round: marker written before a healthy start, no rollback on failures after the switch, the live key accepted as input, an incomplete install accepted. 6d also caught that 24269ec's message described a key handoff that was not in the code (corrected in ad079cf). Fixed in 56a22df, 24269ec, ad079cf, 6ef0210 |
| 6f–6h | CHANGES, CHANGES, APPROVE | install.sh: a linked key file could overwrite another file, an unauthenticated bundle with npm scripts as root, then a newline filename beating the checksum and a hash-then-extract race. Fixed in 7171c44 and e2ee339 (one private bundle copy, hashed and extracted; the script never deletes the upload). 6h: no HIGH left; three medium/low items recorded in docs/testnet.md |
| 7 (26e8c21) | CHANGES | the falling win haircut. The curve was stored per position but the rebate was read live, so opening both sides while a valid change (flat 30%, rebate 29.99%) waited out paramsDelay paired the old 15% floor with the new rebate (+$48.90 for the pair; the flat haircut had the same hole). Fixed in e9c7a66: the rebate is stored per position too |
| 7b (e9c7a66) | APPROVE | round 7 PoC closed (pair −$75.51); fee, maintenance, curve and rebate all used as stored on close and liquidation; the redeem buffer stays live by design |

## Not done
Moving the testnet keeper to an always-on host with `deploy/cohost/` (round 6 closed; it runs
on a local machine until then); calendars beyond 2026 and other exchanges; audit; mainnet.

`forge test` (36 tests); `npm install && ./keeper/e2e.sh` (12 checks); `node --test keeper/krx.test.mjs`.
