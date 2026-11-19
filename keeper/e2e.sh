#!/bin/zsh
# Local end-to-end: anvil + mock precompiles at their real addresses + pool + keeper.
#   ./keeper/e2e.sh
set -e
set -o pipefail
cd "$(dirname "$0")/.."
PORT=${E2E_PORT:-8546} # another project's local anvil may already hold 8546
RPC=http://127.0.0.1:$PORT
# anvil's well-known dev keys: 0 = operator and keeper, 1 = trader, 2 = pauser (the hours keeper, from step 5)
K0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
K1=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
T1=$(cast wallet address $K1)
K2=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
P2=$(cast wallet address $K2)

# chain time starts on Fri 2026-10-16 00:00 UTC, so the dated steps below (Sat 10-17, Mon 10-19, ...)
# are always in the future, whatever day this runs
# never run against a chain this script did not start (it would set code and move time there)
if cast chain-id --rpc-url $RPC >/dev/null 2>&1; then echo "port $PORT is already serving a chain: set E2E_PORT"; exit 1; fi
anvil --port $PORT --timestamp 1792108800 --silent &
ANVIL=$!
trap 'kill $ANVIL' EXIT
until cast block-number --rpc-url $RPC >/dev/null 2>&1; do sleep 0.2; done

forge build --silent
CODE=$(forge inspect HLMockPrecompile deployedBytecode)
for a in 806 807 80e; do cast rpc --rpc-url $RPC anvil_setCode 0x0000000000000000000000000000000000000$a $CODE >/dev/null; done
# Multicall3 at its usual address, as on HyperEVM (the keeper batches its reads through it)
cast rpc --rpc-url $RPC anvil_setCode 0xcA11bde05977b3631167028862bE2a173976CA11 $(cat keeper/multicall3.code) >/dev/null

# xyz:TSLA encodings: 10001 for 0x806/0x807, 110001 for 0x80e; prices in 1/1000 USD
px() {
  cast send -q --rpc-url $RPC --private-key $K0 0x0000000000000000000000000000000000000807 "set(uint32,bytes)" 10001 $(cast abi-encode "f(uint64)" $1)
  cast send -q --rpc-url $RPC --private-key $K0 0x0000000000000000000000000000000000000806 "set(uint32,bytes)" 10001 $(cast abi-encode "f(uint64)" $1)
  cast send -q --rpc-url $RPC --private-key $K0 0x000000000000000000000000000000000000080e "set(uint32,bytes)" 110001 $(cast abi-encode "f(uint64,uint64)" $(($1 - 5)) $(($1 + 5)))
}
later() { cast rpc --rpc-url $RPC evm_increaseTime $1 >/dev/null; cast rpc --rpc-url $RPC evm_mine >/dev/null; }
keeper() { RPC_URL=$RPC POOL=$POOL PRIVATE_KEY=$K0 node --disable-warning=ExperimentalWarning keeper/keeper.ts --once | sed 's/^[^ ]* /  keeper: /'; }
entry() { cast call --rpc-url $RPC $POOL "positions(uint256)(address,bool,uint16,uint256,uint256,uint64,bool,uint16,uint64,uint16,uint256,uint16)" $1 | sed -n 5p | cut -d' ' -f1; }
owner() { cast call --rpc-url $RPC $POOL "positions(uint256)(address,bool,uint16,uint256,uint256,uint64,bool,uint16,uint64,uint16,uint256,uint16)" $1 | sed -n 1p; }
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got $2, want $3"; exit 1; fi; }

px 350000
forge script script/DeployLocal.s.sol --rpc-url $RPC --private-key $K0 --broadcast --silent >/dev/null
USDC=$(python3 -c "import json;print(json.load(open('keeper/.local.json'))['usdc'])")
POOL=$(python3 -c "import json;print(json.load(open('keeper/.local.json'))['pool'])")
cast send -q --rpc-url $RPC --private-key $K0 $USDC "mint(address,uint256)" $T1 1000000000000
cast send -q --rpc-url $RPC --private-key $K1 $USDC "approve(address,uint256)" $POOL 1000000000000

echo "1. request an open: the keeper waits for settleDelay"
cast send -q --rpc-url $RPC --private-key $K1 $POOL "requestOpen(bool,uint256,uint16)" true 10000000000 10
keeper
check "not settled before the delay" "$(entry 1)" 0

