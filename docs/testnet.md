# Deploying to HyperEVM testnet

Checked 2026-10-17. Chain 998, RPC `https://rpc.hyperliquid-testnet.xyz/evm`.

## Current deployment (2026-11-19: the 11-14 pool plus a testnet reference price)
- Pool `0x4B0d8AB73b2511EbDF9eBE474cf0C5a2a77AD8cD`, mock USDC `0x37e6a38d3237ed78E408B56D00693fA47Db9518E`,
  reference `0x97e0178aE6F918c9063506a9AF76934a131B9938` (`ReporterRef`, `maxAge` 180 s), xyz:TSLA, the
  testnet defaults below with `maxRefOracleBps` 150, seeded with 10,000 mock USDC. Deployed with
  `PAUSER=$KEEPER REPORTER=$KEEPER` (step 3).
  Operator `0xf3DD600Ddf6C1542Db845b3F65F603b5f011c5f9` (a key used only for Day One testnet). Pauser,
  reporter and keeper `0xD0B64bc5D46E903f2228cc861006Ed4A92BbF547` (its own key): it can set and clear
  the trading-hours pause and push the reference, and nothing else, and it sends from a different
  address than the operator, so it does not share nonces with anything the operator key still runs.
- Page: `?net=testnet&pool=0x4B0d8AB73b2511EbDF9eBE474cf0C5a2a77AD8cD&usdc=0x37e6a38d3237ed78E408B56D00693fA47Db9518E`.
- Why: on the 11-14 pool (below) the testnet oracle stopped at 380.96 from 11-14 while HL mainnet's
  xyz:TSLA oracle moved on (391.26 on 11-19, 264 bp away), and with no reference the guard could not
  tell. The keeper (`REF_COIN=xyz:TSLA`) now pushes HL mainnet's oracle for the same market every
  minute, so a testnet oracle more than 1.5% from it makes every settlement wait
  (`Breach RefOracle`), and a keeper that stops pushing makes them wait too (`Breach RefStale`).
- First run (2026-11-19): the keeper pushed its first reference (391.21) 14 s after starting and
  paused opens for NYSE hours; at the open (14:30 UTC) it lifted the pause and a $200 long (20 USDC at
  10x, from the operator key) was requested as position 1. It has not settled: the book had bids only
  (495.43 best, no ask), so the guard stops at `EmptyBook` before it reaches the reference
  (`settle(1)` reverts `Breach(EmptyBook, 0, 0)`), and the keeper sends nothing on an empty book. With an
  ask back and the oracle still at 380.96 against a reference of 391.55, it would stop at
  `RefOracle` (about 270 bp over 150), as it did on anvil with the same prices.
- The reference is testnet only and only as good as its reporter: the keeper's key can hold every
  settlement or let a wrong oracle through inside the bound (`src/testnet/ReporterRef.sol`). It is
  not an independent signed price. On mainnet use one (`PythRef`; its update data needs a Hermes API
  key). HL mainnet's oracle is posted by the same deployer as its book, so for a mainnet pool it would
  not be independent either; here it only stands in for the price the testnet deployer stopped posting.
- The operator was funded from the founder's earlier deployer address, so the pool links to it on
  chain; the founder accepted that on 2026-11-07. Its HyperCore account was created by sending
  0.05 HYPE from the EVM to `0x2222…2222` (activation took about 0.024 HYPE); big blocks can only be
  turned on after.

## Earlier deployments
- `0x9C1F3e7af3781CA4a7AB8b5E0f4BE81d8063ba25` (2026-11-14, master 611e92e, mock USDC `0x86b1…1546`): the
  current pool without a reference. Retired on 2026-11-19, when the keeper on the always-on host moved
  to the current pool; nothing drives it now. Position 1 (the $200 long below) is still open there,
  owned by `0xa032…aa09`; opens were last paused for NYSE hours.
  First run (2026-11-14, a Friday evening in New York): a $200 long (20 USDC at 10x) was requested
  as position 1, and the keeper refused to settle it: `Breach Spread: 3215 over 100`. The testnet
  book had a 378.38 bid and a single 500 ask (oracle 380.96), a 28% spread against the 1% bound. That
  is the guard doing its job on a broken book; the keeper keeps trying and settles when the spread
  comes back under the bound. It did: the keeper settled position 1 on 2026-11-16 at 17:02:40 UTC
  (a Monday, in NYSE hours) at 380.96 (`Opened(1, 380.96)`, tx `0x64b1…27e8`). As of 2026-11-19 the
  testnet oracle has not moved from 380.96 since 11-14 while the book trades near 495, and the guard
  did not notice: that pool has no reference and no mark/mid bound.
