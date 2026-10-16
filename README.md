# Primer (working name)

Private. A loss-funded counterparty pool for a newly listed HIP-3 perp, run by the market's
deployer while the book is thin, and retired once it is deep enough.

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

## Not done
Share redemption (needs what the pool owes open positions first), keeper (`poke`, `settle`,
`liquidate`), testnet deployment, audit.

`forge test` (precompiles are mocked at their real addresses).
