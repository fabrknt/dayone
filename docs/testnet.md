# Deploying to HyperEVM testnet

Checked 2026-10-17. Chain 998, RPC `https://rpc.hyperliquid-testnet.xyz/evm`.

## Current deployment (2026-10-18, dedicated key, with the haircut curve)
- Pool `0x183AA811bFc913fCf5630cbAA4B85b3a8499a707`, mock USDC `0x19B461A53e2A64205668a5FeFF5f0Fa6B428d1C4`
  (xyz:TSLA, the testnet defaults below). Deployed and operated by a key used only for Day One
  testnet (operator `0xf3DD600Ddf6C1542Db845b3F65F603b5f011c5f9`), in `the operator key file`
  (mode 600, with the `0x` prefix). Its HyperCore account was created by sending 0.05 HYPE from the
  EVM to `0x2222…2222` (activation took about 0.024 HYPE); big blocks can only be turned on after.
- Earlier pools, abandoned (test positions closed, about $0.20 of mock-USDC fees left in each):
  `0x7103…d6D6` (curve, previous key) and `0x372E…9040` (flat haircut).
- First run: `poke` with the real precompiles, then a $200 long requested and settled by the
  keeper at 373.42, the same oracle the HL API reported. On the new pool the position stores the
  curve (30% -> 15%, 0.25% -> 1%) and the 12% rebate; `haircutAt` at a 1.76% move gives 15%.
- Gas: on the new pool viem's exact estimate ran a settle out of gas (285,766 of 285,766) and the
  keeper logged it as ok. The keeper now adds 30% to the estimate and treats only a receipt with
  status success as done (anything else is logged REVERTED). The keeper runs with
  `MARKET_HOURS=nyse` and paused new positions on Saturday as intended.
- Page: `?net=testnet&pool=0x183AA811bFc913fCf5630cbAA4B85b3a8499a707&usdc=0x19B461A53e2A64205668a5FeFF5f0Fa6B428d1C4`.
- Keeper host: moving from a local machine to an existing always-on host as its own systemd
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
1. A fresh key with testnet HYPE on HyperEVM for gas (send from HyperCore testnet spot to the
   EVM, or a faucet). About 6.4M gas in all at 0.2 gwei.
2. Turn on big blocks for that address. LaunchPool's initcode is 18.5 KB with the optimizer (about
   3.7M gas), over the 2M small-block limit. This is a HyperCore action signed by the same key:
   `{"type": "evmUserModify", "usingBigBlocks": true}` (hyperliquid-python-sdk:
   `Exchange.use_big_blocks(True)`; or `script/big_blocks.py on`, which skips the SDK's metadata
   load because the SDK fails to parse testnet's spot list). Turn it off after deploying
   (`script/big_blocks.py off`): while on, every EVM transaction from the address waits for a big
   block, about one a minute.
3. `forge script script/DeployTestnet.s.sol --rpc-url https://rpc.hyperliquid-testnet.xyz/evm --broadcast --private-key $KEY`
   It prints the mock USDC and pool addresses. Testnet defaults: `paramsDelay` 1 day, minimum
   position $100, per-lane cap $30K per 60 s (xyz:TSLA's mainnet safe cap), net OI $100K.
4. Mint mock USDC to a trader (`cast send --legacy $USDC "mint(address,uint256)" …`; without
   `--legacy`, cast's fee estimate fails on this RPC with "invalid block range"), approve the pool, and
   run the keeper: `RPC_URL=https://rpc.hyperliquid-testnet.xyz/evm POOL=$POOL PRIVATE_KEY=$KEY MARKET_HOURS=nyse node keeper/keeper.ts`.
   For the current deployment (0x183A…, deployed before the pauser role and `claim()`) add
   `POOL_ABI=v1`: the keeper then uses `setOpensPaused` with the operator key, and settle pays
   queued winners itself. `deploy/cohost/bundle.sh` writes it into `keeper.env`.
   `MARKET_HOURS=nyse` pauses new positions while NYSE is closed; use `krx` for xyz:SKHX or xyz:SMSN.
   That needs the pool's pauser key (`PAUSER=<keeper address>` at step 3, or later
   `cast send $POOL "setPauser(address)" <keeper address>` from the operator key) or the operator key.
   Give the keeper the pauser key, not the operator key: the pauser can only set and clear the
   trading-hours pause (`setHoursPaused`), never `graduate`, `proposeParams`, `rearm` or the
   operator's own pause (`setOpensPaused`), which the keeper therefore cannot undo.
5. Open the page with `?net=testnet&pool=$POOL&usdc=$USDC` and a browser wallet on chain 998.

What testnet adds over `keeper/e2e.sh`: the real precompiles and a deployer's real oracle
updates, instead of mocks.
