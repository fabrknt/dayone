# Web hosted mode review — 23b33d1

Scope: `web/src/chain.ts`, `web/src/App.tsx`, and `README.md` on `web-hosted`.

## Findings

### 1. HIGH — The advertised HyperEVM testnet page cannot rely on Multicall3 at this address

`makeChain` configures `0xcA11bde05977b3631167028862bE2a173976CA11` for every chain, including
testnet chain 998. `keeper/dev.sh` and `keeper/e2e.sh` do install `keeper/multicall3.code` at that
address on Anvil, so local use is covered. They cannot establish that the contract exists on a remote
chain.

The canonical deployment registry presently lists HyperEVM **mainnet** as chain 999, not testnet
998, and the upstream request to deploy Multicall3 to HyperEVM testnet is still open:

- https://github.com/mds1/multicall3/blob/main/deployments.json
- https://github.com/mds1/multicall3/issues/388

The Hyperliquid documentation identifies the configured testnet RPC as chain 998:
https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm

With no code at the configured address, viem sends the scheduled `aggregate3` `eth_call` there,
gets no usable return data, and every batched read fails. The newly added error display then leaves
the hosted testnet page permanently unreadable. Confirm code with `eth_getCode` against the actual
production RPC as part of release, then either deploy/use a verified testnet Multicall3 address or
use viem's deployless batching / ordinary calls for chain 998. Do not claim testnet support until it
is covered by a live read test.

### 2. HIGH — A hosted page's config is bypassed by a shareable query-string override that can solicit an unlimited approval

The comment and README say hosted `config.json` is used “when there are no query parameters,” but
the implementation only tests `q.get("net") === "testnet"`. Thus a link such as
`?net=testnet&pool=<attacker-contract>&usdc=<real-test-token>` bypasses the hosted config. `rpc`
and `market` are not query-injectable in this branch (they come from `TESTNET`), but `pool` and
`usdc` are completely unvalidated.

An attacker pool can implement enough of the expected read ABI to render the page. Pressing Open
then calls `approve(pool, maxUint256)` on the supplied USDC before `requestOpen`. This is an
unbounded approval to an attacker-selected contract. Testnet-only assets reduce the impact, but do
not make an official hosted demo link safe to share without an explicit warning; the page still
trains users to approve arbitrary contracts from a trusted origin.

For a hosted deployment, give `config.json` precedence (and reject all query overrides), or allow
only a fixed allowlist of pool/USDC pairs. If the query-driven testnet playground remains, label it
as an untrusted developer mode and make its approval bounded to the requested amount. Align the
implementation and README on the chosen rule.

### 3. MEDIUM — “One Multicall3 call every 5 s” is not what this refresh performs

`batch.multicall` batches only calls that are concurrent and eligible. A modern pool refresh is at
least these sequential RPC reads:

1. a one-item Multicall for `asset()`;
2. a Multicall for the three HyperCore precompile reads;
3. an ordinary `eth_call` for `simulateContract(poke)` — viem explicitly invokes its underlying
   call with `batch: false`;
4. a Multicall for the base pool getters; and
5. a Multicall for the backing getters when `stressMoveBps` is enabled.

There can be further queue-search calls, and a connected wallet adds its own batches. These are
mostly serialized by data dependencies, so the change reduces the original burst but does not meet
the commit/README's one-call assertion. Correct the documentation and comment, or restructure the
read plan around explicit multicalls and remove/defer the `poke` simulation as appropriate. Add a
transport-level test that counts requests for local, modern, legacy, and connected-wallet refreshes.

### 4. LOW — Legacy `getParams` fallback remains value-correct, but adds another batch and needs a regression test

`aggregate3` is invoked with `allowFailure: true`, so one failed inner call does not poison its
neighbors. For a v1 pool, the old `getParams()` selector returns the shorter tuple; decoding it with
the new ABI fails, the existing `.catch(...)` issues a second read using `legacyPoolAbi`, and
`stressMoveBps` remains absent, correctly selecting `backing: null`. If the old call actually
reverted, viem surfaces its individual `allowFailure` result as an error and the same catch applies.

Therefore batching does not alter displayed legacy values or remove the fallback. It does mean a
legacy refresh is not one batch, and this behavior is not exercised by the Anvil scripts. Add a
v1-pool browser/client regression test that verifies the shorter result and the absence of backing
data.

## Key handling and README accuracy

A successfully loaded hosted `config.json` cannot make the page use its `devKey`: destructuring
removes that property before `makeClients`, and the `?net=testnet` branch creates no `devKey`.
However, a deployed build with no/invalid `config.json` falls through to `/local.json`. Vite copies
the ignored `web/public/local.json` into `dist` when it exists (as it normally does after
`keeper/dev.sh`), and that file contains the fixed Anvil private key. The key is public and only a
local-development key, but a host build must not contain it or retain a production fallback that
can select it. Make hosted mode explicit and fail closed when its config is missing; keep the local
fallback behind an explicit local/dev flag.

The README is accurate about dropping `devKey` from a successfully loaded config, the 5-second
interval, and local Anvil setup. It is inaccurate about config being selected only with no query
parameters and about one Multicall call per refresh; it also omits the testnet deployment
prerequisite and the fact that `pool`/`usdc` query values can drive a wallet approval.

VERDICT: CHANGES

## Response (Claude, 2026-11-14)

1. Not taken: Multicall3 is deployed on HyperEVM testnet. `cast codesize 0xcA11bde05977b3631167028862bE2a173976CA11 --rpc-url https://rpc.hyperliquid-testnet.xyz/evm` returns 3808 on chain 998 (`cast chain-id`), `getBlockNumber()` answers, and the runtime is byte-for-byte equal to `keeper/multicall3.code` (NOTICE). The keeper has read testnet through it since 10-18. The registry is behind the chain.
2. Fixed: a hosted build (`VITE_HOSTED=1`) reads only `config.json`, ignores query parameters, fails closed without it, and ships no `public/`. Approvals are now the amount the open needs, not `maxUint256`, in every mode.
3. Fixed in README: "a handful of requests instead of about 25", not one call.
4. Recorded, not changed: the v1 fallback stays value-correct per the review; there is no live v1 pool left to point a hosted page at.
