Findings:

1. **P1 — A failed pause transaction still lets this keeper settle pending opens during a known halt or unknown feed state.**  
   [`keeper/keeper.ts:312`](keeper/keeper.ts:312) logs and absorbs a failed `setHoursPaused(true)`, then [`keeper/keeper.ts:359`](keeper/keeper.ts:359) proceeds to settle opens. This occurs on the first tick with no usable feed, a timeout/unreadable feed, or a detected halt if the pauser key is unset/unauthorized or the RPC/send fails. Gate keeper-initiated opens on `shouldPause` (and retain the hold if setting the pause fails).

2. **P1 — `POOL_ABI=v1` can clear an operator emergency pause before the halt feed reflects the halt.**  
   [`keeper/keeper.ts:193`](keeper/keeper.ts:193), [`keeper/keeper.ts:312`](keeper/keeper.ts:312). For v1, the keeper reads and writes the sole `opensPaused` flag. If the operator pauses on a fresh real-world halt while the cached/feed state still says trading, the keeper calls `setOpensPaused(false)`. V2 correctly isolates `hoursPaused`; v1 cannot. Reject `PRIMARY_HALTS` with `POOL_ABI=v1`, or disable automatic unpausing for that mode.

3. **P2 — Step 5b does not test that an actually empty/clear feed reopens, and can mask its final keeper failure.**  
   [`keeper/e2e.sh:98`](keeper/keeper/e2e.sh:98) pipes through `grep | sed` without `pipefail`; [`keeper/e2e.sh:105`](keeper/e2e.sh:105) runs the empty-feed case but asserts nothing afterward. The prior “other” case has an AAPL item, so it does not exercise the zero-item parser path. A regression where clear feeds stay paused can pass, since the next KRX assertion also expects paused. Add `set -o pipefail` and assert `opensPaused == false` immediately after `feed clear 5; hk`.

No unhandled rejection from the early `readHalts()` path: its fetch, file-read, parse, and timeout failures are caught internally. Missing/stale/future-dated feed states otherwise fail closed, including `--once` and calendar expiry. A hung fetch delays the whole tick (including liquidations), despite the comment claiming otherwise, but it does not unpause opens.

I could not run the E2E script here because the sandbox rejects the runner’s `nice(5)` call before Anvil starts.

VERDICT: CHANGES
