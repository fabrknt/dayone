// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {HLPriceGuard} from "hl-price-guard/HLPriceGuard.sol";
import {LaunchPool, IERC20} from "../src/LaunchPool.sol";
import {MockUSDC} from "../test/Mocks.sol";

/// HyperEVM testnet (chain 998). Defaults to xyz:TSLA on testnet: xyz is dex 65 there, so the
/// oracle index is 650001 and the BBO index 750001 (checked 2026-10-17).
///
/// The testnet book sits far from its oracle (mid 612 bp above it on 10-17), so the mark/mid
/// bounds are off here; the jump latch, two-step settlement and both caps stay on.
/// A mock USDC is deployed as collateral; mint it with MockUSDC.mint. The pool is seeded with
/// SEED (default 10,000) mock USDC, which with stressMoveBps at 10% backs about $100K net.
///
///   forge script script/DeployTestnet.s.sol --rpc-url https://rpc.hyperliquid-testnet.xyz/evm \
///     --broadcast --private-key $KEY
contract DeployTestnet is Script {
    function run() external {
        uint32 dex = uint32(vm.envOr("DEX", uint256(65)));
        uint32 index = uint32(vm.envOr("INDEX", uint256(1)));
        uint8 szDecimals = uint8(vm.envOr("SZ_DECIMALS", uint256(3)));
        uint256 usdc = 1e6;
        vm.startBroadcast();
        MockUSDC token = new MockUSDC();
        LaunchPool pool = new LaunchPool(
            IERC20(address(token)),
            HLPriceGuard.Asset({dex: dex, index: index, szDecimals: szDecimals}),
            HLPriceGuard.Bounds({maxMarkOracleBps: 0, maxMidOracleBps: 0, maxSpreadBps: 100, maxRefOracleBps: 0}),
            LaunchPool.Params({
                maxLeverage: 20,
                maintenanceBps: 250,
                feeBps: 5,
                settleDelay: 3,
                capWindow: 60,
                capPerWindow: 30_000 * usdc, // xyz:TSLA's mainnet safe cap, measure/safe_caps.py 10-17
                minNotional: 100 * usdc,
                maxNotional: 30_000 * usdc,
                maxJumpBps: 200,
                maxNetNotional: 100_000 * usdc,
                winHaircutBps: 3000,
                winHaircutMinBps: 1500,
                haircutFromMoveBps: 25,
                haircutToMoveBps: 100,
                rebateBps: 1200,
                redeemBufferBps: 1000,
                stressMoveBps: 1000 // takes new positions only while a 10% move stays payable
            }),
            0,
            1 days // paramsDelay
        );
        address pauser = vm.envOr("PAUSER", address(0)); // the keeper's key: trading-hours pause only
        if (pauser != address(0)) pool.setPauser(pauser);
        // the operator's starting capital (mock USDC here); nothing opens before it
        uint256 seedAmount = vm.envOr("SEED", uint256(10_000)) * usdc;
        token.mint(msg.sender, seedAmount);
        token.approve(address(pool), seedAmount);
        pool.seed(seedAmount);
        vm.stopBroadcast();
        console.log("usdc", address(token));
        console.log("pool", address(pool));
    }
}
