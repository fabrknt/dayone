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
            winHaircutMinBps: 1500,
            haircutFromMoveBps: 25,
            haircutToMoveBps: 100,
            rebateBps: 1200,
            redeemBufferBps: 1000,
            stressMoveBps: 0 // the backing check has its own tests below
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
        (,,,, uint256 entry,,,,,,,) = pool.positions(id);
        assertEq(entry, 350e18);
    }

    function test_loserFillsPoolAndGetsShares() public {
        uint256 id = open(alice, true, 10_000 * USDC, 10); // $100K notional, fee $50
        setPx(346_500); // -1%
        vm.warp(block.timestamp + 60);
        close(alice, id); // loss $1,000 + $50 close fee
        assertEq(pool.poolBalance(), 1_100 * USDC); // both fees + loss
        assertEq(pool.shares(alice), 120 * USDC); // 12% of the $1,000 loss; fees do not count
        assertEq(usdc.balanceOf(alice), 1_000_000 * USDC - 1_100 * USDC);
        assertEq(usdc.balanceOf(address(pool)), pool.poolBalance());
    }

    function test_unpaidProfitQueuesAndIsPaidFromLaterLosses() public {
        uint256 id = open(alice, true, 10_000 * USDC, 10);
        setPx(353_500); // +1%, at the curve's floor: ($1,000 - $50 close fee) * 85% = $807.50 owed; the pool holds $50
        vm.warp(block.timestamp + 60);
        close(alice, id);
        assertEq(pool.totalDebt(), 757.5e6);
        assertEq(pool.poolBalance(), 0);
        (address to, uint64 at,,,) = pool.debts(0);
        assertEq(to, alice);
        assertEq(at, block.timestamp); // when it was queued

        vm.warp(block.timestamp + 60);
        uint256 id2 = open(bob, true, 10_000 * USDC, 10); // bob's $50 open fee goes to alice first
        assertEq(pool.totalDebt(), 707.5e6);
        setPx(350_000); // bob loses 1%
        vm.warp(block.timestamp + 60);
        close(bob, id2);
        assertEq(pool.totalDebt(), 0);
        assertEq(pool.claimable(0), 757.5e6);
        pool.claim(0); // anyone may send it; it goes to alice
        assertEq(usdc.balanceOf(alice), 1_000_000 * USDC + 757.5e6); // +807.50 - 50 open fee
        assertEq(usdc.balanceOf(address(pool)), pool.poolBalance()); // nothing open: tokens == books
        vm.expectRevert(LaunchPool.BadRequest.selector);
        pool.claim(0); // nothing left
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
        assertEq(pool.shares(alice), 720 * USDC); // 12% of $6,000
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
    /// With the rebate (12%) below the haircut (30% falling to 15% at a 1% move) and outsiders
    /// holding most shares, the pair loses. This pair moves 1%, so it pays the curve's floor.
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
        p.rebateBps = p.winHaircutMinBps; // below the top of the curve, but not below its floor
        vm.expectRevert(LaunchPool.RebateNotBelowHaircut.selector);
        pool.proposeParams(p, HLPriceGuard.Bounds(25, 25, 20, 150), IRefSource(address(0)));
    }

    function test_redeemPaysEquityShare() public {
        uint256 id = open(alice, true, 10_000 * USDC, 10);
        setPx(346_500); // -1%
        vm.warp(block.timestamp + 60);
        close(alice, id); // pool $1,100; alice's shares are worth her $120 rebate, the rest is locked
        assertEq(pool.equity(346.5e18), 1_100 * USDC);
        assertEq(pool.shares(address(pool)), 980 * USDC);
        uint256 aliceShares = pool.shares(alice);
        vm.prank(alice);
        uint256 got = pool.redeem(aliceShares);
        assertEq(got, 120 * USDC);
        assertEq(pool.poolBalance(), 980 * USDC);
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

    /// The pauser (the keeper's key) can set and clear the trading-hours pause and nothing else.
    function test_pauserOnlyTogglesHours() public {
        address keeper = address(0x6EE9E2);
        pool.setPauser(keeper);
        vm.startPrank(keeper);
        pool.setHoursPaused(true);
        assertTrue(pool.opensPaused());
        pool.setHoursPaused(false);
        assertFalse(pool.opensPaused());
        vm.expectRevert(LaunchPool.NotOperator.selector);
        pool.setOpensPaused(true);
        vm.expectRevert(LaunchPool.NotOperator.selector);
        pool.graduate();
        vm.expectRevert(LaunchPool.NotOperator.selector);
        pool.rearm(350 ether);
        vm.expectRevert(LaunchPool.NotOperator.selector);
        pool.proposeParams(defaultParams(), HLPriceGuard.Bounds(25, 25, 20, 150), IRefSource(address(0)));
        vm.expectRevert(LaunchPool.NotOperator.selector);
        pool.setPauser(keeper);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(LaunchPool.NotPauser.selector);
        pool.setHoursPaused(true);

        pool.setPauser(address(0)); // removed: the old key is refused
        vm.prank(keeper);
        vm.expectRevert(LaunchPool.NotPauser.selector);
        pool.setHoursPaused(true);
    }

    /// The keeper reopening at market open does not clear the operator's own pause.
    function test_operatorPauseOutlivesHoursReopen() public {
        address keeper = address(0x6EE9E2);
        pool.setPauser(keeper);
        vm.prank(keeper);
        pool.setHoursPaused(true);
        pool.setOpensPaused(true); // operator emergency
        vm.prank(keeper);
        pool.setHoursPaused(false); // market opens
        assertTrue(pool.opensPaused());
        vm.prank(alice);
        vm.expectRevert(LaunchPool.OpensClosed.selector);
        pool.requestOpen(true, 1_000 * USDC, 10);
        pool.setOpensPaused(false);
        assertFalse(pool.opensPaused());
        open(alice, true, 1_000 * USDC, 10);
    }

    /// The hours pause alone also satisfies applyParams' pause requirement for a cap raise.
    function test_hoursPauseCountsForCapRaise() public {
        LaunchPool.Params memory p = defaultParams();
        p.capWindow = 120;
        pool.proposeParams(p, HLPriceGuard.Bounds(25, 25, 20, 150), IRefSource(address(0)));
        vm.warp(block.timestamp + 1 days);
        pool.setHoursPaused(true); // the operator may set it too
        pool.applyParams();
        assertEq(pool.getParams().capWindow, 120);
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
        (address owner,,,,,,,,,,,) = pool.positions(id);
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
        assertEq(pool.shares(alice), 120 * USDC); // 12% of $1,000
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

    // ---- the win haircut falls with the size of the move ----

    /// 30% up to a 0.25% move, 15% from 1%, linear in between; measured on the price, so
    /// leverage does not change the rate.
    function test_haircutCurve() public {
        uint256 a = open(alice, true, 1_000 * USDC, 1);
        uint256 b = open(bob, true, 1_000 * USDC, 20);
        assertEq(pool.haircutAt(a, 350.35e18), 3000); // +10 bp
        assertEq(pool.haircutAt(a, 352.1875e18), 2250); // +62.5 bp: halfway
        assertEq(pool.haircutAt(a, 353.5e18), 1500); // +100 bp
        assertEq(pool.haircutAt(a, 357e18), 1500); // +200 bp: the floor
        assertEq(pool.haircutAt(a, 347.8125e18), 2250); // the same for a move down
        assertEq(pool.haircutAt(b, 352.1875e18), 2250); // 20x pays what 1x pays
    }

    /// The curve is part of the params: each position keeps the one in force at its request.
    function test_haircutCurveFixedAtRequest() public {
        uint256 id = open(alice, true, 10_000 * USDC, 10);
        LaunchPool.Params memory p = defaultParams();
        p.winHaircutBps = 2000;
        p.winHaircutMinBps = 1300;
        pool.proposeParams(p, HLPriceGuard.Bounds(25, 25, 20, 150), IRefSource(address(0)));
        vm.warp(block.timestamp + 1 days);
        pool.applyParams();
        assertEq(pool.haircutAt(id, 357e18), 1500); // still the old floor
        assertEq(pool.haircutAt(id, 350.35e18), 3000); // and the old top
        uint256 id2 = open(bob, true, 10_000 * USDC, 10);
        assertEq(pool.haircutAt(id2, 357e18), 1300);
    }

    function test_haircutCurveValidation() public {
        LaunchPool.Params memory p = defaultParams();
        p.winHaircutMinBps = p.winHaircutBps + 1; // a curve that rises
        vm.expectRevert(LaunchPool.BadParams.selector);
        pool.proposeParams(p, HLPriceGuard.Bounds(25, 25, 20, 150), IRefSource(address(0)));
        p = defaultParams();
        p.haircutToMoveBps = p.haircutFromMoveBps;
        vm.expectRevert(LaunchPool.BadParams.selector);
        pool.proposeParams(p, HLPriceGuard.Bounds(25, 25, 20, 150), IRefSource(address(0)));
    }

    /// Washing aimed at the floor: the rebate set one bp under the floor, a 4% move so the winning
    /// leg pays only the floor, high leverage. The pair still loses.
    function test_washAtCurveFloorLoses() public {
        LaunchPool.Params memory p = defaultParams();
        p.rebateBps = p.winHaircutMinBps - 1; // 14.99% against a 15% floor
        pool.proposeParams(p, HLPriceGuard.Bounds(25, 25, 20, 150), IRefSource(address(0)));
        vm.warp(block.timestamp + 1 days);
        pool.applyParams();

        address carol = address(0xCA201);
        usdc.mint(carol, 100_000 * USDC);
        vm.prank(carol);
        usdc.approve(address(pool), type(uint256).max);
        uint256 c = open(carol, true, 25_000 * USDC, 20); // outsiders own most shares first
        setPx(343_000);
        vm.warp(block.timestamp + 60);
        close(carol, c);
        pool.poke();

        uint256 before = usdc.balanceOf(alice) + usdc.balanceOf(bob);
        vm.warp(block.timestamp + 60);
        uint256 l = open(alice, true, 1_000 * USDC, 20);
        uint256 sh = open(bob, false, 1_000 * USDC, 20);
        setPx(349_860); // +2%
        pool.poke();
        setPx(356_720); // +4% from 343
        assertEq(pool.haircutAt(l, 356.72e18), 1500);
        vm.warp(block.timestamp + 60);
        close(bob, sh); // loses $800 of $1,000 margin
        close(alice, l); // wins $800, pays 15% of it
        uint256 eq = pool.equity(356.72e18);
        uint256 pairShareValue = (pool.shares(alice) + pool.shares(bob)) * eq / pool.totalShares();
        int256 pair = int256(usdc.balanceOf(alice) + usdc.balanceOf(bob) + pairShareValue) - int256(before);
        emit log_named_int("pair net at the floor (USDC units)", pair);
        assertLt(pair, 0);
    }

    /// Item 5: with the falling haircut, what the pool is left with after everything closes still
    /// sits between the low end (equity before the closes) and the high end (shareValuation).
    function testFuzz_boundsHoldWithHaircutCurve(uint16 levL, uint16 levS, uint16 moveBps, bool up) public {
        levL = uint16(bound(levL, 1, 20));
        levS = uint16(bound(levS, 1, 20));
        moveBps = uint16(bound(moveBps, 0, 390)); // two latch steps of under 2% each
        uint256 l = open(alice, true, 2_000 * USDC, levL);
        uint256 sh = open(bob, false, 3_000 * USDC, levS);
        uint256 half = uint256(moveBps) / 2;
        uint64 p1 = uint64(up ? 350_000 * (10_000 + half) / 10_000 : 350_000 * (10_000 - half) / 10_000);
        uint64 p2 = uint64(up ? 350_000 * (10_000 + uint256(moveBps)) / 10_000 : 350_000 * (10_000 - uint256(moveBps)) / 10_000);
        setPx(p1);
        pool.poke();
        setPx(p2);
        uint256 price = uint256(p2) * 1e15;
        uint256 low = pool.equity(price);
        uint256 high = pool.shareValuation();
        vm.warp(block.timestamp + 60);
        (address ownerL,,,,,,,,,,,) = pool.positions(l);
        if (ownerL != address(0)) {
            try pool.liquidate(l) {} catch { close(alice, l); }
        }
        (address ownerS,,,,,,,,,,,) = pool.positions(sh);
        if (ownerS != address(0)) {
            try pool.liquidate(sh) {} catch { close(bob, sh); }
        }
        uint256 after_ = pool.poolBalance() > pool.totalDebt() ? pool.poolBalance() - pool.totalDebt() : 0;
        assertGe(after_ + 1, low); // rounding: at most one unit
        assertLe(after_, high);
    }

    // ---- regressions for Codex round 7 ----

    /// R7-F1: open both sides under the 30% -> 15% curve, then a valid change to a flat 30% curve
    /// with a 29.99% rebate is applied. The old winner still pays the old floor (15%); the old
    /// loser must get the old rebate (12%), not the new one, or the pair profits.
    function test_r7_rebateFixedAtRequest() public {
        address carol = address(0xCA201);
        usdc.mint(carol, 100_000 * USDC);
        vm.prank(carol);
        usdc.approve(address(pool), type(uint256).max);
        uint256 c = open(carol, true, 25_000 * USDC, 20); // unrelated holders own most of the pool
        setPx(343_000);
        vm.warp(block.timestamp + 60);
        close(carol, c);
        pool.poke();

        uint256 before = usdc.balanceOf(alice) + usdc.balanceOf(bob);
        vm.warp(block.timestamp + 60);
        uint256 l = open(alice, true, 1_000 * USDC, 20);
        uint256 sh = open(bob, false, 1_000 * USDC, 20);
        LaunchPool.Params memory p = defaultParams();
        (p.winHaircutBps, p.winHaircutMinBps, p.rebateBps) = (3000, 3000, 2999);
        pool.proposeParams(p, HLPriceGuard.Bounds(25, 25, 20, 150), IRefSource(address(0)));
        vm.warp(block.timestamp + 1 days);
        pool.applyParams();

        setPx(349_860);
        pool.poke();
        setPx(356_720); // +4%: the old winner pays its own floor, 15%
        assertEq(pool.haircutAt(l, 356.72e18), 1500);
        vm.warp(block.timestamp + 60);
        uint256 sharesBefore = pool.shares(bob);
        close(bob, sh); // loses $800 + $1.60 fee
        uint256 minted = pool.shares(bob) - sharesBefore;
        close(alice, l);
        uint256 eq = pool.equity(356.72e18);
        uint256 pairShareValue = (pool.shares(alice) + pool.shares(bob)) * eq / pool.totalShares();
        int256 pair = int256(usdc.balanceOf(alice) + usdc.balanceOf(bob) + pairShareValue) - int256(before);
        emit log_named_uint("shares minted to the old loser", minted);
        emit log_named_int("pair net (USDC units)", pair);
        assertLt(pair, 0);
    }

    // ---- paths the earlier tests left out (coverage, 10-19) ----

    /// A real gap trips the latch until the operator rearms at the new price.
    function test_rearmAfterGap() public {
        uint256 id = open(alice, true, 1_000 * USDC, 10);
        setPx(357_500); // +2.14% in one step, past the 2% latch
        vm.expectRevert(abi.encodeWithSelector(LaunchPool.Breach.selector, HLPriceGuard.Breach.Jump, 215, 200));
        pool.poke();
        pool.rearm(357.5e18);
        (uint256 anchor,) = pool.latch();
        assertEq(anchor, 357.5e18);
        pool.poke();
        vm.warp(block.timestamp + 60);
        close(alice, id); // settles at the new price
        assertGt(usdc.balanceOf(alice), 1_000_000 * USDC - 10 * USDC);
    }

    /// The price runs through the liquidation level before anyone liquidates and the close
    /// settles: the loss is capped at the margin and the trader gets nothing back.
    function test_closePastLiquidationLosesOnlyMargin() public {
        uint256 id = open(alice, true, 1_000 * USDC, 20); // $20K notional, $10 open fee
        vm.prank(alice);
        pool.requestClose(id);
        setPx(343_000);
        pool.poke();
        setPx(336_140);
        pool.poke();
        setPx(330_000); // -5.71%: loss $1,142.86 + $10 close fee > $1,000 margin
        vm.warp(block.timestamp + 3);
        pool.settle(id);
        assertEq(usdc.balanceOf(alice), 1_000_000 * USDC - 1_010 * USDC);
        assertEq(pool.poolBalance(), 1_010 * USDC);
        assertEq(pool.shares(alice), 118.8e6); // 12% of ($1,000 - $10 fee)
        assertEq(usdc.balanceOf(address(pool)), pool.poolBalance());
    }

    /// A real crash trips the latch and liquidation waits with everything else. The pool is the
    /// only counterparty and a loser loses at most its margin, so waiting costs the pool only the
    /// income it would have had: nothing is owed for the loss past the margin, whichever way the
    /// price goes next.
    function test_liquidationWaitingOnLatchOwesNothing() public {
        uint256 id = open(alice, true, 1_000 * USDC, 20); // $20K notional, liquidated near -3.75%
        uint256 before = pool.poolBalance(); // the $10 open fee
        setPx(245_000); // -30% in one update: the loss would be $6,000 on $1,000 margin
        vm.expectRevert(abi.encodeWithSelector(LaunchPool.Breach.selector, HLPriceGuard.Breach.Jump, 3000, 200));
        pool.liquidate(id);
        assertEq(pool.equity(245e18), before); // the open loss is not the pool's to pay
        assertEq(pool.totalDebt(), 0);

        uint256 snap = vm.snapshotState();
        // the operator rearms at the crash price: liquidation takes exactly the margin
        pool.rearm(245e18);
        pool.liquidate(id);
        assertEq(pool.poolBalance(), before + 1_000 * USDC);
        assertEq(usdc.balanceOf(alice), 1_000_000 * USDC - 1_010 * USDC);

        vm.revertToState(snap);
        // or the price comes back first: the trader escapes, the pool still owes nothing
        setPx(349_000);
        vm.expectRevert(LaunchPool.NotLiquidatable.selector);
        pool.liquidate(id);
        close(alice, id);
        assertGt(pool.poolBalance(), before);
        assertEq(pool.totalDebt(), 0);
        assertEq(usdc.balanceOf(address(pool)), pool.poolBalance());
    }

    /// Codex round 10: the arithmetic limits. Prices beyond HL's scale are refused at deploy;
    /// fees round up; a mint that would overflow the share count rebases every holding first.
    function test_r10_arithmeticLimits() public {
        HLPriceGuard.Bounds memory b = HLPriceGuard.Bounds(25, 25, 20, 150);
        vm.expectRevert(LaunchPool.BadParams.selector);
        new LaunchPool(IERC20(address(usdc)), HLPriceGuard.Asset(1, 1, 7), b, defaultParams(), 0, 1 days);
        new LaunchPool(IERC20(address(usdc)), HLPriceGuard.Asset(1, 1, 6), b, defaultParams(), 0, 1 days);

        // $100.0001 notional at 5 bp is $0.05000005 of fee: charged as 50,001 base units
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        pool.requestOpen(true, 100_000_100, 1);
        assertEq(before - usdc.balanceOf(alice), 100_000_100 + 50_001);

        uint256 id = open(alice, true, 1_000 * USDC, 10);
        setPx(349_000);
        close(alice, id); // a small loss: the first mint
        assertGt(pool.totalShares(), 0);
        vm.store(address(pool), bytes32(uint256(22)), bytes32(pool.MAX_SHARES() - 1)); // totalShares
        id = open(bob, true, 1_000 * USDC, 10);
        setPx(344_750);
        pool.poke();
        setPx(340_000);
        uint256 balance = pool.poolBalance();
        uint256 bobBefore = usdc.balanceOf(bob);
        close(bob, id); // a loss from 349 to 340: the rebate would overflow MAX_SHARES
        uint256 loss = 1_000 * USDC - (usdc.balanceOf(bob) - bobBefore); // includes the $5 close fee
        uint256 bobShares = pool.shares(bob);
        assertGt(bobShares, 0);
        // every holding was divided by 2^64 first, and bob's rebate is still paid in shares
        assertEq(pool.shareEpoch(), 1);
        assertEq(pool.totalShares(), 2 ** 64 + bobShares);
        uint256 value = (loss - 5 * USDC) * 1200 / 10_000;
        assertEq(bobShares, value * 2 ** 64 / (pool.shareValuation() - value));
        assertEq(pool.shares(alice), 0); // her few real shares round down to nothing: dust
        assertLe(pool.shares(alice) + pool.shares(bob) + pool.shares(address(pool)), pool.totalShares());
        assertEq(pool.poolBalance(), balance + loss);
        assertEq(usdc.balanceOf(address(pool)), pool.poolBalance() + pool.pendingOpens()); // alice's open still pending
    }

    function _backedPool() internal returns (LaunchPool p) {
        p = _backedPool(1000);
    }

    function _backedPool(uint16 redeemBufferBps) internal returns (LaunchPool p) {
        LaunchPool.Params memory params = defaultParams();
        params.stressMoveBps = 1000;
        params.redeemBufferBps = redeemBufferBps;
        p = new LaunchPool(
            IERC20(address(usdc)), HLPriceGuard.Asset(1, 1, 3), HLPriceGuard.Bounds(25, 25, 20, 150), params, 0, 1 days
        );
        for (uint256 i; i < 2; i++) {
            vm.prank(i == 0 ? alice : bob);
            usdc.approve(address(p), type(uint256).max);
        }
        usdc.mint(address(this), 100_000 * USDC);
        usdc.approve(address(p), type(uint256).max);
    }

    function _requestAndWait(LaunchPool p, address u, bool long, uint256 margin, uint16 lev) internal returns (uint256 id) {
        vm.prank(u);
        id = p.requestOpen(long, margin, lev);
        vm.warp(block.timestamp + 3);
    }

    /// An empty pool takes nothing; a seeded one takes positions while a 10% move either way
    /// stays payable from its balance.
    function test_backingLimitsOpensToTheBalance() public {
        LaunchPool p = _backedPool();
        uint256 id = _requestAndWait(p, alice, true, 1_000 * USDC, 20);
        // $20K long: +10% owes $2,000; the balance is the $10 fee
        vm.expectPartialRevert(LaunchPool.BeyondBacking.selector);
        p.settle(id);
        vm.prank(alice);
        p.cancelOpen(id);

        p.seed(10_000 * USDC);
        assertEq(p.shares(address(this)), 10_000 * USDC); // the first shares: 1 per base unit
        id = _requestAndWait(p, alice, true, 1_000 * USDC, 20);
        p.settle(id);
        (uint256 up, uint256 down) = p.stressOwed(350e18);
        assertApproxEqAbs(up, 2_000 * USDC, 1_000); // units and the stressed price round up
        assertEq(down, 0); // longs lose on the way down
        // another $100K long: +10% would owe $12,000 > $10,060
        id = _requestAndWait(p, bob, true, 5_000 * USDC, 20);
        vm.expectPartialRevert(LaunchPool.BeyondBacking.selector);
        p.settle(id);
        vm.prank(bob);
        p.cancelOpen(id);
        // $60K more fits: +10% owes $8,000
        id = _requestAndWait(p, bob, true, 3_000 * USDC, 20);
        p.settle(id);
        // a short adds its own side's bound only on the way down
        id = _requestAndWait(p, bob, false, 1_000 * USDC, 20);
        p.settle(id);
        (up, down) = p.stressOwed(350e18);
        assertApproxEqAbs(up, 8_000 * USDC, 1_000);
        assertApproxEqAbs(down, 2_000 * USDC, 1_000);
    }

    /// Codex round 11: a long far past its margin must not offset another long's win. The bound
    /// treats every long as entered at the lowest long entry, so the old cheap long counts in full.
    function test_backingDoesNotNetOverlosses() public {
        LaunchPool p = _backedPool();
        p.seed(10_000 * USDC);
        uint256 cheap = _requestAndWait(p, alice, true, 100 * USDC, 20); // $2K at $350
        p.settle(cheap);
        for (uint256 i = 1; i <= 15; i++) { // up to $455 in latch-sized steps
            setPx(uint64(350_000 + 7_000 * i));
            p.poke();
        }
        uint256 dear = _requestAndWait(p, bob, true, 100 * USDC, 20); // $2K at $455
        p.settle(dear);
        assertEq(p.longEntryMin(), 350e18);
        // every long counted from $350: +10% from $455 is about (500.5 - 350) * all units
        (uint256 up,) = p.stressOwed(455e18);
        uint256 units = p.longUnits();
        assertGe(up, units * (500.5e18 - 350e18) / 1e18);
        // closing the cheap one leaves the bound where it was until a refresh
        vm.prank(alice);
        p.requestClose(cheap);
        vm.warp(block.timestamp + 3);
        p.settle(cheap);
        assertEq(p.longEntryMin(), 350e18);
        p.refreshEntryBounds();
        assertEq(p.longEntryMin(), 455e18);
    }

    /// From the lend window (10-19): two longs on one side, a crash trips the latch, the operator
    /// rearms, and a holder redeems before the long past its margin is liquidated. The redemption
    /// must leave enough for the other long's win: the overloss does not offset it.
    function test_redeemAfterRearmKeepsTheSameSideWin() public {
        LaunchPool p = _backedPool(100); // the smallest buffer, so it cannot hide a netting bound
        p.seed(50_000 * USDC);
        uint256 cheap = _requestAndWait(p, alice, true, 100 * USDC, 20); // $2K at $350
        p.settle(cheap);
        for (uint256 i = 1; i <= 15; i++) { // up to $455 in latch-sized steps
            setPx(uint64(350_000 + 7_000 * i));
            p.poke();
        }
        uint256 dear = _requestAndWait(p, bob, true, 1_000 * USDC, 20); // $20K at $455
        p.settle(dear);

        setPx(420_000); // -7.7% in one update: the latch trips
        vm.expectPartialRevert(LaunchPool.Breach.selector);
        p.liquidate(dear);
        p.rearm(420e18);
        // cheap is up 20%: $400, $340 after the 15% haircut. dear is down 7.7% at 20x: $1,538 on
        // $1,000 of margin. Netting the $538 overloss against the win would reserve nothing for
        // it, and the 1% buffer holds back only $220.
        uint256 eq = p.equity(420e18);
        uint256 hold = p.minReserve() + (p.longOI() - p.shortOI()) / 100;
        p.redeem(p.totalShares() * (eq - hold) / eq);

        // the winner closes before the loser is liquidated, so its margin cannot help
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        p.requestClose(cheap);
        vm.warp(block.timestamp + 3);
        p.settle(cheap);
        assertEq(p.totalDebt(), 0); // the win was paid in full from what the redemption left
        p.liquidate(dear);
        assertGt(usdc.balanceOf(alice) - aliceBefore, 430 * USDC); // $100 margin + $340 - the $1 close fee
        assertEq(usdc.balanceOf(address(p)), p.poolBalance() + p.unclaimed());
    }

    /// Codex round 12: a new long at a new low entry re-prices the old longs. The page's room
    /// (web/room.ts, checked in web/room.test.mjs on this state) says about $23,576.
    function test_r12_roomMatchesBacking() public {
        LaunchPool p = _backedPool();
        p.seed(10_000 * USDC);
        for (uint256 i = 1; i <= 15; i++) {
            setPx(uint64(350_000 + 7_000 * i));
            p.poke();
        }
        p.settle(_requestAndWait(p, alice, true, 10_000 * USDC, 10)); // $100K at $455
        for (uint256 i = 1; i <= 15; i++) {
            setPx(uint64(455_000 - 7_000 * i));
            p.poke();
        }
        assertEq(p.poolBalance(), 10_050 * USDC);
        assertEq(p.longUnits(), 219_780_220);
        uint256 snap = vm.snapshotState();
        p.settle(_requestAndWait(p, bob, true, 2_357 * USDC, 10)); // $23,570 settles
        vm.revertToState(snap);
        uint256 id = _requestAndWait(p, bob, true, 2_380 * USDC, 10); // $23,800 does not
        vm.expectPartialRevert(LaunchPool.BeyondBacking.selector);
        p.settle(id);
    }

    /// Off only on a local chain; elsewhere at least MIN_STRESS_BPS, at deploy and on proposal.
    function test_stressFloorOutsideLocalChains() public {
        LaunchPool p = _backedPool();
        vm.chainId(998);
        LaunchPool.Params memory params = p.getParams();
        params.stressMoveBps = 0;
        vm.expectRevert(LaunchPool.BadParams.selector);
        p.proposeParams(params, HLPriceGuard.Bounds(25, 25, 20, 150), IRefSource(address(0)));
        params.stressMoveBps = 499;
        vm.expectRevert(LaunchPool.BadParams.selector);
        p.proposeParams(params, HLPriceGuard.Bounds(25, 25, 20, 150), IRefSource(address(0)));
        params.stressMoveBps = 500;
        p.proposeParams(params, HLPriceGuard.Bounds(25, 25, 20, 150), IRefSource(address(0)));
        vm.expectRevert(LaunchPool.BadParams.selector);
        new LaunchPool(IERC20(address(usdc)), HLPriceGuard.Asset(1, 1, 3), HLPriceGuard.Bounds(25, 25, 20, 150), defaultParams(), 0, 1 days);
    }

    /// While a winner is queued nothing new opens: requests are refused and a pending open
    /// cannot settle. Seeding pays the queue first and reopens.
    function test_queuedWinnerStopsOpensUntilPaid() public {
        LaunchPool p = _backedPool();
        p.seed(1_000 * USDC);
        uint256 id = _requestAndWait(p, alice, true, 300 * USDC, 20); // $6K: +10% owes $600 + $300
        p.settle(id);
        uint256 pending = _requestAndWait(p, bob, true, 100 * USDC, 2);
        // the price runs up 30% in steps the latch accepts; alice closes with more than the pool has
        for (uint256 i = 1; i <= 15; i++) {
            setPx(uint64(350_000 + 7_000 * i));
            p.poke();
        }
        vm.prank(alice);
        p.requestClose(id);
        vm.warp(block.timestamp + 3);
        p.settle(id);
        assertGt(p.totalDebt(), 0);
        vm.expectPartialRevert(LaunchPool.BeyondBacking.selector); // its fee pays a little of the queue first
        p.settle(pending);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LaunchPool.BeyondBacking.selector, p.totalDebt(), 0));
        p.requestOpen(true, 100 * USDC, 2);

        uint256 owed = p.totalDebt();
        uint256 sharesBefore = p.shares(address(this));
        p.seed(owed + 1_000 * USDC);
        assertEq(p.totalDebt(), 0);
        assertEq(p.claimable(0), owed);
        assertGt(p.shares(address(this)), sharesBefore);
        p.settle(pending); // reopened
    }

    function test_seedIsOperatorOnly() public {
        LaunchPool p = _backedPool();
        vm.prank(alice);
        vm.expectRevert(LaunchPool.NotOperator.selector);
        p.seed(1_000 * USDC);
        vm.expectRevert(LaunchPool.BadRequest.selector);
        p.seed(0);
    }

    function test_refusesOutOfTurnCalls() public {
        vm.prank(alice);
        uint256 pending = pool.requestOpen(true, 1_000 * USDC, 10);
        vm.prank(bob);
        vm.expectRevert(LaunchPool.NotOwner.selector);
        pool.cancelOpen(pending);
        vm.prank(bob);
        vm.expectRevert(LaunchPool.NotOwner.selector);
        pool.requestClose(pending);
        vm.prank(alice);
        vm.expectRevert(LaunchPool.BadRequest.selector);
        pool.requestClose(pending); // not open yet
        vm.expectRevert(LaunchPool.BadRequest.selector);
        pool.liquidate(pending);
        vm.expectRevert(LaunchPool.BadRequest.selector);
        pool.settle(999); // no such position

        // paused after the request: the open cannot settle, and the trader can take the money back
        pool.setOpensPaused(true);
        vm.warp(block.timestamp + 3);
        vm.expectRevert(LaunchPool.OpensClosed.selector);
        pool.settle(pending);
        vm.prank(alice);
        pool.cancelOpen(pending);
        assertEq(usdc.balanceOf(alice), 1_000_000 * USDC);
        assertEq(pool.pendingOpens(), 0);
        pool.setOpensPaused(false);

        uint256 id = open(alice, true, 1_000 * USDC, 10);
        vm.prank(alice);
        vm.expectRevert(LaunchPool.BadRequest.selector);
        pool.cancelOpen(id); // already open
        vm.expectRevert(LaunchPool.BadRequest.selector);
        pool.settle(id); // open, no close requested
        vm.prank(alice);
        pool.requestClose(id);
        vm.prank(alice);
        vm.expectRevert(LaunchPool.BadRequest.selector);
        pool.requestClose(id); // twice

        vm.prank(alice);
        vm.expectRevert(LaunchPool.BadRequest.selector);
        pool.redeem(0);
        vm.prank(alice);
        vm.expectRevert(LaunchPool.BadRequest.selector);
        pool.redeem(1); // holds none
    }

    function test_paramsValidationEachBound() public {
        LaunchPool.Params[11] memory bad;
        for (uint256 i; i < bad.length; i++) {
            bad[i] = defaultParams();
        }
        bad[0].redeemBufferBps = 99;
        bad[1].minNotional = 0;
        bad[2].minNotional = bad[2].maxNotional + 1;
        bad[3].capWindow = 5;
        bad[4].capWindow = 61;
        bad[5].maxLeverage = 0;
        bad[6].winHaircutBps = 10_001;
        bad[7].feeBps = 1_001;
        bad[8].maintenanceBps = 0;
        bad[9].maintenanceBps = 10_001;
        bad[10].haircutToMoveBps = 10_001;
        for (uint256 i; i < bad.length; i++) {
            vm.expectRevert(LaunchPool.BadParams.selector);
            pool.proposeParams(bad[i], HLPriceGuard.Bounds(25, 25, 20, 150), IRefSource(address(0)));
        }
    }

    function test_pendingParamsShowsProposal() public {
        LaunchPool.Params memory p = defaultParams();
        p.feeBps = 7;
        pool.proposeParams(p, HLPriceGuard.Bounds(30, 30, 20, 150), IRefSource(address(0)));
        (LaunchPool.Params memory q, HLPriceGuard.Bounds memory b,, uint64 at) = pool.pendingParams();
        assertEq(q.feeBps, 7);
        assertEq(b.maxMarkOracleBps, 30);
        assertEq(at, block.timestamp + 1 days);
    }

    /// However many winners are queued, the loss that pays them all costs the same gas: the
    /// queue is paid by a counter, and each winner's share is sent by claim().
    function test_longDebtQueuePaidInConstantGas() public {
        uint256 n = 200;
        uint256[] memory ids = new uint256[](n);
        vm.startPrank(alice);
        for (uint256 i; i < n; i++) {
            ids[i] = pool.requestOpen(true, 100 * USDC, 10); // $1,000 each, $0.50 open fee
        }
        vm.stopPrank();
        vm.warp(block.timestamp + 3);
        for (uint256 i; i < n; i++) {
            pool.settle(ids[i]);
        }
        setPx(353_500); // +1%: each wins ($10 - $0.50) * 85% = $8.075; the pool holds $100 of fees
        vm.startPrank(alice);
        for (uint256 i; i < n; i++) {
            pool.requestClose(ids[i]);
        }
        vm.stopPrank();
        vm.warp(block.timestamp + 3);
        for (uint256 i; i < n; i++) {
            pool.settle(ids[i]);
        }
        uint256 queued = pool.debtCount();
        assertGt(queued, 180);
        assertEq(pool.totalDebt(), n * 8.075e6 - 100 * USDC);

        vm.warp(block.timestamp + 60);
        uint256 b = open(bob, true, 25_000 * USDC, 20); // $500K
        vm.prank(bob);
        pool.requestClose(b);
        setPx(350_000); // -0.99%: bob's loss pays the whole queue
        vm.warp(block.timestamp + 3);
        uint256 g = gasleft();
        pool.settle(b);
        g -= gasleft();
        emit log_named_uint("settle gas, paying the whole queue", g);
        assertLt(g, 300_000); // the old loop sent one transfer per queued winner
        assertEq(pool.totalDebt(), 0);

        for (uint256 i; i < queued; i++) {
            pool.claim(i);
        }
        assertEq(pool.unclaimed(), 0);
        assertEq(usdc.balanceOf(address(pool)), pool.poolBalance()); // nothing open: tokens == books
    }

    /// A winner the token refuses to pay (e.g. blacklisted) holds up nobody: settles still pay
    /// the queue, and the next winner claims.
    function test_blockedWinnerDoesNotBlockOthers() public {
        uint256 a = open(alice, true, 10_000 * USDC, 10);
        uint256 b = open(bob, true, 10_000 * USDC, 10);
        setPx(353_500); // +1%: each is owed $807.50; the pool holds $100 of open fees
        vm.warp(block.timestamp + 60);
        close(alice, a); // debt 0: $707.50
        close(bob, b); // debt 1: $807.50
        usdc.setBlocked(alice, true);

        address carol = address(0xCA201);
        usdc.mint(carol, 100_000 * USDC);
        vm.prank(carol);
        usdc.approve(address(pool), type(uint256).max);
        vm.warp(block.timestamp + 60);
        uint256 c = open(carol, true, 25_000 * USDC, 20);
        setPx(350_000);
        vm.warp(block.timestamp + 60);
        close(carol, c); // the loss pays both debts in full
        assertEq(pool.totalDebt(), 0);

        vm.expectRevert(bytes("blocked"));
        pool.claim(0);
        uint256 before = usdc.balanceOf(bob);
        pool.claim(1);
        assertEq(usdc.balanceOf(bob) - before, 807.5e6);
        assertEq(pool.claimable(0), 707.5e6); // still there if alice is unblocked
    }

    // ---- Papertrade's "paper-mint straddle" (their 10-20 notes), replayed on Day One ----

    /// One trader holds both sides of a straddle. After a big move it books the win first, so
    /// the queue takes most of the pool, then the losing side, whose rebate is priced while the
    /// pool is worth almost nothing: it can end up holding most of the shares. Priced at
    /// shareValuation(), they are still worth no more than the rebate once the operator seeds
    /// again. Papertrade minted a flat 100 PAPER per $1 there; returns the attacker's share of
    /// the pool, what its shares are worth after the reseed, and the rebate.
    function _straddle(bool winFirst, uint256 endPx) internal returns (uint256 attackerBps, uint256 worth, uint256 rebate) {
        LaunchPool p = _backedPool();
        p.seed(10_000 * USDC);
        uint256 l = _requestAndWait(p, alice, true, 4_500 * USDC, 20); // $90K each side
        p.settle(l);
        uint256 s = _requestAndWait(p, bob, false, 4_500 * USDC, 20);
        p.settle(s);
        for (uint256 px = 350_000; px < endPx;) { // latch-sized steps
            px = px + 7_000 < endPx ? px + 7_000 : endPx;
            setPx(uint64(px));
            p.poke();
        }
        if (!winFirst) p.liquidate(s);
        vm.prank(alice);
        p.requestClose(l);
        vm.warp(block.timestamp + 3);
        p.settle(l);
        if (winFirst) p.liquidate(s);
        rebate = 4_500 * USDC * 1200 / 10_000;
        attackerBps = p.shares(bob) * 10_000 / p.totalShares();
        p.seed(p.totalDebt() + 10_000 * USDC); // pays any queue first
        worth = p.shares(bob) * p.equity(endPx * 1e15) / p.totalShares();
    }

    function test_straddleRebateWorthOnlyTheRebate() public {
        for (uint256 endPx = 392_000; endPx <= 420_000; endPx += 7_000) {
            uint256 snap = vm.snapshotState();
            (uint256 bpsN, uint256 worthN, uint256 rebate) = _straddle(false, endPx);
            vm.revertToState(snap);
            (uint256 bpsA, uint256 worthA,) = _straddle(true, endPx);
            vm.revertToState(snap);
            emit log_named_uint("end price (1/1000 USD)", endPx);
            emit log_named_uint("  loss first: attacker bps of pool", bpsN);
            emit log_named_uint("  win first:  attacker bps of pool", bpsA);
            emit log_named_uint("  loss first: worth after reseed", worthN);
            emit log_named_uint("  win first:  worth after reseed", worthA);
            assertLe(worthN, rebate);
            assertLe(worthA, rebate);
        }
    }

    /// Every end price, including the ones that leave the pool worth just above the rebate,
    /// where the attacker holds nearly every share.
    function testFuzz_straddleRebateWorthOnlyTheRebate(uint256 endPx) public {
        endPx = bound(endPx, 368_000, 430_000); // the short past its whole margin
        (uint256 bps, uint256 worth, uint256 rebate) = _straddle(true, endPx);
        assertLe(worth, rebate);
        if (bps > 9_900) emit log_named_uint("attacker held bps", bps);
    }
}
