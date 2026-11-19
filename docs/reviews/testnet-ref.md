# Testnet reference review, rounds 1 to 5 (59f55d5 and the fix commit)

Codex, read-only. Each round's report as received; the response to each is in the next round's
request, summarised in the commit message.

## Round 1

No HIGH findings. Three MEDIUM findings and one LOW.

1. **MEDIUM — Reference rotation leaves the keeper pushing the old contract.** [keeper/keeper.ts:285](/Users/hiroyusai/src/dayone/keeper/keeper.ts:285)

   `refAt` is resolved once. If the operator replaces a lost reporter through `proposeParams` / `applyParams`, the running keeper continues successfully pushing the old reference. The new reference stays stale, blocking opens, closes, liquidations, redemptions and `applyEnd` until someone restarts or fixes the keeper. Quiet successful pushes conceal the mistake.

   **Fix:** Re-read `pool.refSource()` before each scheduled push, revalidate the reporter when it changes, and log the change. An in-memory harness using the actual `pushRef` body reproduced pushes to the old address after rotation.

2. **MEDIUM — Reference configuration failure aborts unrelated keeper work indefinitely.** [keeper/keeper.ts:287](/Users/hiroyusai/src/dayone/keeper/keeper.ts:287), [keeper/keeper.ts:309](/Users/hiroyusai/src/dayone/keeper/keeper.ts:309)

   Setting `REF_COIN` for a reference-free pool, a non-ReporterRef source, or the wrong reporter key throws before any pool reads. Every subsequent tick repeats it. This stops otherwise valid liquidations and closes on a reference-free pool, claims, hours pausing, frozen sightings, and settlements on an already-ended pool. The process remains alive while doing no useful work.

   **Fix:** Isolate reference setup/push errors from the main tick and emit a prominent configuration error. Continue independent work; contract guards already reject operations requiring a fresh reference. Add coverage for no source, wrong reporter, and incompatible source.

3. **MEDIUM — A reference push can block the entire keeper for minutes.** [keeper/keeper.ts:300](/Users/hiroyusai/src/dayone/keeper/keeper.ts:300), [keeper/keeper.ts:162](/Users/hiroyusai/src/dayone/keeper/keeper.ts:162)

   The API timeout bounds only fetching. After fetching, `pushRef` awaits simulation, estimation, transaction submission and receipt confirmation before the tick reads anything. The installed viem receipt timeout defaults to **180 seconds**. An accepted but unconfirmed push therefore stops liquidations, closes, claims and frozen sightings—even while the previous reference remains usable. A sufficiently long wait also exceeds `FROZEN_GAP`, restarting the frozen hour. Retries can repeat this stall.

   **Fix:** Track reference transactions as pending and check confirmation across ticks, with bounded work and shared-budget priority for exits. Preserve serialized nonce handling. Test a pending push and RPC failures, not just successful pushes.

4. **LOW — Documentation omits the full outage/recovery behavior and overstates “nothing settles.”** [README.md:165](/Users/hiroyusai/src/dayone/README.md:165), [docs/testnet.md:27](/Users/hiroyusai/src/dayone/docs/testnet.md:27)

   Reporter loss blocks redemption even with no positions, frozen exits, and `applyEnd`; neither rearming nor observing a frozen book bypasses staleness. Recovery requires the reporter to return or the operator to replace/remove the reference after `paramsDelay`. Conversely, already-ended positions still settle at `endPrice`, and claims and pending-open cancellations remain available. Repeated pushes also certify receipt time, so an unchanged or stale upstream oracle can remain “fresh” indefinitely.

   **Fix:** Document those restrictions, exceptions, recovery steps and source-freshness limitation explicitly.

The constructor preserves `_validate`; reference installation through `applyParams` imposed no additional source validation. Seed, share valuation and equity accounting remain unchanged. The sentinel fails closed at normal chain timestamps; reporter trust and mainnet-oracle non-independence are stated honestly. Decimal parsing and the generalized `send()` target/ABI handling showed no additional defect. Bundle defaults match the stated conditional behavior.

Existing KRX, claims and room tests passed. Solidity tests were not rerun under the read-only constraint. No files changed.

**CHANGES**
## Round 2

No HIGH findings. Three MEDIUM findings and two LOW.

