// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {HLPrecompiles} from "hl-price-guard/HLPrecompiles.sol";
import {HLPriceGuard} from "hl-price-guard/HLPriceGuard.sol";
import {LaunchPool, IERC20, IRefSource} from "../src/LaunchPool.sol";
import {MockPrecompile, MockUSDC} from "./Mocks.sol";

/// Random sequences of every pool action, including parameter changes, latch trips and
/// rearms. The pool's operator is this handler. Calls that the pool refuses are skipped, not
/// failures: the invariants below are checked after every step either way.
contract Handler is Test {
    uint32 constant PERP = 10001;
    uint32 constant BBO_IDX = 110001;
    uint256 constant USDC = 1e6;

    LaunchPool public pool;
    MockUSDC public usdc;
    address[3] public actors = [address(0xA11CE), address(0xB0B), address(0xCA401)];
    uint64 public px = 350_000;

    // how often each action went through, to see the run is not all reverts
    mapping(string => uint256) public calls;

    constructor(MockUSDC usdc_, LaunchPool.Params memory p) {
        usdc = usdc_;
        setPx(px);
        pool = new LaunchPool(
            IERC20(address(usdc)),
            HLPriceGuard.Asset({dex: 1, index: 1, szDecimals: 3}),
            HLPriceGuard.Bounds({maxMarkOracleBps: 25, maxMidOracleBps: 25, maxSpreadBps: 20, maxRefOracleBps: 150}),
            p,
            0,
            1 days
        );
        for (uint256 i; i < actors.length; i++) {
            usdc.mint(actors[i], 100_000_000 * USDC);
            vm.prank(actors[i]);
            usdc.approve(address(pool), type(uint256).max);
        }
    }

    function setPx(uint64 p) internal {
        MockPrecompile(HLPrecompiles.ORACLE_PX).set(PERP, abi.encode(p));
        MockPrecompile(HLPrecompiles.MARK_PX).set(PERP, abi.encode(p));
        MockPrecompile(HLPrecompiles.BBO).set(BBO_IDX, abi.encode(p - 5, p + 5));
    }

    function oracle() public view returns (uint256) {
        return uint256(px) * 1e15;
    }

    function _owner(uint256 id) internal view returns (address o) {
        (o,,,,,,,,,,,) = pool.positions(id);
    }

    /// Tries the action on each live position, starting at a random one, until one goes through.
    function _onSome(uint256 seed, function(uint256) internal returns (bool) act) internal returns (bool) {
        uint256[] memory ids = pool.activeIds();
        for (uint256 i; i < ids.length; i++) {
            if (act(ids[(seed + i) % ids.length])) return true;
        }
        return false;
    }

    // ---- actions ----

    function requestOpen(uint256 actorSeed, bool long, uint256 margin, uint256 lev) external {
        address a = actors[actorSeed % actors.length];
        lev = bound(lev, 1, 20);
        margin = bound(margin, 100 * USDC, 25_000 * USDC);
        vm.prank(a);
        try pool.requestOpen(long, margin, uint16(lev)) {
            calls["requestOpen"]++;
        } catch {}
    }

    function _cancel(uint256 id) internal returns (bool) {
        vm.prank(_owner(id));
        try pool.cancelOpen(id) {
            return true;
        } catch {
            return false;
        }
    }

    function cancelOpen(uint256 seed) external {
        if (seed % 4 == 0 && _onSome(seed, _cancel)) calls["cancelOpen"]++; // rarer, or few opens settle
    }

    function _requestClose(uint256 id) internal returns (bool) {
        vm.prank(_owner(id));
        try pool.requestClose(id) {
            return true;
        } catch {
            return false;
        }
    }

    function requestClose(uint256 seed) external {
        if (_onSome(seed, _requestClose)) calls["requestClose"]++;
    }

    function _settle(uint256 id) internal returns (bool) {
        try pool.settle(id) {
            return true;
        } catch {
            return false;
        }
    }

    function settle(uint256 seed) external {
        vm.warp(block.timestamp + pool.getParams().settleDelay);
        if (_onSome(seed, _settle)) calls["settle"]++;
    }

    function _liquidate(uint256 id) internal returns (bool) {
        try pool.liquidate(id) {
            return true;
        } catch {
            return false;
        }
    }

    function liquidate(uint256 seed) external {
        if (_onSome(seed, _liquidate)) calls["liquidate"]++;
    }

    function claim(uint256 seed) external {
        uint256 n = pool.debtCount();
        for (uint256 i; i < n; i++) {
            uint256 id = (seed + i) % n;
            if (pool.claimable(id) != 0) {
                pool.claim(id);
                calls["claim"]++;
                return;
            }
        }
    }

    /// Up to ±2.5%: within the latch's 2% sometimes, past it otherwise.
    function movePrice(int256 bps) external {
        bps = bound(bps, -250, 250);
        uint256 next = uint256(px) * uint256(10_000 + bps) / 10_000;
        if (next < 1_000) next = 1_000;
        px = uint64(next);
        setPx(px);
        try pool.poke() {
            calls["poke"]++;
        } catch {}
    }

    function rearm() external {
        pool.rearm(oracle());
        calls["rearm"]++;
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 300));
    }

    function redeem(uint256 actorSeed, uint256 part) external {
        address a = actors[actorSeed % actors.length];
        uint256 s = pool.shares(a);
        if (s == 0) return;
        vm.prank(a);
        try pool.redeem(bound(part, 1, s)) {
            calls["redeem"]++;
        } catch {}
    }

    /// Paused about a quarter of the time, so opens still go through.
    function setHoursPaused(uint256 seed) external {
        pool.setHoursPaused(seed % 4 == 0);
    }

    /// New fee, maintenance, rebate and curve, applied after the delay; caps unchanged.
    function changeParams(uint256 fee, uint256 maint, uint256 top, uint256 low, uint256 rebate) external {
        LaunchPool.Params memory p = pool.getParams();
        p.feeBps = uint16(bound(fee, 0, 20));
        p.maintenanceBps = uint16(bound(maint, 100, 800));
        p.winHaircutMinBps = uint16(bound(low, 500, 3000));
        p.winHaircutBps = uint16(bound(top, p.winHaircutMinBps, 5000));
        p.rebateBps = uint16(bound(rebate, 0, p.winHaircutMinBps - 1));
        pool.proposeParams(p, HLPriceGuard.Bounds(25, 25, 20, 150), IRefSource(address(0)));
        vm.warp(block.timestamp + 1 days);
        pool.applyParams();
        calls["changeParams"]++;
    }
}

