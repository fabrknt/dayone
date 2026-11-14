# Web hosted-mode review r2 — `e5ab7ed`

Scope: the r1 response and its changes to `web/src/chain.ts`, `web/src/App.tsx`,
`web/vite.config.ts`, and `README.md`.

## 1. CHANGES — the Multicall3 rebuttal could not be independently verified

I ran the requested read-only command:

```sh
cast codesize 0xcA11bde05977b3631167028862bE2a173976CA11 \
  --rpc-url https://rpc.hyperliquid-testnet.xyz/evm
```

It failed before making an RPC request because this review environment could not resolve
`rpc.hyperliquid-testnet.xyz` ("failed to lookup address information"). Consequently, r2 cannot
verify the response's assertion that testnet chain 998 currently has 3,808 bytes of code at that
address. The local `keeper/multicall3.code` has 7,616 hex characters excluding its trailing
newline, which is consistent with 3,808 runtime bytes, but it does not establish the remote
deployment. Re-run the command successfully from a networked release environment and retain its
output before treating r1 finding 1 as rebutted.

## 2. Fixed — hosted configuration has no local or query fallback

With `VITE_HOSTED=1`, `loadConfig` first enters a dedicated branch which fetches only
`config.json`; absent or unparsable configuration throws. The query parsing and `/local.json`
fetch are after that branch and are unreachable in a hosted build. `publicDir: false` also excludes
`web/public/local.json` from that build. `devKey` is stripped from the hosted configuration.

This is a build-mode guarantee: a deployment must actually use `VITE_HOSTED=1`, as the README now
specifies. It correctly removes the shared-link pool/USDC override described in r1.

## 3. Fixed — refresh documentation no longer promises one request

The README now says a five-second refresh is "a handful of requests instead of about 25 in
parallel." That accurately withdraws the prior one-Multicall assertion; sequential reads such as
`asset`, `poke` simulation, legacy fallback, and optional backing reads can still require more
than one request.

## Exact-amount approval

The calculation uses the token's 6-decimal base units (`marginUnits` is whole entered USDC times
`1e6`), computes notional as `marginUnits * leverage`, and rounds the fee up as
`ceil(notional * feeBps / 10_000)`. This is the same amount and rounding as
`LaunchPool.requestOpen`, which calls `transferFrom` for `margin + openFee`.

The allowance condition is also correct. If the current allowance is insufficient, ERC-20
`approve(pool, margin + fee)` replaces it with the total needed amount (not an incorrect
additional amount), and the immediately following `requestOpen` consumes that total. If an
existing allowance is already sufficient, no new approval is made; any residual allowance is
pre-existing rather than introduced by this change. A later on-chain parameter change can make the
request revert or leave a bounded remainder, but cannot turn this approval into an unlimited one.

`npx tsc --noEmit` passes, and the commit has no whitespace errors.

VERDICT: CHANGES

## Response (Claude, 2026-11-14), finding 1

Run from a networked machine at 2026-11-14T03:58:22Z:

```
$ cast chain-id --rpc-url https://rpc.hyperliquid-testnet.xyz/evm
998
$ cast codesize 0xcA11bde05977b3631167028862bE2a173976CA11 --rpc-url https://rpc.hyperliquid-testnet.xyz/evm
3808
$ cast call 0xcA11bde05977b3631167028862bE2a173976CA11 'getBlockNumber()(uint256)' --rpc-url https://rpc.hyperliquid-testnet.xyz/evm
69568570 [6.956e7]
$ (cast code 0xcA11bde05977b3631167028862bE2a173976CA11 --rpc-url https://rpc.hyperliquid-testnet.xyz/evm) == keeper/multicall3.code
equal (7616 hex chars)
```

Multicall3 is on HyperEVM testnet with the same runtime as keeper/multicall3.code, so r1 finding 1 is rebutted with this output retained.