1. **MEDIUM — Pending pushes break nonce serialization.** [keeper/keeper.ts:159](/Users/hiroyusai/src/dayone/keeper/keeper.ts:159)

   After a push’s 15-second receipt timeout, the same or a later tick can submit a liquidation, settlement, claim or pause transaction. The installed viem 2.57.7 requests the nonce with `blockTag: "pending"`; this account has no nonce manager. HyperEVM’s public RPC documents `eth_getTransactionCount` as supporting only the latest block, so it provides no reliable pending-nonce reservation. [Hyperliquid RPC documentation](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/json-rpc).

   **Scenario:** Push nonce N remains unmined while the previous reference is still fresh. A liquidation simulates successfully, then selects N again. Submission can fail or replace the push. On an RPC that correctly returns N+1, the liquidation instead queues behind the push, and `send()` can still block the tick for its default 180-second receipt timeout.

   **Fix:** Share explicit nonce allocation and outstanding-transaction reconciliation across all writes. Bound receipt waits for dependent pool transactions too.

2. **MEDIUM — Forgetting a pending hash does not resolve its transaction.** [keeper/keeper.ts:311](/Users/hiroyusai/src/dayone/keeper/keeper.ts:311)

   After `REF_PUSH_MS`, the keeper clears the pending transaction and immediately permits another push, without checking whether the first transaction remains queued or whether its nonce was consumed.

   **Scenario:** Mining stalls for several minutes. With pending-aware nonce responses, the keeper queues another push each minute; all can execute later, writing old sampled prices with fresh block timestamps. With latest-only nonce responses, it repeatedly collides with the unresolved nonce. Receipt RPC failures also trigger this path even when submission succeeded.

   **Fix:** Retain the hash, nonce, target and sampled price until reconciliation establishes the outcome. Recover through an explicit replacement/cancellation policy rather than treating elapsed time as transaction disappearance.

3. **MEDIUM — The slow-receipt regression check passes the original blocking behavior.** [keeper/e2e.sh:287](/Users/hiroyusai/src/dayone/keeper/e2e.sh:287)

   A keeper that simply waits for the next 30-second block still finishes below the asserted 60-second limit. The position is already settled, so the test also exercises neither a pool write behind the pending push nor pending handling across ticks.

   **Fix:** Hold mining until the tick has demonstrably continued, assert that the push remains unconfirmed, and include a due pool action while the previous reference remains fresh. Run multiple ticks beyond `REF_PUSH_MS` and verify nonce allocation and duplicate prevention. Give the test an external deadline so a hang fails reliably.

4. **LOW — The new mock API can attach the test to an unrelated listener or hang indefinitely.** [keeper/e2e.sh:253](/Users/hiroyusai/src/dayone/keeper/e2e.sh:253)

   `PORT + 52` is unchecked. If occupied, `ref-api.mjs` exits, but the readiness loop accepts any HTTP response from the existing listener. If startup fails without a listener, the loop never ends. The initial “reference push ok” loop at line 277 is also unbounded.

   **Fix:** Bind the mock to loopback on an available port, verify its identity and child-process health, and impose readiness deadlines.

5. **LOW — Documentation still misstates freshness and ended-pool behavior.** [docs/testnet.md:33](/Users/hiroyusai/src/dayone/docs/testnet.md:33), [README.md:168](/Users/hiroyusai/src/dayone/README.md:168)

   `ReporterRef.push()` records the execution block’s timestamp, not send time. A delayed transaction therefore gives an older sampled price a new freshness window. README’s “every priced action” also still includes ended-pool exits, which bypass the reference through `_exitPrice()`.

   **Fix:** Say freshness records on-chain execution time and explicitly qualify the README restriction as applying before the pool ends.

The rotation and configuration-error isolation fixes otherwise look correct. The hand-built `proposeParams` calldata matches the current static 17-field `Params` tuple and four-field bounds; concatenation is valid here. Pending receipt reads use the shared limiter, so they consume budget without bypassing `RPC_PER_MIN`.

Shell/JavaScript syntax checks and the existing KRX, claims and room tests passed. I did not run e2e or Solidity tests because they write artifacts. No files changed.

**CHANGES**
## Round 3

No HIGH findings. One MEDIUM and one LOW remain.

1. **MEDIUM — A lost broadcast response bypasses serialization.** [keeper/keeper.ts:364](/Users/hiroyusai/src/dayone/keeper/keeper.ts:364)

   **Scenario:** The node accepts the push at nonce N, but its `eth_sendRawTransaction` response times out or the connection closes. `write()` throws before returning the hash; the catch labels it “skipped” and leaves `refPending` unset. The tick immediately permits pool sends, which can reuse N on a latest-only RPC or queue behind the push on a pending-aware RPC. The receipt-timeout fix does not cover this submission ambiguity.

   **Fix:** Prepare and sign the push locally, compute its hash, and record `{hash, nonce}` before broadcasting. Preserve that state after an ambiguous submission failure and reconcile it before permitting further sends. Add a regression where the RPC accepts the transaction but loses the response.

