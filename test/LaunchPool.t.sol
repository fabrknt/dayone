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
            0,
            1 days
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
            minNotional: 100 * USDC,
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
        (,,,, uint256 entry,,,,,,) = pool.positions(id);
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
        vm.warp(block.timestamp + 70); // rolling: the burst leaves the window within 60-70 s
        pool.settle(id);
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
        pool.proposeParams(defaultParams(), HLPriceGuard.Bounds(25, 25, 20, 150), r);
        vm.warp(block.timestamp + 1 days);
        pool.applyParams();
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
        pool.proposeParams(p, HLPriceGuard.Bounds(25, 25, 20, 150), IRefSource(address(0)));
    }

    function test_redeemPaysEquityShare() public {
        uint256 id = open(alice, true, 10_000 * USDC, 10);
        setPx(346_500); // -1%
        vm.warp(block.timestamp + 60);
        close(alice, id); // pool $1,100; alice's shares are worth her $200 rebate, the rest is locked
        assertEq(pool.equity(346.5e18), 1_100 * USDC);
        assertEq(pool.shares(address(pool)), 900 * USDC);
        uint256 aliceShares = pool.shares(alice);
        vm.prank(alice);
        uint256 got = pool.redeem(aliceShares);
        assertEq(got, 200 * USDC);
        assertEq(pool.poolBalance(), 900 * USDC);
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

    // ---- regressions for Codex round 1 ----

    /// R1-F1: an open loser on one side must not offset an open winner on the other.
    function test_r1_equityDoesNotNetOppositeSides() public {
        open(alice, true, 10_000 * USDC, 10);
        open(bob, false, 10_000 * USDC, 10);
        setPx(353_500); // long +$1,000, short -$1,000: net zero, but the long is owed $1,000
        // pool holds $100 of open fees; owed = long ($1,000 profit + $10,000 margin) + short (0)
        assertEq(pool.equity(353.5e18), 0);
        assertEq(pool.shareValuation(), 20_100 * USDC); // $100 fees + both margins: the most it can reach
    }

    /// R1-F2: the first loser's shares are worth the rebate, not the whole pool.
    function test_r1_firstLoserSharesWorthOnlyRebate() public {
        uint256 a = open(alice, true, 10_000 * USDC, 10);
        setPx(346_500);
        vm.warp(block.timestamp + 70);
        close(alice, a); // alice loses $1,000: shares worth $200
        pool.poke();
        vm.warp(block.timestamp + 70);
        uint256 b = open(bob, true, 10_000 * USDC, 10);
        setPx(343_035);
        vm.warp(block.timestamp + 70);
        close(bob, b); // bob loses $1,000 too
        uint256 aliceShares = pool.shares(alice);
        vm.prank(alice);
        uint256 got = pool.redeem(aliceShares);
        // her $200 plus her pro-rata part of later income, nowhere near bob's $1,000
        assertLt(got, 400 * USDC);
        assertGt(got, 200 * USDC);
    }

    /// R1-F3: a fee change can't reach a pending request, and only lands after the delay.
    function test_r1_feeFixedAtRequestAndParamsDelayed() public {
        vm.prank(alice);
        uint256 id = pool.requestOpen(true, 1_000 * USDC, 10); // $5 fee at 5 bp
        LaunchPool.Params memory p = defaultParams();
        p.feeBps = 1_000;
        pool.proposeParams(p, HLPriceGuard.Bounds(25, 25, 20, 150), IRefSource(address(0)));
        vm.expectRevert(LaunchPool.TooEarly.selector);
        pool.applyParams();
        vm.warp(block.timestamp + 1 days);
        pool.applyParams();
        vm.prank(alice);
        pool.cancelOpen(id);
        assertEq(usdc.balanceOf(alice), 1_000_000 * USDC); // refund = what she paid, not 10%
    }

    /// R1-F4: opens filling their lane do not block a due close.
    function test_r1_closeHasItsOwnLane() public {
        uint256 a = open(alice, true, 10_000 * USDC, 10);
        vm.warp(block.timestamp + 70);
        open(bob, true, 25_000 * USDC, 20);
        open(bob, false, 25_000 * USDC, 20); // open lane now full ($1M)
        vm.prank(alice);
        pool.requestClose(a);
        vm.warp(block.timestamp + 3);
        pool.settle(a); // the close lane is empty
        assertEq(pool.openLaneUsed(), 1_000_000 * USDC);
        assertEq(pool.closeLaneUsed(), 100_000 * USDC);
    }

    /// R1-F5: a zero redemption buffer is refused.
    function test_r1_minimumRedeemBuffer() public {
        LaunchPool.Params memory p = defaultParams();
        p.redeemBufferBps = 0;
        vm.expectRevert(LaunchPool.BadParams.selector);
        pool.proposeParams(p, HLPriceGuard.Bounds(25, 25, 20, 150), IRefSource(address(0)));
    }

    /// R1-F6: dust is refused, and cancelled or closed ids leave the active list.
    function test_r1_activeListAndMinNotional() public {
        vm.startPrank(alice);
        vm.expectRevert(LaunchPool.BadRequest.selector);
        pool.requestOpen(true, 9 * USDC, 10); // $90 < $100 minimum
        uint256 a = pool.requestOpen(true, 1_000 * USDC, 10);
        uint256 b = pool.requestOpen(true, 1_000 * USDC, 10);
        assertEq(pool.activeIds().length, 2);
        pool.cancelOpen(a);
        vm.stopPrank();
        uint256[] memory ids = pool.activeIds();
        assertEq(ids.length, 1);
        assertEq(ids[0], b);
        vm.warp(block.timestamp + 3);
        pool.settle(b);
        close(alice, b);
        assertEq(pool.activeIds().length, 0);
    }

    // ---- regressions for Codex round 2 ----

    /// R2-N1: a wash whose losing leg closes first must not give the washer most of the shares:
    /// the mint is priced at the most the pool can reach, which includes the open short's margin.
    function test_r2_firstMintCappedWhenPoolIsWorthLittle() public {
        uint256 l = open(alice, true, 10_000 * USDC, 10);
        uint256 sh = open(bob, false, 10_000 * USDC, 10);
        setPx(346_500); // alice (long) loses $1,000, bob (short) is up $1,000 and still open
        vm.warp(block.timestamp + 70);
        close(alice, l);
        uint256 locked = pool.shares(address(pool));
        assertGe(locked, pool.shares(alice) * 10); // the washer's shares are a small fraction
        close(bob, sh);
        // even owning half, the pair cannot take back more than it paid in fees and haircut
        uint256 aliceShares = pool.shares(alice);
        vm.prank(alice);
        uint256 got = pool.redeem(aliceShares);
        int256 pair = int256(usdc.balanceOf(alice) + usdc.balanceOf(bob)) - int256(2_000_000 * USDC);
        emit log_named_int("wash pair net after redeem", pair);
        emit log_named_uint("redeemed", got);
        assertLt(pair, 0);
    }

    /// R2-N2: a cap raise needs opens paused; then each open position closes at most once, the
    /// lanes drain, and the change applies.
    function test_r2_capRaiseAppliesOnceOpensPaused() public {
        uint256 id = open(alice, true, 1_000 * USDC, 10);
        LaunchPool.Params memory p = defaultParams();
        p.capWindow = 120;
        pool.proposeParams(p, HLPriceGuard.Bounds(25, 25, 20, 150), IRefSource(address(0)));
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(LaunchPool.OpensClosed.selector);
        pool.applyParams(); // opens still running
        pool.setOpensPaused(true);
        vm.prank(alice);
        vm.expectRevert(LaunchPool.OpensClosed.selector);
        pool.requestOpen(true, 1_000 * USDC, 10); // the recycling trick needs a new open
        close(alice, id); // the last thing that can touch a lane
        vm.warp(block.timestamp + 200); // past the longer window plus a slice
        pool.applyParams();
        assertEq(pool.getParams().capWindow, 120);
    }

    function test_onlyOperator() public {
        vm.prank(alice);
        vm.expectRevert(LaunchPool.NotOperator.selector);
        pool.graduate();
    }

    // ---- regressions for Codex round 3 (Codex's reruns, kept as written) ----

    function test_r3_repeatedCappedMintsNoLongerDrainReserve() public {
        address victim = address(0xCA11E);
        usdc.mint(victim, 1_000_000 * USDC);
        vm.prank(victim);
        usdc.approve(address(pool), type(uint256).max);
        uint256 victimLong = open(victim, true, 10_000 * USDC, 10);
        setPx(346_500);
        close(victim, victimLong);
        setPx(350_000);
        vm.warp(block.timestamp + 70);

        uint256 pairStart = usdc.balanceOf(alice) + usdc.balanceOf(bob);
        uint256[5] memory longs;
        uint256[5] memory shorts;
        for (uint256 i; i < 5; ++i) {
            longs[i] = open(alice, true, 25_000 * USDC, 20);
            shorts[i] = open(bob, false, 25_000 * USDC, 20);
            if (i != 4) vm.warp(block.timestamp + 70);
        }
        setPx(343_000);
        for (uint256 i; i < 5; ++i) {
            close(alice, longs[i]);
            if (i != 4) vm.warp(block.timestamp + 70);
        }
        emit log_named_uint("alice share bps after five losing closes", pool.shares(alice) * 10_000 / pool.totalShares());
        assertLt(pool.shares(alice) * 100, pool.totalShares() * 10);

        for (uint256 i; i < 5; ++i) {
            close(bob, shorts[i]);
            if (i != 4) vm.warp(block.timestamp + 70);
        }
        uint256 pairBalance = usdc.balanceOf(alice) + usdc.balanceOf(bob);
        emit log_named_uint("queued winner debt", pool.totalDebt());
        emit log_named_int("wash pair net before blocked redemption", int256(pairBalance) - int256(pairStart));
        uint256 aliceShares = pool.shares(alice);
        vm.prank(alice);
        uint256 got = pool.redeem(aliceShares);
        emit log_named_uint("alice redeemed", got);
        int256 net = int256(usdc.balanceOf(alice) + usdc.balanceOf(bob)) - int256(pairStart);
        emit log_named_int("wash pair net after redeeming everything", net);
        assertLt(net, 0);
    }

    function test_r3_maintenanceRaiseCannotLiquidateExistingPosition() public {
        uint256 id = open(alice, true, 1_000 * USDC, 10);
        LaunchPool.Params memory p = defaultParams();
        p.maintenanceBps = 5_000;
        pool.proposeParams(p, HLPriceGuard.Bounds(25, 25, 20, 150), IRefSource(address(0)));
        vm.warp(block.timestamp + 1 days);
        pool.applyParams();
        vm.expectRevert(LaunchPool.NotLiquidatable.selector);
        pool.liquidate(id);
        (address owner,,,,,,,,,,) = pool.positions(id);
        assertEq(owner, alice);
        emit log_string("existing 10x position survives delayed maintenance raise");
    }

    function test_r3_firstMintCreatesLockAtShareValuation() public {
        uint256 losingLong = open(alice, true, 100_000 * USDC, 1);
        open(bob, false, 100_000 * USDC, 1);
        setPx(346_500);
        close(alice, losingLong);
        emit log_named_uint("share valuation", pool.shareValuation());
        emit log_named_uint("alice shares", pool.shares(alice));
        emit log_named_uint("locked shares", pool.shares(address(pool)));
        assertEq(pool.shares(alice), 200 * USDC);
        assertGt(pool.shares(address(pool)), 0);
        assertEq(pool.totalShares(), pool.shareValuation());
    }

    // ---- regressions for Codex round 4 ----

    /// R4-F1: a pending open's fee is already in the contract and becomes income at settle, so a
    /// rebate minted before that settle must be priced with it (Codex PoC, adapted).
    function test_r4_pendingOpenFeeCountsInValuation() public {
        uint256 attackerLong = open(alice, true, 5 * USDC, 20);
        LaunchPool.Params memory p = defaultParams();
        p.feeBps = 1_000; // the highest fee _validate allows
        pool.proposeParams(p, HLPriceGuard.Bounds(25, 25, 20, 150), IRefSource(address(0)));
        vm.warp(block.timestamp + 1 days);
        pool.applyParams();

        address v1 = address(0xBEEF);
        address v2 = address(0xCAFE);
        for (uint256 i; i < 2; ++i) {
            address v = i == 0 ? v1 : v2;
            usdc.mint(v, 1_000_000 * USDC);
            vm.prank(v);
            usdc.approve(address(pool), type(uint256).max);
        }
        vm.prank(v1);
        uint256 p1 = pool.requestOpen(false, 25_000 * USDC, 20); // $50K fee, pending
        vm.prank(v2);
        uint256 p2 = pool.requestOpen(true, 25_000 * USDC, 20); // opposite side
        assertEq(pool.pendingOpens(), 2 * 75_000 * USDC);

        setPx(343_000);
        pool.poke();
        setPx(339_500);
        pool.liquidate(attackerLong); // $3 loss, $0.60 rebate priced with the pending fees
        vm.warp(block.timestamp + 3);
        pool.settle(p1);
        pool.settle(p2);
        assertEq(pool.pendingOpens(), 0);
        uint256 aliceShares = pool.shares(alice);
        vm.prank(alice);
        uint256 paid = pool.redeem(aliceShares);
        assertLt(paid, 3 * USDC); // less than the $3 lost; was $9,836 before the fix
    }

    /// R4-F1: cancelling a pending open takes its margin and fee back out of the valuation.
    function test_r4_cancelOpenReleasesPending() public {
        uint256 v0 = pool.shareValuation();
        vm.prank(alice);
        uint256 id = pool.requestOpen(true, 1_000 * USDC, 10);
        assertEq(pool.shareValuation(), v0 + 1_005 * USDC);
        vm.prank(alice);
        pool.cancelOpen(id);
        assertEq(pool.shareValuation(), v0);
        assertEq(pool.pendingOpens(), 0);
    }
}
