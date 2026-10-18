#!/bin/zsh
# Local end-to-end: anvil + mock precompiles at their real addresses + pool + keeper.
#   ./keeper/e2e.sh
set -e
cd "$(dirname "$0")/.."
PORT=8546
RPC=http://127.0.0.1:$PORT
# anvil's well-known dev keys: 0 = operator and keeper, 1 = trader, 2 = pauser (the hours keeper, from step 5)
K0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
K1=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
T1=$(cast wallet address $K1)
K2=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
P2=$(cast wallet address $K2)

# chain time starts on Fri 2026-10-16 00:00 UTC, so the dated steps below (Sat 10-17, Mon 10-19, ...)
# are always in the future, whatever day this runs
anvil --port $PORT --timestamp 1792108800 --silent &
ANVIL=$!
trap "kill $ANVIL" EXIT
until cast block-number --rpc-url $RPC >/dev/null 2>&1; do sleep 0.2; done

forge build --silent
CODE=$(forge inspect MockPrecompile deployedBytecode)
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
echo "7. past the calendar: opens stay paused and the keeper carries on"
cast rpc --rpc-url $RPC evm_setNextBlockTimestamp 1799143200 >/dev/null; cast rpc --rpc-url $RPC evm_mine >/dev/null  # Tue 2027-01-05 10:00 UTC
LOG=$(mktemp)
RPC_URL=$RPC POOL=$POOL PRIVATE_KEY=$K2 MARKET_HOURS=nyse node --disable-warning=ExperimentalWarning keeper/keeper.ts --once > $LOG 2>&1
grep -q "CALENDAR EXPIRED" $LOG && ! grep -q "tick failed" $LOG && echo "ok   calendar expiry logged, tick completed" || { cat $LOG; echo "FAIL calendar expiry"; exit 1; }
check "paused past the calendar" "$(cast call --rpc-url $RPC $POOL "opensPaused()(bool)")" true
echo "all ok"