echo "2. after the delay the keeper settles at the oracle"
later 3
keeper
check "entry = 350.000" "$(entry 1)" 350000000000000000000

echo "3. the price walks down 1.5% at a time; the keeper pokes each step and liquidates at -8.7%"
for p in 344750 339579 334485 329468 324526 319658; do px $p; later 3; keeper; done
check "position 1 liquidated" "$(owner 1)" 0x0000000000000000000000000000000000000000

echo "4. a second position, then a 15% jump in one update: the keeper is refused and waits"
px 319658; later 3; keeper
cast send -q --rpc-url $RPC --private-key $K1 $POOL "requestOpen(bool,uint256,uint16)" true 10000000000 10
later 3; keeper
check "position 2 open" "$(entry 2)" 319658000000000000000
px 271709; later 3
LOG=$(mktemp)
keeper | tee $LOG
grep -q "Breach Jump" $LOG && echo "ok   poke refused with a Jump breach" || { echo "FAIL no Jump breach"; exit 1; }
check "position 2 not liquidated at the bad price" "$(entry 2)" 319658000000000000000
echo "5. MARKET_HOURS=nyse with the pauser key: Saturday pauses new positions, Monday 10:00 ET reopens them"
cast send -q --rpc-url $RPC --private-key $K0 $POOL "setPauser(address)" $P2
cast rpc --rpc-url $RPC evm_setNextBlockTimestamp 1792260000 >/dev/null; cast rpc --rpc-url $RPC evm_mine >/dev/null  # Sat 2026-10-17 18:00 UTC
RPC_URL=$RPC POOL=$POOL PRIVATE_KEY=$K2 MARKET_HOURS=nyse node --disable-warning=ExperimentalWarning keeper/keeper.ts --once | grep -E "setHoursPaused" | sed 's/^[^ ]* /  keeper: /'
check "paused on Saturday" "$(cast call --rpc-url $RPC $POOL "opensPaused()(bool)")" true
cast rpc --rpc-url $RPC evm_setNextBlockTimestamp 1792418400 >/dev/null; cast rpc --rpc-url $RPC evm_mine >/dev/null  # Mon 2026-10-19 14:00 UTC = 10:00 EDT
RPC_URL=$RPC POOL=$POOL PRIVATE_KEY=$K2 MARKET_HOURS=nyse node --disable-warning=ExperimentalWarning keeper/keeper.ts --once | grep -E "setHoursPaused" | sed 's/^[^ ]* /  keeper: /'
check "open on Monday 10:00 ET" "$(cast call --rpc-url $RPC $POOL "opensPaused()(bool)")" false
if [ -d node_modules/prebell ]; then
echo "5b. PRIMARY_HALTS=TSLA (prebell): a Nasdaq LULD halt pauses new positions, a clear feed reopens them, a stale feed pauses"
# a saved Nasdaq feed (prebell's fixture) rewritten for chain time: published at $2 seconds before
# now, with TSLA halted at 09:58 ET if $1 is "halted"
feed() {
  node -e '
    const fs = require("node:fs");
    const [src, out, mode, age] = process.argv.slice(1);
    const x = fs.readFileSync(src, "utf8");
    const at = new Date((1792418400 - Number(age)) * 1000).toUTCString();
    const item = x.match(/<item>[\s\S]*?<\/item>/)[0];
    const tsla = item.replace(/<title>[^<]*/, "<title>TSLA").replace(/<ndaq:IssueSymbol>[^<]*/, "<ndaq:IssueSymbol>TSLA")
      .replace(/<ndaq:HaltDate>[^<]*/, "<ndaq:HaltDate>10/19/2026").replace(/<ndaq:HaltTime>[^<]*/, "<ndaq:HaltTime>09:58:00.000")
      .replace(/<ndaq:ReasonCode>[^<]*/, "<ndaq:ReasonCode>LUDP");
    const items = mode === "halted" ? tsla : mode === "other" ? tsla.replace(/TSLA/g, "AAPL") : "";
    fs.writeFileSync(out, x.replace(/<item>[\s\S]*<\/item>/, items).replace(/(<channel>[\s\S]*?<pubDate>)[^<]*/, `$1${at}`)
      .replace(/<ndaq:numItems>\d+/, `<ndaq:numItems>${items ? 1 : 0}`));
  ' node_modules/prebell/fixtures/nasdaq-tradehalts.xml $FEED $1 $2
}
FEED=$(mktemp)
hk() { RPC_URL=$RPC POOL=$POOL PRIVATE_KEY=$K2 MARKET_HOURS=nyse PRIMARY_HALTS=TSLA HALTS_FILE=$FEED node --disable-warning=ExperimentalWarning keeper/keeper.ts --once | grep -E "setHoursPaused|primary market" | sed 's/^[^ ]* /  keeper: /'; }
feed halted 5; hk
check "paused while TSLA is halted" "$(cast call --rpc-url $RPC $POOL "opensPaused()(bool)")" true
feed other 5; hk
check "open once the feed shows only another stock halted" "$(cast call --rpc-url $RPC $POOL "opensPaused()(bool)")" false
feed clear 600; hk
check "paused on a 10-minute-old feed" "$(cast call --rpc-url $RPC $POOL "opensPaused()(bool)")" true
feed clear 5; hk
check "open again on a clear feed (no items)" "$(cast call --rpc-url $RPC $POOL "opensPaused()(bool)")" false
elif [ -n "$REQUIRE_PREBELL" ]; then
  echo "FAIL 5b: REQUIRE_PREBELL is set but prebell is not installed"; exit 1
