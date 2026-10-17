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
printf 'RPC_URL=%s\nPOOL=%s\nMARKET_HOURS=nyse\nTICK_MS=2000\n' https://rpc.hyperliquid-testnet.xyz/evm 0x372Efd44DD50FBc0b070A0729756659f12539040 > $B/keeper.env
COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -czf dist/dayone-keeper.tgz -C $B .
rm -rf $B
echo "dist/dayone-keeper.tgz $(wc -c < dist/dayone-keeper.tgz) bytes"
