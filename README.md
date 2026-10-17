# Day One — Fabrknt Labs

Private. Research and a reference implementation, not a product. Not offered to traders.
It studies how to make a newly listed HIP-3 perp tradable from day one without inviting the attacks
a thin book invites: initial liquidity, price anomalies, exposure caps and stop conditions.
Part of Fabrknt for HIP-3 (fabrknt.com/hip3/labs/day-one); it moves forward only when an operator
(design partner) has a concrete need for it.

The mechanism studied: a loss-funded counterparty pool for a newly listed HIP-3 perp, run by the
market's deployer while the book is thin, and retired once it is deep enough.

- Starts empty. Traders' losses and fees fill it; each $ lost mints pool shares to the loser.
  Profits the pool cannot pay yet wait in a FIFO queue (the Papertrade model).
- Settles two-step at HL's oracle, read through hl-price-guard's `HLPriceGuard` (bounds, an
  independent reference, a jump latch). Any breach makes settlement and liquidation wait.
- Caps notional settled per minute and net open interest. On replay of Papertrade's 10-10
  incident, the per-minute cap is what made the push unprofitable; choosing the oracle over the
  BBO cut it only 15%.
- Pauses new positions out of trading hours; `graduate()` stops new positions for good.

Design, replay results and competitors: `docs/design.md` (Japanese).

## Layout
- `src/LaunchPool.sol`, `test/LaunchPool.t.sol`
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

## Not done
Testnet deployment (prepared: docs/testnet.md, needs a funded key with big blocks on), market-hours calendars other than NYSE (KRX for xyz:SKHX and xyz:SMSN), audit.

`forge test` (17 tests); `npm install && ./keeper/e2e.sh`.
