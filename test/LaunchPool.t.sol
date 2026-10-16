// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {HLPrecompiles} from "hl-price-guard/HLPrecompiles.sol";
import {HLPriceGuard} from "hl-price-guard/HLPriceGuard.sol";
import {ExposureBudget} from "hl-price-guard/ExposureBudget.sol";
import {LaunchPool, IERC20, IRefSource} from "../src/LaunchPool.sol";
import {MockPrecompile, MockUSDC} from "./Mocks.sol";

contract MockRef is IRefSource {
    HLPriceGuard.Ref internal r;

    function set(uint256 price, uint256 at, uint256 maxAge) external {
        r = HLPriceGuard.Ref(price, at, maxAge);
    }

    function ref() external view returns (HLPriceGuard.Ref memory) {
        return r;
    }
}

contract LaunchPoolTest is Test {
    // xyz:TSLA encodings: 0x806/0x807 take 10001, 0x80e takes 110001. Prices in 1/1000 USD.
    uint32 constant PERP = 10001;
    uint32 constant BBO_IDX = 110001;
    uint256 constant USDC = 1e6;

    MockUSDC usdc;
    LaunchPool pool;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        address mockCode = address(new MockPrecompile());
        vm.etch(HLPrecompiles.ORACLE_PX, mockCode.code);
        vm.etch(HLPrecompiles.MARK_PX, mockCode.code);
        vm.etch(HLPrecompiles.BBO, mockCode.code);
        vm.warp(1792190822);
        setPx(350_000); // $350.000

        usdc = new MockUSDC();
        pool = new LaunchPool(
            IERC20(address(usdc)),
            HLPriceGuard.Asset({dex: 1, index: 1, szDecimals: 3}),
            HLPriceGuard.Bounds({maxMarkOracleBps: 25, maxMidOracleBps: 25, maxSpreadBps: 20, maxRefOracleBps: 150}),
            defaultParams(),
            0
        );
        for (uint256 i; i < 2; i++) {
            address u = i == 0 ? alice : bob;
            usdc.mint(u, 1_000_000 * USDC);
            vm.prank(u);
            usdc.approve(address(pool), type(uint256).max);
        }
    }

    function defaultParams() internal pure returns (LaunchPool.Params memory) {
        return LaunchPool.Params({
            maxLeverage: 20,
            maintenanceBps: 250,
            feeBps: 5,
            settleDelay: 3,
            capWindow: 60,
            capPerWindow: 1_000_000 * USDC,
            maxNotional: 500_000 * USDC,
            maxJumpBps: 200,
            maxNetNotional: 1_500_000 * USDC,
            winHaircutBps: 3000,
            rebateBps: 2000,
            redeemBufferBps: 1000
        });
    }

    /// Oracle, mark and a tight book all at `px`.
    function setPx(uint64 px) internal {
        MockPrecompile(HLPrecompiles.ORACLE_PX).set(PERP, abi.encode(px));
        MockPrecompile(HLPrecompiles.MARK_PX).set(PERP, abi.encode(px));
        MockPrecompile(HLPrecompiles.BBO).set(BBO_IDX, abi.encode(px - 5, px + 5));
    }

    function open(address u, bool long, uint256 margin, uint16 lev) internal returns (uint256 id) {
        vm.prank(u);
        id = pool.requestOpen(long, margin, lev);
        vm.warp(block.timestamp + 3);
        pool.settle(id);
    }

    function close(address u, uint256 id) internal {
        vm.prank(u);
        pool.requestClose(id);
        vm.warp(block.timestamp + 3);
        pool.settle(id);
    }

    function test_settlementWaitsForDelay() public {
        vm.prank(alice);
        uint256 id = pool.requestOpen(true, 1_000 * USDC, 10);
        vm.expectRevert(LaunchPool.TooEarly.selector);
        pool.settle(id);
        vm.warp(block.timestamp + 3);
        pool.settle(id);
        (,,,, uint256 entry,,) = pool.positions(id);
        assertEq(entry, 350e18);
    }

    function test_loserFillsPoolAndGetsShares() public {
        uint256 id = open(alice, true, 10_000 * USDC, 10); // $100K notional, fee $50
        setPx(346_500); // -1%
        vm.warp(block.timestamp + 60);
        close(alice, id); // loss $1,000 + $50 close fee
        assertEq(pool.poolBalance(), 1_100 * USDC); // both fees + loss
        assertEq(pool.shares(alice), 200 * USDC); // 20% of the $1,000 loss; fees do not count
        assertEq(usdc.balanceOf(alice), 1_000_000 * USDC - 1_100 * USDC);
        assertEq(usdc.balanceOf(address(pool)), pool.poolBalance());
    }

    function test_unpaidProfitQueuesAndIsPaidFromLaterLosses() public {
        uint256 id = open(alice, true, 10_000 * USDC, 10);
        setPx(353_500); // +1%: ($1,000 - $50 close fee) * 70% = $665 owed; the pool holds $50
        vm.warp(block.timestamp + 60);
        close(alice, id);
        assertEq(pool.totalDebt(), 615 * USDC);
        assertEq(pool.poolBalance(), 0);

        vm.warp(block.timestamp + 60);
        uint256 id2 = open(bob, true, 10_000 * USDC, 10); // bob's $50 open fee goes to alice first
        assertEq(pool.totalDebt(), 565 * USDC);
        setPx(350_000); // bob loses 1%
        vm.warp(block.timestamp + 60);
        close(bob, id2);
        assertEq(pool.totalDebt(), 0);
        assertEq(usdc.balanceOf(alice), 1_000_000 * USDC + 615 * USDC); // +665 - 50 open fee
        assertEq(usdc.balanceOf(address(pool)), pool.poolBalance()); // nothing open: tokens == books
    }

    function test_capPerMinute() public {
        open(alice, true, 25_000 * USDC, 20); // $500K
        open(bob, true, 25_000 * USDC, 20); // $1M used
        vm.prank(alice);
        uint256 id = pool.requestOpen(true, 1_000 * USDC, 10);
        vm.warp(block.timestamp + 3);
        vm.expectRevert(
            abi.encodeWithSelector(ExposureBudget.BudgetExceeded.selector, 1_000_000 * USDC, 10_000 * USDC, 1_000_000 * USDC)
        );
        pool.settle(id);
        vm.warp(block.timestamp + 60);
        pool.settle(id); // next window
    }

    /// A push that moves the book but not the oracle trips the mid-oracle bound and the close
    /// waits. (On Papertrade the oracle moved too; the cap is what stops that, test_capPerMinute.)
    function test_pushedBookBlocksSettlement() public {
        uint256 id = open(alice, true, 25_000 * USDC, 20);
        vm.prank(alice);
        pool.requestClose(id);
        vm.warp(block.timestamp + 3);
        MockPrecompile(HLPrecompiles.BBO).set(BBO_IDX, abi.encode(uint64(351_045), uint64(351_055)));
        vm.expectRevert(abi.encodeWithSelector(LaunchPool.Breach.selector, HLPriceGuard.Breach.MidOracle, 30, 25));
        pool.settle(id);
    }

    /// SKHX's shape: the deployer's oracle drops 15.6% in one update. Liquidation and
    /// settlement stop until the price comes back or the operator rearms.
    function test_oracleJumpLatchesPool() public {
        uint256 id = open(alice, true, 25_000 * USDC, 20);
        setPx(295_400);
        vm.expectRevert(abi.encodeWithSelector(LaunchPool.Breach.selector, HLPriceGuard.Breach.Jump, 1560, 200));
        pool.liquidate(id);
        setPx(349_000); // back within 200 bp of the anchor
        vm.expectRevert(LaunchPool.NotLiquidatable.selector);
        pool.liquidate(id);
    }

    function test_liquidationMintsSharesForLostMargin() public {
        uint256 id = open(alice, true, 10_000 * USDC, 20); // $200K notional, $100 open fee on top
        setPx(344_750); // -1.5%: loss $3,000, equity $7,000 > $5,000 maintenance
        vm.expectRevert(LaunchPool.NotLiquidatable.selector);
        pool.liquidate(id);
        pool.poke(); // keeper moves the latch's anchor to 344.75
        setPx(339_500); // -3%: loss $6,000, equity $4,000
        pool.liquidate(id);
        assertEq(usdc.balanceOf(alice), 1_000_000 * USDC - 100 * USDC - 6_000 * USDC);
        assertEq(pool.poolBalance(), 6_100 * USDC);
        assertEq(pool.shares(alice), 1_200 * USDC); // 20% of $6,000
        assertEq(usdc.balanceOf(address(pool)), pool.poolBalance());
    }

    /// Without a keeper, ordinary drift across quiet spells trips the latch.
    function test_withoutPokeDriftTripsLatch() public {
        uint256 id = open(alice, true, 10_000 * USDC, 20);
        setPx(339_500); // -3% since the last successful read
        vm.expectRevert(abi.encodeWithSelector(LaunchPool.Breach.selector, HLPriceGuard.Breach.Jump, 300, 200));
        pool.liquidate(id);
    }

    function test_referenceDisagreementBlocks() public {
        MockRef r = new MockRef();
        pool.setRefSource(r);
        r.set(360e18, block.timestamp, 10); // 278 bp above the oracle
        vm.prank(alice);
        uint256 id = pool.requestOpen(true, 1_000 * USDC, 10);
        vm.warp(block.timestamp + 3);
        r.set(360e18, block.timestamp, 10);
        vm.expectRevert(abi.encodeWithSelector(LaunchPool.Breach.selector, HLPriceGuard.Breach.RefOracle, 278, 150));
        pool.settle(id);
        vm.prank(alice);
        pool.cancelOpen(id);
        assertEq(usdc.balanceOf(alice), 1_000_000 * USDC);
    }

    function test_outOfHoursAndGraduation() public {
        pool.setOpensPaused(true);
        vm.prank(alice);
        vm.expectRevert(LaunchPool.OpensClosed.selector);
        pool.requestOpen(true, 1_000 * USDC, 10);
        pool.setOpensPaused(false);
        uint256 id = open(alice, true, 1_000 * USDC, 10);
        pool.graduate();
        vm.prank(bob);
        vm.expectRevert(LaunchPool.OpensClosed.selector);
        pool.requestOpen(true, 1_000 * USDC, 10);
        close(alice, id); // existing positions can still close
    }

    function test_leverageAndSizeLimits() public {
        vm.startPrank(alice);
        vm.expectRevert(LaunchPool.BadRequest.selector);
        pool.requestOpen(true, 1_000 * USDC, 21);
        vm.expectRevert(LaunchPool.BadRequest.selector);
        pool.requestOpen(true, 30_000 * USDC, 20); // $600K > $500K
        vm.stopPrank();
    }

    function test_netExposureCap() public {
        open(alice, true, 25_000 * USDC, 20); // long $500K
        vm.warp(block.timestamp + 60);
        open(bob, true, 25_000 * USDC, 20); // long $1M
        vm.warp(block.timestamp + 60);
        uint256 s1 = open(bob, false, 25_000 * USDC, 20); // a short nets it to $500K
        vm.warp(block.timestamp + 60);
        open(alice, true, 25_000 * USDC, 20); // $1M
        vm.warp(block.timestamp + 60);
        open(alice, true, 25_000 * USDC, 20); // $1.5M, at the limit
        vm.warp(block.timestamp + 60);
        vm.prank(bob);
        pool.requestClose(s1);
        vm.warp(block.timestamp + 3);
        pool.settle(s1); // closing the short is allowed even though net goes to $2M
        vm.prank(alice);
        uint256 id = pool.requestOpen(true, 1_000 * USDC, 10);
        vm.warp(block.timestamp + 3);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchPool.NetExposureExceeded.selector, 2_010_000 * USDC, 1_500_000 * USDC)
        );
        pool.settle(id);
    }

    /// Two own accounts, one long and one short of the same size: one loses what the other wins.
    /// The rebate dilutes the other shareholders, while the haircut and fees go to all of them.
    /// With rebate (20%) below the haircut (30%) and outsiders holding most shares, the pair loses.
    function test_washTradingLoses() public {
        address carol = address(0xCA201);
        usdc.mint(carol, 100_000 * USDC);
        vm.prank(carol);
        usdc.approve(address(pool), type(uint256).max);
        uint256 c = open(carol, true, 25_000 * USDC, 20); // carol loses 2% of $500K
        setPx(343_000);
        vm.warp(block.timestamp + 60);
        close(carol, c);
        pool.poke();

        uint256 before = usdc.balanceOf(alice) + usdc.balanceOf(bob);
        vm.warp(block.timestamp + 60);
        uint256 l = open(alice, true, 10_000 * USDC, 10);
        uint256 sh = open(bob, false, 10_000 * USDC, 10);
        setPx(346_430); // +1%
        vm.warp(block.timestamp + 60);
        close(bob, sh);
        close(alice, l);
        uint256 eq = pool.equity(346.43e18);
        uint256 pairShareValue = pool.shares(bob) * eq / pool.totalShares();
        int256 pair = int256(usdc.balanceOf(alice) + usdc.balanceOf(bob) + pairShareValue) - int256(before);
        emit log_named_int("pair net (USDC units)", pair);
        emit log_named_uint("pair share value", pairShareValue);
        assertLt(pair, 0);
        assertLt(pool.shares(bob) * 10 / pool.totalShares(), 1); // outsiders hold over 90%
    }

    function test_rebateMustBeBelowHaircut() public {
        LaunchPool.Params memory p = defaultParams();
        p.rebateBps = p.winHaircutBps;
        vm.expectRevert(LaunchPool.RebateNotBelowHaircut.selector);
        pool.setParams(p, HLPriceGuard.Bounds(25, 25, 20, 150));
    }

    function test_redeemPaysEquityShare() public {
        uint256 id = open(alice, true, 10_000 * USDC, 10);
        setPx(346_500); // -1%
        vm.warp(block.timestamp + 60);
        close(alice, id); // pool $1,100, alice holds all shares, worth her $200 rebate... and more
        assertEq(pool.equity(346.5e18), 1_100 * USDC);
        uint256 aliceShares = pool.shares(alice);
        vm.prank(alice);
        uint256 got = pool.redeem(aliceShares);
        assertEq(got, 1_100 * USDC); // sole holder: the whole pool, nothing open, no reserve
        assertEq(pool.poolBalance(), 0);
    }

    function test_redeemBlockedByDebtAndOpenProfit() public {
        // bob loses first so the pool has money and bob has shares
        uint256 b1 = open(bob, true, 10_000 * USDC, 10);
        setPx(346_500);
        vm.warp(block.timestamp + 60);
        close(bob, b1); // pool $1,100
        // alice opens long; price recovers 2%: alice's open profit is owed by the pool
        vm.warp(block.timestamp + 60);
        open(alice, true, 25_000 * USDC, 20); // $500K at 346.5
        setPx(349_000); // +0.72%: alice up ~$3,608 > pool balance
        pool.poke();
        assertEq(pool.equity(349e18), 0);
        uint256 bobShares = pool.shares(bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LaunchPool.RedeemBlocked.selector, 0, 0));
        pool.redeem(bobShares);
    }

    function test_onlyOperator() public {
        vm.prank(alice);
        vm.expectRevert(LaunchPool.NotOperator.selector);
        pool.graduate();
    }
}