2. **LOW — The readiness deadline cannot interrupt a hanging HTTP call.** [keeper/e2e.sh:256](/Users/hiroyusai/src/dayone/keeper/e2e.sh:256)

   **Scenario:** An existing listener on `REFPORT` accepts the connection but never responds. The initial `curl` hangs indefinitely. The readiness `curl` at line 259 has the same problem: `waitfor` counts completed attempts, so its nominal ten-second deadline cannot interrupt it. RPC-based predicates likewise can exceed their advertised deadlines.

   **Fix:** Give both curls explicit connection and total timeouts. Use a wall-clock deadline and bound each network command, or wrap step 13 in an external watchdog.

The known-hash reconciliation otherwise addresses the reported nonce and time-expiry problems. Holding sends indefinitely while nonce N remains unresolved is safe: later transactions from that account cannot execute ahead of N. A known pending transaction does not necessarily mean the whole chain stopped, but recovery then requires resolving or replacing N. Skipping liquidation reads and hours checks is acceptable under that policy; neither can produce an executable write from this account until N resolves.

The revised test exercises a due open, multiple pending ticks, drop recovery and resumed settlement. Mock binding and identity checks, reference rotation, and documentation corrections look correct.

JavaScript and shell syntax checks completed; zsh emitted sandbox `nice` warnings. E2E and Solidity tests were not run because they write artifacts. No files changed.

**CHANGES**
## Round 4

No HIGH findings. One MEDIUM remains.

1. **MEDIUM — “Not found” can release serialization immediately after an ambiguous broadcast.** [keeper/keeper.ts:325](/Users/hiroyusai/src/dayone/keeper/keeper.ts:325)

   **Scenario:** The broadcast reaches a node, but its reply is lost. On the next tick, a lagging RPC backend returns no receipt, latest nonce N, and no transaction. The keeper clears `refPending`; because `refDueMs` still lies in the future, line 340 skips the replacement push and permits pool sends at N while the original push may still execute. A single not-found response does not establish that an ambiguously submitted transaction was dropped. The new `--once` regression exits before exercising this path.

   **Fix:** Retain the signed bytes and rebroadcast that exact transaction while keeping other sends blocked until its receipt or nonce consumption resolves it. Add a multi-tick regression where the broadcast is accepted but subsequent lookups temporarily return not found.

The signing change otherwise checks out. An in-memory RPC comparison using installed viem 2.57.7 produced identical signed bytes to `writeContract`: chain ID 998, legacy transaction, `gasPrice` at 1.2× the RPC estimate, and no EIP-1559 fee fields. Hashing those serialized bytes gives the transaction hash.

The wall-clock deadline and curl timeouts address the prior LOW finding. Shell and new JavaScript syntax checks passed. E2E and Solidity tests were not run because they write artifacts. No files changed.

**CHANGES**
## Round 5

Round 4 is resolved within a running process: not-found now retains the pending push, rebroadcasts identical bytes, and keeps other sends blocked. No HIGH findings.

1. **MEDIUM — Restart loses the pending-push serialization barrier.** [keeper/keeper.ts:289](/Users/hiroyusai/src/dayone/keeper/keeper.ts:289)

   **Scenario:** A push at nonce N remains unmined when the keeper restarts. The fresh process has no `refPending`. If its initial reference API read or preparation fails, `pushRef()` returns and the tick permits pool sends using latest nonce N. Those sends compete with the unresolved push—the condition round 4 sought to prevent.

   Reusing N for a new **reference push** is acceptable as a replacement attempt: both pushes cannot execute. Losing the barrier before that replacement is established is the problem.

   **Fix:** Persist the signed push and nonce before broadcasting, restore that state before permitting sends, and clear it only after receipt or nonce consumption. Add a restart regression with an unmined push and an initial reference-read failure.

Shell and helper JavaScript syntax checks and `git diff --check` passed. E2E and Solidity tests were not run because they write artifacts. No files changed.

**CHANGES**
## Round 5 finding: recorded, not fixed

A keeper restarted while its push is unmined has no record of it, so its first sends may use the
same nonce. One of the two transactions lands and the other is rejected or replaced; the loser is
retried on a later tick. That is the same as for a pool transaction left unmined across a restart,
which the keeper has always accepted. Persisting the pending push would need a state directory in
`deploy/cohost/install.sh`; not worth it for a testnet-only reference.