else
  echo "5b. skipped: PRIMARY_HALTS needs prebell (not public yet), not installed" >&2
fi
echo "6. MARKET_HOURS=krx: Monday 23:00 KST pauses new positions, Tuesday 10:00 KST reopens them"
RPC_URL=$RPC POOL=$POOL PRIVATE_KEY=$K2 MARKET_HOURS=krx node --disable-warning=ExperimentalWarning keeper/keeper.ts --once | grep -E "setHoursPaused" | sed 's/^[^ ]* /  keeper: /'
check "paused at 23:00 KST" "$(cast call --rpc-url $RPC $POOL "opensPaused()(bool)")" true
cast rpc --rpc-url $RPC evm_setNextBlockTimestamp 1792458000 >/dev/null; cast rpc --rpc-url $RPC evm_mine >/dev/null  # Tue 2026-10-20 01:00 UTC = 10:00 KST
RPC_URL=$RPC POOL=$POOL PRIVATE_KEY=$K2 MARKET_HOURS=krx node --disable-warning=ExperimentalWarning keeper/keeper.ts --once | grep -E "setHoursPaused" | sed 's/^[^ ]* /  keeper: /'
check "open on Tuesday 10:00 KST" "$(cast call --rpc-url $RPC $POOL "opensPaused()(bool)")" false
echo "6b. the operator's own pause holds through trading hours: the pauser key cannot clear it"
cast send -q --rpc-url $RPC --private-key $K0 $POOL "setOpensPaused(bool)" true
RPC_URL=$RPC POOL=$POOL PRIVATE_KEY=$K2 MARKET_HOURS=krx node --disable-warning=ExperimentalWarning keeper/keeper.ts --once | grep -E "setHoursPaused" | sed 's/^[^ ]* /  keeper: /' || true
check "still paused at 10:00 KST" "$(cast call --rpc-url $RPC $POOL "opensPaused()(bool)")" true
cast send -q --rpc-url $RPC --private-key $K2 $POOL "setOpensPaused(bool)" false 2>/dev/null && { echo "FAIL pauser cleared the operator pause"; exit 1; } || echo "ok   pauser refused setOpensPaused"
cast send -q --rpc-url $RPC --private-key $K0 $POOL "setOpensPaused(bool)" false
echo "7. into 2027: New Year's Day stays paused, Monday 10:00 ET reopens; past 2027 opens stay paused and the keeper carries on"
cast rpc --rpc-url $RPC evm_setNextBlockTimestamp 1798815600 >/dev/null; cast rpc --rpc-url $RPC evm_mine >/dev/null  # Fri 2027-01-01 10:00 ET, holiday
RPC_URL=$RPC POOL=$POOL PRIVATE_KEY=$K2 MARKET_HOURS=nyse node --disable-warning=ExperimentalWarning keeper/keeper.ts --once | grep -E "setHoursPaused" | sed 's/^[^ ]* /  keeper: /'
check "paused on 2027-01-01" "$(cast call --rpc-url $RPC $POOL "opensPaused()(bool)")" true
cast rpc --rpc-url $RPC evm_setNextBlockTimestamp 1799074800 >/dev/null; cast rpc --rpc-url $RPC evm_mine >/dev/null  # Mon 2027-01-04 10:00 ET
RPC_URL=$RPC POOL=$POOL PRIVATE_KEY=$K2 MARKET_HOURS=nyse node --disable-warning=ExperimentalWarning keeper/keeper.ts --once | grep -E "setHoursPaused" | sed 's/^[^ ]* /  keeper: /'
check "open on 2027-01-04 10:00 ET" "$(cast call --rpc-url $RPC $POOL "opensPaused()(bool)")" false
cast rpc --rpc-url $RPC evm_setNextBlockTimestamp 1830610800 >/dev/null; cast rpc --rpc-url $RPC evm_mine >/dev/null  # Tue 2028-01-04 10:00 ET, no calendar
LOG=$(mktemp)
RPC_URL=$RPC POOL=$POOL PRIVATE_KEY=$K2 MARKET_HOURS=nyse node --disable-warning=ExperimentalWarning keeper/keeper.ts --once > $LOG 2>&1
grep -q "CALENDAR EXPIRED" $LOG && ! grep -q "tick failed" $LOG && echo "ok   calendar expiry logged, tick completed" || { cat $LOG; echo "FAIL calendar expiry"; exit 1; }
check "paused past the calendar" "$(cast call --rpc-url $RPC $POOL "opensPaused()(bool)")" true
echo "8. a fresh pool: a winner is queued, a later open fee pays part of it, the keeper sends it"
px 350000
forge script script/DeployLocal.s.sol --rpc-url $RPC --private-key $K0 --broadcast --silent >/dev/null
POOL=$(python3 -c "import json;print(json.load(open('keeper/.local.json'))['pool'])")
USDC=$(python3 -c "import json;print(json.load(open('keeper/.local.json'))['usdc'])")
cast send -q --rpc-url $RPC --private-key $K0 $USDC "mint(address,uint256)" $T1 1000000000000
cast send -q --rpc-url $RPC --private-key $K1 $USDC "approve(address,uint256)" $POOL 1000000000000
cast send -q --rpc-url $RPC --private-key $K1 $POOL "requestOpen(bool,uint256,uint16)" true 10000000000 10
later 3; keeper
px 353500  # +1%: ($1,000 - $50 close fee) * 85% = $807.50 owed, the pool holds the $50 open fee
cast send -q --rpc-url $RPC --private-key $K1 $POOL "requestClose(uint256)" 1
later 3; keeper
check "winner queued" "$(cast call --rpc-url $RPC $POOL "totalDebt()(uint256)" | cut -d' ' -f1)" 757500000
cast send -q --rpc-url $RPC --private-key $K1 $POOL "requestOpen(bool,uint256,uint16)" false 10000000000 10
later 3; keeper  # settles: the $50 open fee goes to the queue
check "fee paid into the queue" "$(cast call --rpc-url $RPC $POOL "unclaimed()(uint256)" | cut -d' ' -f1)" 50000000
BEFORE=$(cast call --rpc-url $RPC $USDC "balanceOf(address)(uint256)" $T1 | cut -d' ' -f1)
keeper
check "keeper sent the winner's paid part" "$(cast call --rpc-url $RPC $POOL "unclaimed()(uint256)" | cut -d' ' -f1)" 0
check "winner received \$50" "$(( $(cast call --rpc-url $RPC $USDC "balanceOf(address)(uint256)" $T1 | cut -d' ' -f1) - BEFORE ))" 50000000
echo "9. a winner the token refuses to pay (blocked) does not hold up the next one; scanning 1 debt a tick"
K3=0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6
T3=$(cast wallet address $K3)
px 350000
# until the claim check, the keeper sends no claims: POOL_ABI=v1 skips them (opensPaused still
# reads on this pool, and without MARKET_HOURS nothing else differs)
k0() { RPC_URL=$RPC POOL=$POOL PRIVATE_KEY=$K0 POOL_ABI=v1 node --disable-warning=ExperimentalWarning keeper/keeper.ts --once | sed 's/^[^ ]* /  keeper: /'; }
forge script script/DeployLocal.s.sol --rpc-url $RPC --private-key $K0 --broadcast --silent >/dev/null
POOL=$(python3 -c "import json;print(json.load(open('keeper/.local.json'))['pool'])")
USDC=$(python3 -c "import json;print(json.load(open('keeper/.local.json'))['usdc'])")
for k in $K0 $K1 $K3; do
  cast send -q --rpc-url $RPC --private-key $K0 $USDC "mint(address,uint256)" $(cast wallet address $k) 1000000000000
  cast send -q --rpc-url $RPC --private-key $k $USDC "approve(address,uint256)" $POOL 1000000000000