contract LaunchPoolInvariantTest is Test {
    Handler h;
    LaunchPool pool;
    MockUSDC usdc;

    function setUp() public {
        address mockCode = address(new MockPrecompile());
        vm.etch(HLPrecompiles.ORACLE_PX, mockCode.code);
        vm.etch(HLPrecompiles.MARK_PX, mockCode.code);
        vm.etch(HLPrecompiles.BBO, mockCode.code);
        vm.warp(1792190822);
        usdc = new MockUSDC();
        h = new Handler(usdc, LaunchPool.Params({
            maxLeverage: 20,
            maintenanceBps: 250,
            feeBps: 5,
            settleDelay: 3,
            capWindow: 60,
            capPerWindow: 1_000_000 * 1e6,
            minNotional: 100 * 1e6,
            maxNotional: 500_000 * 1e6,
            maxJumpBps: 200,
            maxNetNotional: 1_500_000 * 1e6,
            winHaircutBps: 3000,
            winHaircutMinBps: 1500,
            haircutFromMoveBps: 25,
            haircutToMoveBps: 100,
            rebateBps: 1200,
            redeemBufferBps: 1000
        }));
        pool = h.pool();
        targetContract(address(h));
    }

    /// Every token the pool holds is accounted for: the pool's own balance, open margin,
    /// pending opens and what queued winners have been paid but not yet claimed.
    function invariant_tokensMatchBooks() public view {
        assertEq(
            usdc.balanceOf(address(pool)),
            pool.poolBalance() + pool.longMargin() + pool.shortMargin() + pool.pendingOpens() + pool.unclaimed()
        );
    }

    /// The queue's counters agree with its entries, payment is in order (no entry is paid
    /// while an earlier one is short), and the pool keeps no balance while anyone waits.
    function invariant_debtQueue() public view {
        uint256 n = pool.debtCount();
        uint256 owedOrUnclaimed;
        uint256 claimable;
        bool shortSeen;
        for (uint256 i; i < n; i++) {
            (, uint256 start, uint256 amount, uint256 claimed) = pool.debts(i);
            owedOrUnclaimed += amount - claimed;
            claimable += pool.claimable(i);
            bool fullyPaid = pool.debtPaid() >= start + amount;
            if (shortSeen) assertTrue(pool.debtPaid() <= start); // nothing after a short entry is paid
            if (!fullyPaid) shortSeen = true;
        }
        assertEq(pool.totalDebt(), pool.debtQueued() - pool.debtPaid());
        assertEq(owedOrUnclaimed, pool.totalDebt() + pool.unclaimed());
        assertEq(claimable, pool.unclaimed());
        if (pool.totalDebt() != 0) assertEq(pool.poolBalance(), 0);
    }

    /// The per-side totals equal the sum over open positions; pendingOpens equals the sum over
    /// requested ones; the active list holds exactly the live positions.
    function invariant_aggregatesMatchPositions() public view {
        uint256[] memory ids = pool.activeIds();
        uint256[6] memory t; // longOI, shortOI, longMargin, shortMargin, longUnits, shortUnits
        uint256 pending;
        for (uint256 i; i < ids.length; i++) {
            (address owner, bool long, uint16 lev, uint256 margin, uint256 entry,,,,,, uint256 openFee,) =
                pool.positions(ids[i]);
            assertTrue(owner != address(0));
            if (entry == 0) {
                pending += margin + openFee;
                continue;
            }
            uint256 notional = margin * lev;
            uint256 units = long ? (notional * 1e18 + entry - 1) / entry : notional * 1e18 / entry;
            uint256 k = long ? 0 : 1;
            t[k] += notional;
            t[2 + k] += margin;
            t[4 + k] += units;
        }
        assertEq(pool.longOI(), t[0]);
        assertEq(pool.shortOI(), t[1]);
        assertEq(pool.longMargin(), t[2]);
        assertEq(pool.shortMargin(), t[3]);
        assertEq(pool.longUnits(), t[4]);
        assertEq(pool.shortUnits(), t[5]);
        assertEq(pool.pendingOpens(), pending);
    }

    function invariant_sharesAddUp() public view {
        uint256 sum = pool.shares(address(pool));
        for (uint256 i; i < 3; i++) {
            sum += pool.shares(h.actors(i));
        }
        assertEq(pool.totalShares(), sum);
    }

    /// Redemption (equity, the low end) never exceeds minting (shareValuation, the high end),
    /// at the current price or far from it.
    function invariant_equityBelowValuation() public view {
        uint256 v = pool.shareValuation();
        uint256 o = h.oracle();
        assertLe(pool.equity(o), v);
        assertLe(pool.equity(o / 2), v);
        assertLe(pool.equity(o * 2), v);
    }

    /// Shows how many of each action went through (forge test -vv).
    function afterInvariant() public {
        string[10] memory names = [
            "requestOpen", "cancelOpen", "requestClose", "settle", "liquidate", "poke", "rearm", "redeem", "changeParams", "claim"
        ];
        for (uint256 i; i < names.length; i++) {
            emit log_named_uint(names[i], h.calls(names[i]));
        }
        emit log_named_uint("queued winners", pool.debtCount());
    }
}
