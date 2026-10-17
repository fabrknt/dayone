# Deploying to HyperEVM testnet

Checked 2026-10-17. Chain 998, RPC `https://rpc.hyperliquid-testnet.xyz/evm`.

## Market
Default: testnet xyz:TSLA. xyz is dex 65 on testnet (dex 1 on mainnet), so:
- `0x806` / `0x807` / `0x80a` take `650001`
- `0x80e` takes `750001`

On 10-17 its oracle was 352.31, its mark 373.63 and its BBO mid about 373.87, 612 bp above the
oracle. `DeployTestnet` therefore turns off the mark/mid bounds; the jump latch, two-step
settlement and both caps stay on. Other markets: `DEX=… INDEX=… SZ_DECIMALS=…`.

## Steps (the key holder runs 1, 2 and 3)
1. A fresh key with testnet HYPE on HyperEVM for gas (send from HyperCore testnet spot to the
   EVM, or a faucet). About 6.4M gas in all at 0.2 gwei.
2. Turn on big blocks for that address. LaunchPool's initcode is 18 KB with the optimizer (about
   3.6M gas), over the 2M small-block limit. This is a HyperCore action signed by the same key:
   `{"type": "evmUserModify", "usingBigBlocks": true}` (hyperliquid-python-sdk:
   `Exchange.use_big_block(True)`). It can be turned off again after deploying.
3. `forge script script/DeployTestnet.s.sol --rpc-url https://rpc.hyperliquid-testnet.xyz/evm --broadcast --private-key $KEY`
   It prints the mock USDC and pool addresses.
4. Mint mock USDC to a trader (`cast send $USDC "mint(address,uint256)" …`), approve the pool, and
   run the keeper: `RPC_URL=https://rpc.hyperliquid-testnet.xyz/evm POOL=$POOL PRIVATE_KEY=$KEY node keeper/keeper.ts`.

What testnet adds over `keeper/e2e.sh`: the real precompiles and a deployer's real oracle
updates, instead of mocks.