done
cast send -q --rpc-url $RPC --private-key $K3 $POOL "requestOpen(bool,uint256,uint16)" true 10000000000 10
cast send -q --rpc-url $RPC --private-key $K1 $POOL "requestOpen(bool,uint256,uint16)" true 10000000000 10
later 3; k0
px 353500  # +1%: each winner is owed $807.50; the pool holds $100 of open fees
cast send -q --rpc-url $RPC --private-key $K3 $POOL "requestClose(uint256)" 1
later 3; k0  # debt 0 (blocked winner): $707.50
cast send -q --rpc-url $RPC --private-key $K1 $POOL "requestClose(uint256)" 2
later 3; k0  # debt 1: $807.50
cast send -q --rpc-url $RPC --private-key $K0 $USDC "setBlocked(address,bool)" $T3 true
cast send -q --rpc-url $RPC --private-key $K0 $POOL "requestOpen(bool,uint256,uint16)" true 25000000000 20
later 3; k0
px 350000  # the $500K long loses about $4,950: the whole queue is paid
cast send -q --rpc-url $RPC --private-key $K0 $POOL "requestClose(uint256)" 3
later 3; k0
check "queue paid" "$(cast call --rpc-url $RPC $POOL "totalDebt()(uint256)" | cut -d' ' -f1)" 0
BEFORE=$(cast call --rpc-url $RPC $USDC "balanceOf(address)(uint256)" $T1 | cut -d' ' -f1)
# a keeper restarted every tick (the worst case: the scan position lives in the process), one
# debt scanned per tick: each fresh process starts at a clock-derived offset, so it gets past
# the blocked debt 0
KLOG=$(mktemp)
for i in $(seq 1 20); do
  RPC_URL=$RPC POOL=$POOL PRIVATE_KEY=$K0 CLAIM_SCAN=1 TICK_MS=300 node --disable-warning=ExperimentalWarning keeper/keeper.ts --once >> $KLOG 2>&1
  [ "$(cast call --rpc-url $RPC $POOL "claimable(uint256)(uint256)" 1 | cut -d' ' -f1)" = 0 ] && break
  sleep 0.35
