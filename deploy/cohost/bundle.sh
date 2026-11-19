#!/bin/zsh
# Build the keeper bundle for a host that is already running (Linux, arm64 or x64).
#   ./deploy/cohost/bundle.sh   -> dist/dayone-keeper.tgz
# Holds the keeper code, the pool ABI only, package files and keeper.env (no key).
set -euo pipefail
cd "$(dirname "$0")/../.."
forge build --silent
B=$(mktemp -d)
mkdir -p $B/keeper $B/out/LaunchPool.sol dist
cp keeper/keeper.ts keeper/campana.mjs keeper/krx.mjs $B/keeper/
cp package.json package-lock.json $B/
python3 -c "import json,sys;json.dump({'abi':json.load(open('out/LaunchPool.sol/LaunchPool.json'))['abi']},open(sys.argv[1],'w'),separators=(',',':'))" $B/out/LaunchPool.sol/LaunchPool.json
# The pool from docs/testnet.md unless POOL is set; POOL_ABI only for a pool from before the pauser
# role and claim() (v1, e.g. the 10-18 pool 0x183A…) or before the halted-market exits (v2).
# The default pool has a ReporterRef, so REF_COIN defaults to xyz:TSLA with it, and only with it.
[[ -z ${POOL:-} ]] && REF_COIN=${REF_COIN:-xyz:TSLA}
POOL=${POOL:-0x4B0d8AB73b2511EbDF9eBE474cf0C5a2a77AD8cD}
printf 'RPC_URL=%s\nPOOL=%s\nMARKET_HOURS=%s\nTICK_MS=3000\n' https://rpc.hyperliquid-testnet.xyz/evm $POOL ${MARKET_HOURS:-nyse} > $B/keeper.env
[[ -n ${POOL_ABI:-} ]] && printf 'POOL_ABI=%s\n' $POOL_ABI >> $B/keeper.env
# REF_COIN (e.g. xyz:TSLA) for a pool deployed with REPORTER=<this keeper's address>: the keeper
# pushes HL mainnet's oracle for that market to the pool's ReporterRef
[[ -n ${REF_COIN:-} ]] && printf 'REF_COIN=%s\n' $REF_COIN >> $B/keeper.env
COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -czf dist/dayone-keeper.tgz -C $B .
rm -rf $B
echo "dist/dayone-keeper.tgz $(wc -c < dist/dayone-keeper.tgz) bytes"
echo "sha256 $(shasum -a 256 dist/dayone-keeper.tgz | cut -d' ' -f1)  (pass to install.sh)"
