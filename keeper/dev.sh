#!/bin/zsh
# Local playground for the web UI: anvil + mock precompiles + pool + keeper + a moving price.
#   ./keeper/dev.sh        (Ctrl-C stops everything)
# Writes web/public/local.json with the addresses; the UI reads it in local mode.
set -e
cd "$(dirname "$0")/.."
PORT=8546
RPC=http://127.0.0.1:$PORT
K0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80  # operator + keeper
K1=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d  # the UI's dev wallet
K2=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a  # moves the mock price (own nonce, so it never races the keeper)

anvil --port $PORT --block-time 1 --silent &
PIDS=($!)
trap 'kill $PIDS 2>/dev/null' EXIT INT TERM
until cast block-number --rpc-url $RPC >/dev/null 2>&1; do sleep 0.2; done

forge build --silent
CODE=$(forge inspect MockPrecompile deployedBytecode)
for a in 806 807 80e; do cast rpc --rpc-url $RPC anvil_setCode 0x0000000000000000000000000000000000000$a $CODE >/dev/null; done
# Multicall3 at its usual address, as on HyperEVM (the keeper batches its reads through it)
cast rpc --rpc-url $RPC anvil_setCode 0xcA11bde05977b3631167028862bE2a173976CA11 $(cat keeper/multicall3.code) >/dev/null
px() {
  cast send -q --rpc-url $RPC --private-key $K2 0x0000000000000000000000000000000000000807 "set(uint32,bytes)" 10001 $(cast abi-encode "f(uint64)" $1)
  cast send -q --rpc-url $RPC --private-key $K2 0x0000000000000000000000000000000000000806 "set(uint32,bytes)" 10001 $(cast abi-encode "f(uint64)" $1)
  cast send -q --rpc-url $RPC --private-key $K2 0x000000000000000000000000000000000000080e "set(uint32,bytes)" 110001 $(cast abi-encode "f(uint64,uint64)" $(($1 - 15)) $(($1 + 15)))
}
px 350000
forge script script/DeployLocal.s.sol --rpc-url $RPC --private-key $K0 --broadcast --silent >/dev/null
USDC=$(python3 -c "import json;print(json.load(open('keeper/.local.json'))['usdc'])")
POOL=$(python3 -c "import json;print(json.load(open('keeper/.local.json'))['pool'])")
mkdir -p web/public
cat > web/public/local.json <<JSON
{"rpc":"$RPC","chainId":31337,"pool":"$POOL","usdc":"$USDC","market":"xyz:TSLA (local mock)","devKey":"$K1"}
JSON
echo "pool $POOL  usdc $USDC  rpc $RPC"

RPC_URL=$RPC POOL=$POOL PRIVATE_KEY=$K0 node --disable-warning=ExperimentalWarning keeper/keeper.ts > /tmp/dayone-keeper.log 2>&1 &
PIDS+=($!)
echo "keeper log: /tmp/dayone-keeper.log"

# a random walk, one update every 3 s like HL's oracle; steps of up to 8 bp.
# To replay an SK Hynix-style bad update: echo 0.85 > /tmp/dayone-shock  (one step of x0.85;
# the walk carries on from there, so the jump latch stays tripped until the operator rearms)
echo "price shock: echo 0.85 > /tmp/dayone-shock"
rm -f /tmp/dayone-shock
p=350000
while true; do
  sleep 3
  if [ -f /tmp/dayone-shock ]; then
    p=$(python3 -c "print(int($p*$(cat /tmp/dayone-shock)))"); rm -f /tmp/dayone-shock
  else
    p=$(python3 -c "import random;print(int($p*(1+random.uniform(-8,8)/1e4)))")
  fi
  px $p
done
