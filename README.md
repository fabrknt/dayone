# Day One — Fabrknt Labs

**For the deployer of a newly listed HIP-3 perp:** a counterparty pool that keeps a thin book
tradable from day one, with limits aimed at the attacks a thin book invites (a push like
Papertrade's on 2026-10-10, a bad update like SK Hynix's on 2026-07-27, a paper-mint straddle),
retired once the book is deep enough. Each limit is checked against the replay or test named below,
not proven in general. The operator runs it; Fabrknt does not.

Status: an unaudited reference implementation, deployed only on HyperEVM testnet (against xyz:TSLA,
`docs/testnet.md`). Not for production funds. Not offered to traders. Part of Fabrknt for HIP-3
(fabrknt.com/hip3/labs/day-one).

| You want to | Where |
|---|---|
| See it work locally, no keys | `npm install && npm run demo` (below) |
| Choose the seed, caps and latch for your market | `docs/sizing.md` |
| Deploy a pool | `script/DeployTestnet.s.sol` (a testnet example: mock USDC, mark/mid/reference bounds off; see `docs/sizing.md` §5), `docs/testnet.md` |
| Run the keeper (settle, liquidate, claim, poke) | `keeper/keeper.ts`; always-on: `deploy/cohost/` |
| Pause outside the stock's trading hours or during a halt | `MARKET_HOURS=nyse\|krx`; `PRIMARY_HALTS=<symbol>` needs `prebell`, which is not public yet |
| End a halted or delisted market | `noteFrozen`, `proposeEnd` / `applyEnd` (below) |
| Show traders the pool | `web/` |
| Know why each rule exists | "How the pool works" below and the Review table |

## Quick start
Needs Foundry, Node 24, Python 3 and zsh (the scripts are zsh; macOS has it, on Debian/Ubuntu `apt install zsh`).

    git clone --recurse-submodules https://github.com/fabrknt/dayone && cd dayone
    npm install
    npm run demo

`npm run demo` (`keeper/e2e.sh`) starts anvil, puts mock precompiles at their real addresses,
deploys a seeded pool and runs the keeper through opens, settles, liquidation, the jump latch,
trading hours, a halted market and an operator end, checking each step; it ends with `all ok` (about 10 minutes).
`prebell` (Nasdaq halts) is not public yet and is not in `package.json`, so the demo skips that
step and says so; `REQUIRE_PREBELL=1 npm run demo` fails instead of skipping. With access to it,
`npm install --no-save github:fabrknt/prebell` turns the step (and `PRIMARY_HALTS`) on.
Price reading and caps come from [hl-price-guard](https://github.com/fabrknt/hl-price-guard),
pinned by tag.

## How the pool works
The mechanism studied: a loss-funded counterparty pool for a newly listed HIP-3 perp, run by the
market's deployer while the book is thin, and retired once it is deep enough.

- **Backed by the operator's seed, grown by losses.** The operator seeds the pool (`seed`, operator
  only, for shares at the pre-seed `shareValuation()`); traders' losses and fees add to it. A new
  position settles only if, after a `stressMoveBps` move either way (10% on testnet), the pool
  could still pay every winner from its balance, and nothing opens while any winner is queued.
  The bound (`profitBound`) never lets a loser offset a winner: every long counts as entered at
  the lowest open long entry, every short at the highest short entry (exact after an open; after
  a close it stays put until anyone calls `refreshEntryBounds`). So the future losers paying
  today's winners is limited to moves past the stress size, and opens stop the moment it
  happens. With entries near the current price a seed backs about seed / stress of one-sided
  notional ($10,000 backs about $100,000 at 10%); old entries far from the price use up more.
  The stress move is at least `MIN_STRESS_BPS` (5%); 0 turns it off only on a local chain.
  `equity()` subtracts the larger of this bound and its own, so redemption is covered too.
  Profits the pool cannot pay yet wait in a FIFO queue, paid from later losses or a new seed. Paying the queue costs the
  same gas however long it is: income moves a cumulative counter, and `claim(id)` (anyone may
  call it; the keeper does) sends each winner what the queue has paid them.
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
  valuation in shares the contract holds, so no early holder owns the pool. Papertrade's
  "paper-mint straddle" (close only the winning side to push the pool insolvent, then mint at a flat
  rate on the losing side) replayed here: booking the win first can hand the loser up to 99% of the
  shares, but priced net of the queue they stay worth only the rebate once the operator seeds again
  (`test_straddleRebateWorthOnlyTheRebate`, fuzzed over the end price).
