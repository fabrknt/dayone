# Pre-publication re-review (r2) — `dcda128`

> Commit ids below are from before the second history rewrite (key-file names, 2026-11-14). The reviewed fixes are now `f630361`; this review was committed as `b7f83cc`.

Scope: `testnet-v2-1114` at `dcda128`, the complete reachable patch history
(`git log --all -p`), and a new clone of this branch. The accepted author email
and the accepted on-chain link from the operator to the owner's earlier address
are out of scope for findings below.

## Remaining findings

1. **P0 — Old private key-file locations are still reachable in history.** The
   current `docs/testnet.md` no longer identifies the deployed operator and
   keeper keys by their former local filenames. However, reachable commits
   `79ffcd1` and `d12daae` still expose
   `~/.dayone-testnet-2.key` and `~/.dayone-testnet-keeper.key` in the
   historical versions of that document. This is the unremediated
   key-file-location part of r1 finding 2; it is separate from the explicitly
   accepted operator-address linkage. Rewrite or remove those historical
   document versions before publication.

2. **P1 — The reviewed release is not on `master`, and the old branch still
   carries the private dependency.** `master` is `d04d334` and does not contain
   `dcda128`. Its `package.json` still declares
   `prebell: github:fabrknt/prebell#cbd4dd7`, and its lockfile resolves it via
   `git+ssh://git@github.com/fabrknt/prebell.git`. Thus a normal clone whose
   default branch is `master` gets both stale release material and a private
   fetch path. In addition, those same package and lockfile states remain
   visible in reachable history (including `0d21230`), so the full rewritten
   history still publishes the private repository reference. Move the public
   default/ref to the reviewed release and rewrite/squash/filter the old
   dependency-bearing history before making the repository public.

## r1 findings verified as resolved on the reviewed branch

- **1 — Local `/Users` paths:** no non-placeholder `/Users/...` path or local
  username was found in the current tree or reachable patches. The author email
  is intentionally retained under the owner's stated decision.
- **2 — Current deployment documentation:** current text has no former
  deployment-key filename; the accepted operator-address linkage remains. The
  historical filename exposure is recorded above.
- **3 — Private design/graduation material:** no `docs/design.md` or
  `docs/graduation.md` object is reachable from any ref.
- **5 — Testnet instructions:** the instructions now define `KEY`,
  `KEY_FILE`, `KEEPER_KEY_FILE`, and `PAUSER`; provide the `uv run --with
  hyperliquid-python-sdk` command; require `KEY_FILE` in `big_blocks.py`; and
  identify the v1 pool as legacy.
- **6 — Local quick start and sizing links:** Python 3 is documented, and all
  sizing references point into `lib/hl-price-guard`.
- **7 — Current install/demo dependency path:** the root manifest and lockfile
  contain no `prebell`, SSH Git, or private-repository fetch. `keeper.ts`
  dynamically imports `prebell` only when `PRIMARY_HALTS` is set, while
  `e2e.sh` skips that optional scenario unless `REQUIRE_PREBELL=1`. A fresh
  clone of `testnet-v2-1114` completed plain `npm install` successfully (37
  packages, all public registry dependencies); `zsh -n keeper/e2e.sh` and
  `node --check keeper/keeper.ts` also passed. I did not run `npm run demo`,
  because it intentionally invokes `forge script --broadcast`, which this
  review was expressly instructed not to run.
- **8 — Security/audit claims:** README claims are now limited to named
  replays/tests and call the work an internal review, not an audit.
- **9 — Attribution/provenance:** `NOTICE` now identifies Fabrknt, the two
  submodules and their licenses, and the Multicall3 runtime source, deployed
  address equivalence, copyright, and MIT license.

VERDICT: CHANGES