- `0x183AA811bFc913fCf5630cbAA4B85b3a8499a707` (2026-10-18, mock USDC `0x19B4…d1C4`): before the
  backing check, `seed`, the pauser role and `claim()` (keeper `POOL_ABI=v1`). Retired on
  2026-11-14: its keeper on the always-on host was replaced by the current pool's, so nothing drives
  it now (opens were last paused for NYSE hours; no positions were open).
- Abandoned (test positions closed, about $0.20 of mock-USDC fees left in each): `0x7103…d6D6`
  (curve, previous key) and `0x372E…9040` (flat haircut).
- First run on the 10-17/10-18 pools: `poke` with the real precompiles, then a $200 long requested and settled by the
  keeper at 373.42, the same oracle the HL API reported. On the 10-18 pool the position stores the
  curve (30% -> 15%, 0.25% -> 1%) and the 12% rebate; `haircutAt` at a 1.76% move gives 15%.
- Gas: on the 10-18 pool viem's exact estimate ran a settle out of gas (285,766 of 285,766) and the
  keeper logged it as ok. The keeper now adds 30% to the estimate and treats only a receipt with
  status success as done (anything else is logged REVERTED). The keeper runs with
  `MARKET_HOURS=nyse` and paused new positions on Saturday as intended.
- Its page: `?net=testnet&pool=0x183AA811bFc913fCf5630cbAA4B85b3a8499a707&usdc=0x19B461A53e2A64205668a5FeFF5f0Fa6B428d1C4`.
- Keeper host: an existing always-on host (since 2026-11-19 it runs the current pool with the keeper
  key and `REF_COIN=xyz:TSLA`; 11-14 to 11-19 the 11-14 pool; before that the 10-18 pool with the operator key), as its own systemd
  service (`deploy/cohost/`: `bundle.sh` builds the code bundle, no key; `install.sh` installs it
  as `dayone-keeper`: its own user, `/opt/dayone-keeper` (root-owned releases and a
  checksum-verified Node), the key in `/etc/dayone-keeper` readable only by that user, one unit
  capped at 200 MB and a quarter of a CPU).
  - It refuses to run over anything it did not make (dangling symlinks count), and refuses a
    committed install that is incomplete or altered.
  - The marker is written only after the first install's service stays up for 15 s; a failed first
    install removes exactly what it created.
  - An upgrade stages a release, then switches key, release link and unit; any failure from there,
    or a service that does not stay up, restores all three and restarts the previous one.
  - Runs are serialised with a lock. Holding it, the key is read into a 0600 copy in `/run`
    (removed on every exit) and must be 64 hex characters. The script never deletes the upload:
    remove it yourself, as the user who uploaded it. The installed key itself is refused as input.
  - Checked in an Amazon Linux 2023 arm64 container with systemd: 16 scenarios in
    `deploy/cohost/scenarios.sh` (container only; it fakes failures).
  - The bundle is read once into a private copy, which must match the SHA-256 bundle.sh printed
    and is the copy extracted; npm runs with `--ignore-scripts`.
  Run, from a machine with SSH to the host (upload into a directory only the uploader can open):
  ```
  ./deploy/cohost/bundle.sh                                   # prints the SHA-256
  ssh HOST 'install -d -m 700 ~/dayone-upload'
  scp dist/dayone-keeper.tgz deploy/cohost/install.sh KEYFILE HOST:dayone-upload/
  ssh HOST 'cd ~/dayone-upload && sudo bash install.sh dayone-keeper.tgz SHA256 KEYFILE; shred -u KEYFILE'
  ```
  Upgrades: the same without KEYFILE.
  - Reviewed by Codex in rounds 6 to 6h (APPROVE at 6h, no HIGH left for a single-tenant host).
    Recorded, not fixed: the key is read by pathname, so someone who controls the upload path could
    substitute another valid key (hence the private upload directory); `shred` is best effort on
    some storage, so use a key that holds nothing of value; the scenarios do not cover the
    substituted-key case.
- Rate limit: the public testnet RPC rejected about one tick in six ("Request exceeds defined
  limit") when the keeper made 7 reads a tick. It now reads through Multicall3 (1 call a tick, 2
  with positions) and the hosted keeper ticks every 2 s (`TICK_MS`): no failures in 90 s.

## Market
Default: testnet xyz:TSLA. xyz is dex 65 on testnet (dex 1 on mainnet), so:
- `0x806` / `0x807` / `0x80a` take `650001`
- `0x80e` takes `750001`

