// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {HLPriceGuard} from "hl-price-guard/HLPriceGuard.sol";
import {LaunchPool, IERC20} from "../src/LaunchPool.sol";
import {MockUSDC} from "../test/Mocks.sol";

/// Local end-to-end only (keeper/e2e.sh): a mock USDC and a pool on xyz:TSLA's encodings.
/// The precompile mocks are placed by e2e.sh with anvil_setCode before this runs.
contract DeployLocal is Script {
    function run() external {
        uint256 usdc = 1e6;
        vm.startBroadcast();
        MockUSDC token = new MockUSDC();
        LaunchPool pool = new LaunchPool(
            IERC20(address(token)),
            HLPriceGuard.Asset({dex: 1, index: 1, szDecimals: 3}),
            HLPriceGuard.Bounds({maxMarkOracleBps: 25, maxMidOracleBps: 25, maxSpreadBps: 20, maxRefOracleBps: 150}),
            LaunchPool.Params({
                maxLeverage: 20,
                maintenanceBps: 250,
                feeBps: 5,
                settleDelay: 3,
                capWindow: 60,
                capPerWindow: 1_000_000 * usdc,
                minNotional: 100 * usdc,
                maxNotional: 500_000 * usdc,
                maxJumpBps: 200,
                maxNetNotional: 1_500_000 * usdc,
                winHaircutBps: 3000,
                winHaircutMinBps: 1500,
                haircutFromMoveBps: 25,
                haircutToMoveBps: 100,
                rebateBps: 1200,
                redeemBufferBps: 1000,
                // off by default: e2e.sh drives an empty pool into a queued winner on purpose
                stressMoveBps: uint16(vm.envOr("STRESS_BPS", uint256(0)))
            }),
            0,
            60 // paramsDelay
        );
        vm.stopBroadcast();
        vm.writeFile("keeper/.local.json", string.concat(
            '{"usdc":"', vm.toString(address(token)), '","pool":"', vm.toString(address(pool)), '"}'
        ));
    }
}