- **Settlement.** Two-step: request, then anyone settles after `settleDelay` at HL's oracle read
  through hl-price-guard's `HLPriceGuard` (bounds, an independent reference, a jump latch). Any
  breach makes settlement and liquidation wait. Liquidation stays behind the guard on purpose:
  the pool is every trade's only counterparty and a loser loses at most its margin, so a waiting
  liquidation owes nobody anything; the pool only misses income, and a loser escapes if the
  price comes back first. An unguarded liquidation price would let whoever moves the operator's
  oracle and the pushable mark liquidate traders at a false price
  (`test_liquidationWaitingOnLatchOwesNothing`). Funding, if added, must accrue by time, not per
  call.
- **A halted or delisted market.** Its book reads (0, 0) and the guard refuses every read, which
  would hold every position forever (para:PAPER was halted and settled on 2026-10-20; on mainnet
  its oracle and mark then sat at the settle price with an empty book). Two ways out. Once
  `noteFrozen()` has seen the book empty and the oracle unchanged for `FROZEN_DELAY` (1 hour),
  with sightings no more than `FROZEN_GAP` (2 minutes) apart (the contract cannot see the book
  between calls; the keeper notes every minute), closes, liquidations and redemptions settle at that oracle, still checked against the
  reference and the jump latch, until the book returns; opens stay refused. And the operator
  can `proposeEnd(price)`: opens stop at once, and `paramsDelay` later `applyEnd()` (anyone, only
  while the book is still empty, the oracle sits at the proposed price, as Hyperliquid settles a
  halted market at its oracle, and the reference agrees) ends the pool, after which anyone
  settles every open position at that price.
- **Caps.** Opens and closes each have a rolling notional cap (`ExposureBudget.Rolling`), so opens
  cannot use up the budget due closes need; net open interest is capped too. In our replay of
  Papertrade's 10-10 incident (an estimate from its public trades, not a bound), the per-minute cap
  is what brought the take below the cost of the push; choosing the oracle over the BBO cut it only 15%.
- **Operator limits.** Parameter, bounds and reference changes take effect `paramsDelay` after
  they are proposed; raising the cap or changing its window also needs opens paused. Each
  position keeps the fee, haircut and maintenance it was opened with. `rearm` (after a real gap
  trips the latch), pausing opens and `graduate()` are immediate; ending the pool waits `paramsDelay`. The keeper holds a separate
  pauser key that can only set and clear the trading-hours pause (`setHoursPaused`); the
  operator's own pause (`setOpensPaused`) is a different flag the keeper cannot clear.
- **Hygiene.** A minimum position size, an on-chain list of active ids for keepers, a reentrancy
  guard, and the optimizer on (23.5 KB runtime, under the 24 KB limit: 550 bytes left).

When to retire the pool (graduation criteria, a deadline, stop conditions) is still a draft, to be
settled with an operator; it is not published here.

## Layout
- `src/LaunchPool.sol`, `test/LaunchPool.t.sol` (65 tests, including regressions for review
  findings: `test_r1_*` to `test_r12_*`, and for round 13 `test_frozenClockRestartsAfterAGapInSightings`;
  the halted-market tests are `test_halted*`, `test_frozen*` and `test_operatorEnd*`), `test/Invariant.t.sol` (5 invariants over random sequences
  of every action, parameter changes, latch trips, rearms and seeds; after each step: tokens == books, the debt queue's
  counters and order, per-side totals == positions, shares add up, equity <= shareValuation).
  `forge coverage --ir-minimum` on `LaunchPool.sol` (10-21): lines 98.5%, branches 89.9% (91.8% on 10-20,
  before the halted-market branches).
