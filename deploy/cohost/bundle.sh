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
# POOL_ABI=v1: 0x183A… predates the pauser role and claim(); drop it after a redeploy
printf 'RPC_URL=%s\nPOOL=%s\nPOOL_ABI=v1\nMARKET_HOURS=nyse\nTICK_MS=3000\n' https://rpc.hyperliquid-testnet.xyz/evm 0x183AA811bFc913fCf5630cbAA4B85b3a8499a707 > $B/keeper.env
COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -czf dist/dayone-keeper.tgz -C $B .
rm -rf $B
echo "dist/dayone-keeper.tgz $(wc -c < dist/dayone-keeper.tgz) bytes"
echo "sha256 $(shasum -a 256 dist/dayone-keeper.tgz | cut -d' ' -f1)  (pass to install.sh)"