On 10-17 its oracle was 352.31, its mark 373.63 and its BBO mid about 373.87, 612 bp above the
oracle. `DeployTestnet` therefore turns off the mark/mid bounds; the jump latch, two-step
settlement and both caps stay on. Other markets: `DEX=… INDEX=… SZ_DECIMALS=…`.

## Steps (the key holder runs 1, 2 and 3)
Needs, besides the Quick start's tools, [uv](https://docs.astral.sh/uv/) for step 2. Keep each key in
a file only you can read (64 hex characters, with or without `0x`):

    export RPC=https://rpc.hyperliquid-testnet.xyz/evm
    export KEY_FILE=~/.dayone-operator.key        # the operator (deployer) key
    export KEEPER_KEY_FILE=~/.dayone-keeper.key   # the keeper's key, which is also the pauser
    export KEY=$(cat $KEY_FILE) PAUSER=$(cast wallet address --private-key $(cat $KEEPER_KEY_FILE))

1. Both keys need testnet HYPE on HyperEVM for gas (send from HyperCore testnet spot to the EVM, or
   a faucet); the operator's address also needs a HyperCore account for step 2 (send it a little
   HYPE from the EVM to `0x2222…2222`, as above). About 5.1M gas in all (forge's estimate for
   `DeployTestnet`, 10-20) at 0.2 gwei; 0.03 HYPE is plenty for the keeper.
2. Turn on big blocks for that address. LaunchPool's initcode is 24.6 KB with the optimizer (22.0 KB
   runtime), over the 2M small-block limit. This is a HyperCore action signed by the same key:
   `{"type": "evmUserModify", "usingBigBlocks": true}` (hyperliquid-python-sdk:
   `Exchange.use_big_blocks(True)`), or with the script here, which skips the SDK's metadata load
   because the SDK fails to parse testnet's spot list and reads the key from `KEY_FILE`:

       uv run --with hyperliquid-python-sdk python -I script/big_blocks.py on

   Turn it off after deploying (the same command with `off`): while on, every EVM transaction from
   the address waits for a big block, about one a minute.
3. `forge script script/DeployTestnet.s.sol --rpc-url $RPC --broadcast --legacy --slow --private-key $KEY`
   (`PAUSER` from the exports makes the keeper's key the pauser; `REPORTER=$PAUSER` also gives the
   pool a `ReporterRef` that key writes, `maxRefOracleBps` `REF_BPS` (150); `SEED` changes the seed). It prints the mock USDC and pool addresses. Testnet defaults: `paramsDelay` 1 day, minimum
   position $100, per-lane cap $30K per 60 s (xyz:TSLA's mainnet safe cap), net OI $100K,
   `stressMoveBps` 10%, and a seed of `SEED` mock USDC (default 10,000, minted to the deployer and
   paid in for shares), which backs about $100K of longs and, separately, $100K of shorts
   (each side gross). How to choose these for another market: `docs/sizing.md`.
4. Mint mock USDC to a trader (`cast send --legacy $USDC "mint(address,uint256)" …`; without
   `--legacy`, cast's fee estimate fails on this RPC with "invalid block range"), approve the pool, and
   run the keeper with its own key: `RPC_URL=$RPC POOL=$POOL PRIVATE_KEY=$(cat $KEEPER_KEY_FILE) MARKET_HOURS=nyse node keeper/keeper.ts`
   (add `REF_COIN=xyz:TSLA` for a pool deployed with `REPORTER`: the keeper then pushes HL mainnet's
   oracle for that market to the reference every minute).
   Only for the 10-18 pool (0x183A…, deployed before the pauser role and `claim()`): add
   `POOL_ABI=v1`, and the keeper then uses `setOpensPaused` with the operator key, and settle pays
   queued winners itself. `deploy/cohost/bundle.sh` writes `POOL_ABI` into `keeper.env`.
   `MARKET_HOURS=nyse` pauses new positions while NYSE is closed; use `krx` for xyz:SKHX or xyz:SMSN.
   That needs the pool's pauser key (`PAUSER=<keeper address>` at step 3, or later
   `cast send $POOL "setPauser(address)" <keeper address>` from the operator key) or the operator key.
   Give the keeper the pauser key, not the operator key: the pauser can only set and clear the
   trading-hours pause (`setHoursPaused`), never `graduate`, `proposeParams`, `rearm` or the
   operator's own pause (`setOpensPaused`), which the keeper therefore cannot undo.
5. Open the page with `?net=testnet&pool=$POOL&usdc=$USDC` and a browser wallet on chain 998.

What testnet adds over `keeper/e2e.sh`: the real precompiles and a deployer's real oracle
updates, instead of mocks.
