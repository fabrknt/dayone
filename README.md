# Day One

Private. Trade every HIP-3 listing from day one: a loss-funded counterparty pool for a newly
listed HIP-3 perp, run by the market's deployer while the book is thin, and retired once it is
deep enough.

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
- `lib/hl-price-guard`: price reading and caps. Changes to it are made in that repo.

- `keeper/keeper.ts`: pokes on each oracle change, settles due requests, liquidates; with
  `MARKET_HOURS=nyse` it pauses new positions while NYSE is closed (`keeper/campana.mjs`).
  `keeper/e2e.sh` runs it end to end on anvil with the precompiles mocked at their real addresses.

## Not done
Testnet deployment (prepared: docs/testnet.md, needs a funded key with big blocks on), market-hours calendars other than NYSE (KRX for xyz:SKHX and xyz:SMSN), audit.

`forge test` (17 tests); `npm install && ./keeper/e2e.sh`.