- `lib/hl-price-guard`: price reading and caps from HL Price Guard (`fabrknt/hl-price-guard`), as a
  submodule pinned to one commit. Policy: pin only tagged versions, and move to a newer tag on purpose
  (`git -C lib/hl-price-guard checkout vX.Y.Z`, then run the tests), never to its latest commit.
  The pin is `v0.4.1` (edbee7e; moved from `v0.3.0` on 2026-11-14 with no contract change: `forge test` 70 passed, `npm run demo` all ok); `v0.2.0` has a `Rolling.reconfigure` bug. Changes to the library are made
  in that repo; it does not depend on Day One.
- `prebell` (`fabrknt/prebell`, not public yet, an optional dependency in `package.json` pinned to a commit
  from GitHub; the keeper and `npm run demo` run without it): the keeper's
  `PRIMARY_HALTS` reads the primary listing's halt state through `prebell/guard`
  (`parseNasdaqFeed`, `marketStateFor` under prebell's `us-hip3-perp` scenario). Move the pin on
  purpose, then run `keeper/e2e.sh`.
- `keeper/keeper.ts`: liquidates first, then settles due closes before due opens (at most
  `OPENS_PER_TICK`, default 5, in ticket order: a ticket when first seen, a fresh one after each try; an open the backing check refuses is
  retried after a jittered backoff of 1 to 64 ticks, sooner once a close or liquidation frees
  room; `refreshEntryBounds` at most every 100 ticks), then sends up to 3 `claim`s
  (the scan rotates, so one winner whose transfer keeps reverting holds up nobody), then pokes when the oracle has
  drifted a quarter of `maxJumpBps` from the latch's anchor. One batched read a tick through
  Multicall3 and one budget for every RPC request (`RPC_PER_MIN`, default 90; the public RPC
  allows 100), gas limits padded 30% under the 2M small-block cap (`TICK_MS`, default 1 s); with
  `MARKET_HOURS=nyse` or `krx` it pauses new positions while that exchange is closed
  (`keeper/campana.mjs` for NYSE, 2026 and 2027; `keeper/krx.mjs` for xyz:SKHX and xyz:SMSN: 09:00-15:30 KST,
  the 2026 calendar with its 17 weekday closures and the CSAT shift on 11-19, and it refuses dates
  outside the calendar instead of guessing; tests in `keeper/krx.test.mjs`). With
  `PRIMARY_HALTS=TSLA` (nyse only) it also pauses them while Nasdaq's halts feed shows the stock
  halted (a LULD pause, news, a market-wide circuit breaker) or the feed is unreadable, stale
  (over 5 minutes old at chain time, or dated over 30 s ahead of it): the deployer's oracle has no listed
  price to follow then either. The feed is read at most every 30 s (`keeper/e2e.sh` step 5b).
  While opens should be paused (calendar or halt) the keeper settles none itself, even if its pause
  transaction failed. `PRIMARY_HALTS` needs a pool with a pauser role: on a `POOL_ABI=v1` pool the one
  pause flag is also the operator's, and a clear feed could lift it, so the keeper refuses that.
  On an empty book (what the guard refuses: no oracle, no bid, or ask at or under bid) it sends nothing
  that would revert; on a halted one, (0, 0), it calls `noteFrozen()` once a minute, and again during a long
  run of exits so the sighting never goes older than `FROZEN_GAP`, settles exits once the frozen hour is
  up, and clears the clock as soon as the book is anything else. Once the pool is ended it settles every
  open position at the end price.
  `POOL_ABI=v1` for a pool deployed before the pauser role, `claim()` and the backing check
  (testnet 0x183A…), `POOL_ABI=v2` for one deployed after them but before the halted-market exits,
  set explicitly rather than guessed from a failed call.
  `keeper/e2e.sh` runs it end to end on anvil with the precompiles mocked at their real addresses,
  including a halt (the hour held, then settled at the frozen oracle), an operator end, a `POOL_ABI=v2`
  tick and a one-sided book clearing the clock.
  `deploy/cohost/` runs it as a systemd service on an existing Linux host.

## Web UI
`web/`: trade, pool and positions in one page (Vite + React + viem). The pool panel shows what
is payable now (the balance), what is owed to queued winners and how long the oldest has waited
(`Debt.at`), the room left for new longs and shorts under the backing check, and a notice when
the queue has stopped new positions; your queued winnings are listed with a Receive button
(`claim`), in case the keeper is not sending them.
- Local: `./keeper/dev.sh` (anvil, mock precompiles, pool with the backing check at 10% and a
  10,000 seed, `SEED=` to change it, keeper, a moving price), then
  `cd web && npm install && npm run dev`. anvil's key 0 is the operator and keeper, key 1 the
  page's dev wallet, key 2 moves the mock price (separate keys, so they never race on a nonce).
  `echo 0.85 > /tmp/dayone-shock` replays an SK Hynix-style bad update: the page shows the pause.
- Testnet: `?net=testnet&pool=0x…&usdc=0x…` with a browser wallet. The current deployment's
  addresses are in `docs/testnet.md`.
- Hosted: `VITE_HOSTED=1 npx vite build --base ./` and put a `config.json` (`rpc`, `chainId`, `pool`,
  `usdc`, `market`) next to `index.html`. A hosted build reads only that file: query parameters are
  ignored (a shared link cannot point it at another pool), any `devKey` is dropped, it shows nothing
  without the file, and it ships no `public/` (whose `local.json` holds the anvil dev key). Reading
  needs no wallet; trading still does, and approves only the amount each open needs.
- Reads go through Multicall3 at its canonical address (on HyperEVM testnet, and put there on anvil
  by `dev.sh` and `e2e.sh`): a refresh every 5 s is a handful of requests instead of about 25 in
  parallel, which the public testnet RPC rejects. A failed read is shown on the page.
- Phone width: under 480 px the positions table drops its id and entry columns so Close and
  Cancel stay in view, and inputs are 16 px so iOS Safari does not zoom (checked at 390 px).

## Review
Each change that moves money gets an internal review by Codex (not an audit). Each finding was
reproduced with a PoC test before it was fixed (PoCs live in throwaway worktrees, not in this repo).

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
| 8, 8b (keeper) | CHANGES | the 30% gas padding could pass the 2M small-block cap (root cause: the unbounded debt-queue loop), no budget across RPC requests, transport retries, poke before liquidate. Fixed in 5641c9b and d5d9a52; the loop itself in round 9 |
| 9 (d1208dd) | CHANGES | pauser role and the O(1) debt queue: contract checked and cleared (FIFO, no over- or under-payment, unclaimed money outside redemption and minting, a blocked winner no longer stops settles, nothing queue-length-dependent in settle, liquidate, redeem or claim). Two keeper findings: an empty RPC answer looked like an old pool and stuck; a claim that always reverts starved debts past the 50-entry scan. Fixed in 1f1e34c (`POOL_ABI=v1` explicit; rotating scan) |
| 9b, 9c (keeper) | CHANGES, CHANGES | claims only: the scan position lived in the process, so restarts every tick (then restarts at a cadence that resonated with a clock-derived start) never got past a head claim that always fails; `CLAIMS_PER_TICK=0` stopped claims. Fixed in 96bdea4 and the next commit: knobs validated, random start per process, a wrap to the front within the tick. `keeper/claims.test.mjs` runs the real `sendClaims` through those cases. Not re-reviewed: no HIGH, and `claim(id)` is open to anyone, so a stuck keeper delays a winner but cannot keep the money from them |
| 10–10c (ca11829, f4a0b89, 598a278) | CHANGES ×3 | an internal arithmetic review of every expression. Freezes only at price scales HL never uses (szDecimals above 6: PnL, haircut and equity products overflow) or after a share price driven toward zero overflowed the share count; fees, haircuts, maintenance and losses could round a base unit toward the trader. Fixed: szDecimals ≤ 6 checked at deploy, a mint that would pass `MAX_SHARES` (2^128) first divides every holding by 2^64, lazily (round 10b: skipping the rebate handed it to holders; 10c: owing it as cash made it senior and reopened washing), those four round in the pool's favor (`test_r10_arithmeticLimits`). Left as is: at most one base unit of pool-favoring dust per position, mint or redemption |
| 11–11f (9effddc … 7ca577c) | CHANGES ×5, APPROVE | the backing check and `seed`. 11: the first bound (equity's) let a long far past its margin offset another long's win, and `stressMoveBps` could be set to 0 by proposal; fixed with `profitBound` (entry extremes, no netting, also used by `equity()`) and a 5% floor off local chains. 11b: both cleared; keeper retries of unbacked opens came due together, now jittered, at most `OPENS_PER_TICK` (5) a tick, in ticket order (a ticket when first seen, a fresh one each try), and due again when a close or liquidation makes room (11c: clearing the backoff starved later opens; 11d: "never tried first" starved a retried open under arrivals; 11e: new tickets followed the reshuffled active list, now id order). Left as is: the keeper still reads every active position each tick, so a very large active set grows each read |
| 12, 12b (1ed0730, 7aaa45a) | CHANGES, APPROVE | the page: payable now, the queue and its oldest wait (`Debt.at`), backing room, queued winnings with Receive. 12: the room left out the re-pricing when a new position becomes its side's entry extreme ($100,500 shown where $23,576 fits); now computed as the contract does (`web/room.ts`, `web/room.test.mjs`, `test_r12_roomMatchesBacking`); the claims table is labelled as the newest 200 entries; queue reads are cached; a legacy pool says it has no backing check |
| 13, 13b, 13c (56fc38b, 7326bf6, 5412c35) | CHANGES, CHANGES, APPROVE | halted or delisted market. 13: a live spell between two same-oracle sightings was invisible (HIGH) → sightings at most `FROZEN_GAP` apart; `applyEnd` took any operator price without a reference → the oracle must sit at it; the keeper broke on pools from just before this change → `POOL_ABI=v2`; its empty-book test was weaker than the guard's. 13b: a long drain could outrun the gap, and a non-halted rejected book did not clear the clock (keeper). 13c: no findings |

## Not done
KRX's 2027 calendar (after its year-end closure is set in December), NYSE beyond 2027 and other exchanges; audit; mainnet; the graduation criteria's numbers, an on-chain deadline and a way to
close positions left open after graduation (to settle with an operator);
whether to cap each position's profit at notional × `stressMoveBps`, which would make the backing
exact instead of assumed, at the cost of capped wins (as [hyperevm-perp](https://github.com/psyto/hyperevm-perp) does);
the independent reference (`maxRefOracleBps` is 0 on testnet; `PythRef` needs Hermes update data,
which has required an API key since 2026-08-26); the halted-market exits on the page (it does not yet
show a frozen clock, a proposed end or an ended pool) and in `test/Invariant.t.sol` (its random
sequences do not halt the book yet); on a market with no reference, a live book shorter than
`FROZEN_GAP` between two keeper sightings that comes back to exactly the same oracle goes unseen, so
watch that the keeper is alive.

`forge test` (70 tests); `npm install && npm run demo` (36 checks with `prebell`, 32 without); `node --test keeper/krx.test.mjs`; `node keeper/claims.test.mjs`; `node web/room.test.mjs`.

## License
Apache-2.0 (`LICENSE`).