done
grep -E "claim" $KLOG | sort | uniq -c | sed 's/^ */  /; s/ [0-9T:.-]*Z / keeper: /; s/ 0x[0-9a-f]*$//'
check "next winner paid despite the blocked one ahead" "$(( $(cast call --rpc-url $RPC $USDC "balanceOf(address)(uint256)" $T1 | cut -d' ' -f1) - BEFORE ))" 807500000
check "blocked winner's part still claimable" "$(cast call --rpc-url $RPC $POOL "claimable(uint256)(uint256)" 0 | cut -d' ' -f1)" 707500000
echo "10. the market is halted (book 0/0, as para:PAPER read on mainnet): the keeper notes it, waits an hour, then settles the close"
px 350000
forge script script/DeployLocal.s.sol --rpc-url $RPC --private-key $K0 --broadcast --silent >/dev/null
POOL=$(python3 -c "import json;print(json.load(open('keeper/.local.json'))['pool'])")
USDC=$(python3 -c "import json;print(json.load(open('keeper/.local.json'))['usdc'])")
cast send -q --rpc-url $RPC --private-key $K0 $USDC "mint(address,uint256)" $T1 1000000000000
cast send -q --rpc-url $RPC --private-key $K1 $USDC "approve(address,uint256)" $POOL 1000000000000
cast send -q --rpc-url $RPC --private-key $K1 $POOL "requestOpen(bool,uint256,uint16)" true 10000000000 10
cast send -q --rpc-url $RPC --private-key $K1 $POOL "requestOpen(bool,uint256,uint16)" false 10000000000 10
later 3; keeper
cast send -q --rpc-url $RPC --private-key $K1 $POOL "requestClose(uint256)" 1
halt() {
  cast send -q --rpc-url $RPC --private-key $K0 0x0000000000000000000000000000000000000807 "set(uint32,bytes)" 10001 $(cast abi-encode "f(uint64)" $1)
  cast send -q --rpc-url $RPC --private-key $K0 0x0000000000000000000000000000000000000806 "set(uint32,bytes)" 10001 $(cast abi-encode "f(uint64)" $1)
  cast send -q --rpc-url $RPC --private-key $K0 0x000000000000000000000000000000000000080e "set(uint32,bytes)" 110001 $(cast abi-encode "f(uint64,uint64)" 0 0)
}
halt 343000
later 3; keeper
check "frozen price noted" "$(cast call --rpc-url $RPC $POOL "frozenPx()(uint256)" | cut -d' ' -f1)" 343000000000000000000
check "close held during the hour" "$(entry 1)" 350000000000000000000
# chain time also runs with the wall clock while the keeper starts, so compare chain times
for i in $(seq 1 50); do later 60; keeper >/dev/null; done
check "close still held after 50 minutes of sightings" "$(entry 1)" 350000000000000000000
for i in $(seq 1 15); do later 60; keeper >/dev/null; [ "$(owner 1)" = 0x0000000000000000000000000000000000000000 ] && break; done
check "close settled at the frozen oracle" "$(owner 1)" 0x0000000000000000000000000000000000000000
FROZEN_AT=$(cast call --rpc-url $RPC $POOL "frozenAt()(uint64)" | cut -d" " -f1)
SETTLED_AT=$(cast block --rpc-url $RPC latest -f timestamp)
check "no earlier than an hour after the first sighting" "$(( SETTLED_AT - FROZEN_AT >= 3600 ))" 1
echo "11. the operator ends the pool at the settle price: after paramsDelay the keeper settles the rest"
cast send -q --rpc-url $RPC --private-key $K0 $POOL "proposeEnd(uint256)" 343000000000000000000
echo "    (the keeper on a pool without the exits holds its sends on the empty book: POOL_ABI=v2)"
LOG=$(mktemp)
RPC_URL=$RPC POOL=$POOL PRIVATE_KEY=$K0 POOL_ABI=v2 node --disable-warning=ExperimentalWarning keeper/keeper.ts --once > $LOG 2>&1
! grep -qE "tick failed|noteFrozen|settle|liquidate|poke" $LOG && echo "ok   v2 keeper ticks and sends nothing" || { cat $LOG; echo "FAIL v2 keeper"; exit 1; }
later 61
cast send -q --rpc-url $RPC --private-key $K0 $POOL "applyEnd()"
keeper
check "short settled without a request" "$(owner 2)" 0x0000000000000000000000000000000000000000
echo "12. a one-sided book after a halt is not a halt: the keeper clears the frozen clock (Codex round 13b)"
px 350000
forge script script/DeployLocal.s.sol --rpc-url $RPC --private-key $K0 --broadcast --silent >/dev/null
POOL=$(python3 -c "import json;print(json.load(open('keeper/.local.json'))['pool'])")
halt 343000
later 3; keeper
check "frozen price noted" "$(cast call --rpc-url $RPC $POOL "frozenPx()(uint256)" | cut -d' ' -f1)" 343000000000000000000
cast send -q --rpc-url $RPC --private-key $K0 0x000000000000000000000000000000000000080e "set(uint32,bytes)" 110001 $(cast abi-encode "f(uint64,uint64)" 0 343005)
later 3; keeper
check "cleared on a one-sided book" "$(cast call --rpc-url $RPC $POOL "frozenPx()(uint256)" | cut -d' ' -f1)" 0
echo "13. REF_COIN with a ReporterRef: a wrong key or a far price holds settlement and nothing else; a swapped reference is followed; an unmined push holds every other send until it is mined"
# waitfor SECONDS CMD...: until CMD succeeds, failing the run after SECONDS
waitfor() { local end=$(( SECONDS + $1 )); shift; until "$@"; do [ $SECONDS -lt $end ] || { echo "FAIL timed out waiting for: $*"; exit 1; }; sleep 0.2; done; }
px 350000
REFPX=$(mktemp); echo 350.00 > $REFPX
REFPORT=$((PORT + 52))
if curl -s -m 2 -o /dev/null http://127.0.0.1:$REFPORT; then echo "port $REFPORT is taken: set E2E_PORT"; exit 1; fi
node keeper/ref-api.mjs $REFPX $REFPORT & REFAPI=$!
trap 'kill $ANVIL $REFAPI' EXIT
refapi_up() { kill -0 $REFAPI && curl -s -m 2 -X POST http://127.0.0.1:$REFPORT | grep -q xyz:TSLA; }
waitfor 10 refapi_up
A0=$(cast wallet address $K0)
OUT=$(DEX=1 INDEX=1 SZ_DECIMALS=3 REPORTER=$A0 forge script script/DeployTestnet.s.sol --rpc-url $RPC --private-key $K0 --broadcast 2>&1)
POOL=$(echo $OUT | awk '/ pool /{print $2}'); USDC=$(echo $OUT | awk '/ usdc /{print $2}'); REF=$(echo $OUT | awk '/ ref /{print $2}')
cast send -q --rpc-url $RPC --private-key $K0 $USDC "mint(address,uint256)" $T1 1000000000
cast send -q --rpc-url $RPC --private-key $K1 $USDC "approve(address,uint256)" $POOL 1000000000
cast send -q --rpc-url $RPC --private-key $K1 $POOL "requestOpen(bool,uint256,uint16)" true 20000000 10
later 3
rkeeper() { RPC_URL=$RPC POOL=$POOL PRIVATE_KEY=$1 REF_COIN=xyz:TSLA REF_API=http://127.0.0.1:$REFPORT node --disable-warning=ExperimentalWarning keeper/keeper.ts --once > $LOG 2>&1; sed 's/^[^ ]* /  keeper: /' $LOG; }
LOG=$(mktemp)
rkeeper $K1
grep -q "REFERENCE NOT PUSHED" $LOG && grep -q "settle(1) skipped: Breach RefStale" $LOG && ! grep -q "tick failed" $LOG \
  && echo "ok   a key that is not the reporter is reported, and the tick goes on" || { echo "FAIL wrong reporter"; exit 1; }
echo 357.00 > $REFPX; rkeeper $K0
grep -q "Breach RefOracle: 197 over 150" $LOG && echo "ok   2% from the reference: refused" || { echo "FAIL no RefOracle breach"; exit 1; }
echo 350.50 > $REFPX; rkeeper $K0
check "settled within the bound" "$(entry 1)" 350000000000000000000
# the operator swaps in a new reference (same params and bounds, applied after paramsDelay) under a running keeper
REF2=$(forge create --rpc-url $RPC --private-key $K0 --broadcast src/testnet/ReporterRef.sol:ReporterRef --constructor-args $A0 180 | awk '/Deployed to/{print $3}')
RLOG=$(mktemp)
RPC_URL=$RPC POOL=$POOL PRIVATE_KEY=$K0 REF_COIN=xyz:TSLA REF_API=http://127.0.0.1:$REFPORT REF_PUSH_MS=1000 TICK_MS=200 node --disable-warning=ExperimentalWarning keeper/keeper.ts > $RLOG 2>&1 & KP=$!
trap 'kill $ANVIL $REFAPI $KP 2>/dev/null' EXIT
waitfor 30 grep -q "reference push ok" $RLOG
cast send -q --rpc-url $RPC --private-key $K0 $POOL "$(cast sig 'proposeParams((uint16,uint16,uint16,uint64,uint64,uint256,uint256,uint256,uint16,uint256,uint16,uint16,uint16,uint16,uint16,uint16,uint16),(uint16,uint16,uint16,uint16),address)')$(cast call --rpc-url $RPC $POOL 'getParams()' | cut -c3-)$(cast call --rpc-url $RPC $POOL 'bounds()' | cut -c3-)$(cast abi-encode 'f(address)' $REF2 | cut -c3-)"
later 86401
cast send -q --rpc-url $RPC --private-key $K0 $POOL "applyParams()"
echo 351.00 > $REFPX
ref2_pushed() { [ "$(cast call --rpc-url $RPC $REF2 'price()(uint256)' | cut -d' ' -f1)" = 351000000000000000000 ]; }
waitfor 30 ref2_pushed
kill $KP
grep "reference changed" $RLOG | sed 's/^[^ ]* /  keeper: /'
check "the running keeper pushes the swapped-in reference" "$(cast call --rpc-url $RPC $REF2 'price()(uint256)' | cut -d' ' -f1)" 351000000000000000000
# a due open while the last push is still fresh; mining stops, so the next push stays unmined
cast send -q --rpc-url $RPC --private-key $K1 $POOL "requestOpen(bool,uint256,uint16)" true 20000000 10
later 3
cast rpc --rpc-url $RPC evm_setAutomine false >/dev/null
RPC_URL=$RPC POOL=$POOL PRIVATE_KEY=$K0 REF_COIN=xyz:TSLA REF_API=http://127.0.0.1:$REFPORT REF_PUSH_MS=1000 REF_WAIT_MS=2000 TICK_MS=200 node --disable-warning=ExperimentalWarning keeper/keeper.ts > $RLOG 2>&1 & KP=$!
waitfor 30 grep -q "holding other sends" $RLOG
sleep 5 # many ticks, and several REF_PUSH_MS, while the push stays unmined
pending() { cast rpc --rpc-url $RPC txpool_status | python3 -c "import json,sys;print(int(json.load(sys.stdin)['pending'],16))"; }
check "one transaction in flight: the push" "$(pending)" 1
check "no second push" "$(grep -c 'holding other sends' $RLOG)" 1
check "the due open is not sent behind it" "$(grep -c 'settle(2)' $RLOG)" 0
# the node forgets the push (as a lagging node would answer): the keeper broadcasts the same bytes again
H1=$(grep -o "reference push 0x[0-9a-f]* not mined" $RLOG | head -1 | cut -d' ' -f3)
cast rpc --rpc-url $RPC anvil_dropTransaction $H1 >/dev/null
waitfor 30 grep -q "$H1 unknown to the node; broadcast again" $RLOG
check "the same push in flight again, nothing else" "$(pending)" 1
check "no second push" "$(grep -c 'holding other sends' $RLOG)" 1
check "the due open is still not sent" "$(grep -c 'settle(2)' $RLOG)" 0
cast rpc --rpc-url $RPC evm_setAutomine true >/dev/null; cast rpc --rpc-url $RPC evm_mine >/dev/null
settled2() { [ "$(entry 2)" != 0 ]; }
waitfor 30 settled2
kill $KP
grep -E "holding|unknown|resolved" $RLOG | sed 's/^[^ ]* /  keeper: /'
check "once the push is mined, the open settles" "$(entry 2)" 350000000000000000000
# the node takes a push but its answer is lost: the push still counts as in flight until resolved
LOSE=$(mktemp -u); LOSSPORT=$((PORT + 53))
if curl -s -m 2 -o /dev/null http://127.0.0.1:$LOSSPORT; then echo "port $LOSSPORT is taken: set E2E_PORT"; exit 1; fi
node keeper/rpc-lossy.mjs $RPC $LOSSPORT $LOSE & LOSSY=$!
trap 'kill $ANVIL $REFAPI $LOSSY 2>/dev/null' EXIT
lossy_up() { kill -0 $LOSSY && cast chain-id --rpc-url http://127.0.0.1:$LOSSPORT >/dev/null 2>&1; }
waitfor 10 lossy_up
touch $LOSE
N0=$(cast nonce --rpc-url $RPC $A0)
RPC_URL=http://127.0.0.1:$LOSSPORT POOL=$POOL PRIVATE_KEY=$K0 REF_COIN=xyz:TSLA REF_API=http://127.0.0.1:$REFPORT node --disable-warning=ExperimentalWarning keeper/keeper.ts --once > $LOG 2>&1
sed 's/^[^ ]* /  keeper: /' $LOG | grep -v refreshEntryBounds
grep -q "broadcast without a clear answer" $LOG && ! grep -qE "refreshEntryBounds|tick failed" $LOG \
  && echo "ok   a lost broadcast answer holds the rest of the tick" || { echo "FAIL lost broadcast answer"; exit 1; }
check "the push went through regardless" "$(cast nonce --rpc-url $RPC $A0)" $((N0 + 1))
rm $LOSE; kill $LOSSY
echo "all ok"
