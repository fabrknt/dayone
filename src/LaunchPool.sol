// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {HLPriceGuard} from "hl-price-guard/HLPriceGuard.sol";
import {ExposureBudget} from "hl-price-guard/ExposureBudget.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// An independent price for the guard (e.g. a PythRef wrapper). Return price 0 for none.
interface IRefSource {
    function ref() external view returns (HLPriceGuard.Ref memory);
}

/// @notice Loss-funded counterparty pool for one HIP-3 perp while its book is thin
/// (docs/c-launch-pool-design.md). Run by the market's deployer.
///
/// - Starts empty. Traders' losses and fees fill it; each $ lost mints pool shares to the loser.
/// - Profits the pool cannot pay yet wait in a FIFO queue, paid from later losses.
/// - Opens and closes are two-step: request now, settle at the guarded oracle at least
///   `settleDelay` seconds later.
/// - Every settlement counts against a per-minute notional cap (ExposureBudget): on replay,
///   the cap is what made Papertrade's push unprofitable.
/// - Any guard breach (bounds, reference, jump latch) makes settlement revert; requests wait.
contract LaunchPool {
    using ExposureBudget for ExposureBudget.Window;
    using HLPriceGuard for HLPriceGuard.JumpLatch;

    struct Params {
        uint16 maxLeverage;
        uint16 maintenanceBps; // liquidatable when equity < notional * maintenanceBps / 1e4
        uint16 feeBps; // on notional, at open and at close
        uint64 settleDelay; // seconds between request and settlement
        uint64 capWindow; // seconds
        uint256 capPerWindow; // notional settled per window, collateral units
        uint256 maxNotional; // per position
        uint16 maxJumpBps;
        uint256 maxNetNotional; // |long OI - short OI|: what the pool can lose to one move
    }

    struct Position {
        address owner;
        bool long;
        uint16 leverage;
        uint256 margin;
        uint256 entry; // 1e18; 0 while the open is pending
        uint64 requestedAt; // pending open or close
        bool closing;
    }

    struct Debt {
        address to;
        uint256 amount;
    }

    IERC20 public immutable collateral;
    address public operator;
    HLPriceGuard.Asset public asset;
    HLPriceGuard.Bounds public bounds;
    IRefSource public refSource;
    Params public params;

    bool public opensPaused; // out of trading hours, or by the operator
    bool public graduated; // book is deep enough: no new opens, closes still settle

    uint256 public poolBalance; // collateral the pool can pay out from
    uint256 public totalShares;
    mapping(address => uint256) public shares;
    uint256 public shareTierBalance; // full share rate below this pool size

    Debt[] public debts;
    uint256 public debtHead;
    uint256 public totalDebt;

    mapping(uint256 => Position) public positions;
    uint256 public nextId = 1;

    uint256 public longOI;
    uint256 public shortOI;

    ExposureBudget.Window public window;
    HLPriceGuard.JumpLatch public latch;

    event OpenRequested(uint256 indexed id, address indexed owner, bool long, uint256 margin, uint16 leverage);
    event Opened(uint256 indexed id, uint256 entry);
    event CloseRequested(uint256 indexed id);
    event Closed(uint256 indexed id, uint256 exit, int256 pnl, uint256 paid, uint256 queued);
    event Liquidated(uint256 indexed id, uint256 price, uint256 lost);
    event SharesMinted(address indexed to, uint256 lossAmount, uint256 shares);

    error NotOperator();
    error NotOwner();
    error OpensClosed();
    error BadRequest();
    error TooEarly();
    error NotLiquidatable();
    error NetExposureExceeded(uint256 net, uint256 limit);
    error Breach(HLPriceGuard.Breach reason, uint256 observedBps, uint256 limitBps);

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    constructor(
        IERC20 collateral_,
        HLPriceGuard.Asset memory asset_,
        HLPriceGuard.Bounds memory bounds_,
        Params memory params_,
        uint256 shareTierBalance_
    ) {
        collateral = collateral_;
        operator = msg.sender;
        asset = asset_;
        bounds = bounds_;
        params = params_;
        shareTierBalance = shareTierBalance_;
    }

    // ---- operator ----

    function setOpensPaused(bool p) external onlyOperator {
        opensPaused = p;
    }

    function graduate() external onlyOperator {
        graduated = true;
    }

    function setRefSource(IRefSource r) external onlyOperator {
        refSource = r;
    }

    function setParams(Params calldata p, HLPriceGuard.Bounds calldata b) external onlyOperator {
        params = p;
        bounds = b;
    }

    /// After a real gap trips the jump latch. Only once an independent reference agrees.
    function rearm(uint256 price) external onlyOperator {
        latch.rearm(price);
    }

    // ---- traders ----

    function requestOpen(bool long, uint256 margin, uint16 leverage) external returns (uint256 id) {
        if (opensPaused || graduated) revert OpensClosed();
        if (margin == 0 || leverage == 0 || leverage > params.maxLeverage) revert BadRequest();
        if (margin * leverage > params.maxNotional) revert BadRequest();
        // the open fee is collected on top of margin, so notional stays margin * leverage
        collateral.transferFrom(msg.sender, address(this), margin + _fee(margin * leverage));
        id = nextId++;
        positions[id] = Position(msg.sender, long, leverage, margin, 0, uint64(block.timestamp), false);
        emit OpenRequested(id, msg.sender, long, margin, leverage);
    }

    /// Withdraw a pending open, e.g. while the guard keeps rejecting the price.
    function cancelOpen(uint256 id) external {
        Position memory p = positions[id];
        if (p.owner != msg.sender) revert NotOwner();
        if (p.entry != 0) revert BadRequest();
        delete positions[id];
        collateral.transfer(msg.sender, p.margin + _fee(p.margin * p.leverage));
    }

    function requestClose(uint256 id) external {
        Position storage p = positions[id];
        if (p.owner != msg.sender) revert NotOwner();
        if (p.entry == 0 || p.closing) revert BadRequest();
        p.closing = true;
        p.requestedAt = uint64(block.timestamp);
        emit CloseRequested(id);
    }

    /// Anyone (usually a keeper) settles a pending open or close at the guarded oracle.
    function settle(uint256 id) external {
        Position storage p = positions[id];
        if (p.owner == address(0) || (p.entry != 0 && !p.closing)) revert BadRequest();
        if (block.timestamp < p.requestedAt + params.settleDelay) revert TooEarly();
        uint256 notional = p.margin * p.leverage;
        uint256 price = _price();
        window.spend(notional, params.capPerWindow, params.capWindow);
        if (p.entry == 0) {
            if (opensPaused || graduated) revert OpensClosed();
            if (p.long) longOI += notional;
            else shortOI += notional;
            uint256 net = longOI > shortOI ? longOI - shortOI : shortOI - longOI;
            if (net > params.maxNetNotional) revert NetExposureExceeded(net, params.maxNetNotional);
            _income(_fee(notional));
            p.entry = price;
            emit Opened(id, price);
        } else {
            _close(id, p, price);
        }
    }

    function liquidate(uint256 id) external {
        Position memory p = positions[id];
        if (p.entry == 0) revert BadRequest();
        uint256 price = _price();
        uint256 notional = p.margin * p.leverage;
        int256 equity = int256(p.margin) + _pnl(p, price);
        if (equity >= int256(notional * params.maintenanceBps / 10_000)) revert NotLiquidatable();
        delete positions[id];
        _reduceOI(p.long, notional);
        uint256 left = equity > 0 ? uint256(equity) : 0;
        if (left != 0) collateral.transfer(p.owner, left);
        uint256 lost = p.margin - left;
        _income(lost);
        _mintShares(p.owner, lost);
        emit Liquidated(id, price, lost);
    }

    /// Keepers call this on every oracle update. The latch's anchor only moves in a transaction
    /// that succeeds, so without it a quiet spell plus normal drift would trip the latch.
    function poke() external returns (uint256) {
        return _price();
    }

    // ---- shares ----

    /// Value per share of the pool above `reserve`. M1 has no redemption: what the pool owes
    /// to open positions is not tracked yet, so paying shares out could leave winners unpaid.
    function sharePrice(uint256 reserve) public view returns (uint256) {
        if (totalShares == 0 || poolBalance <= reserve) return 0;
        return (poolBalance - reserve) * 1e18 / totalShares;
    }

    // ---- internals ----

    function _price() internal returns (uint256 price) {
        HLPriceGuard.Ref memory r;
        if (address(refSource) != address(0)) r = refSource.ref();
        HLPriceGuard.Quote memory q = HLPriceGuard.quote(asset);
        (HLPriceGuard.Breach reason, uint256 observed, uint256 limit) = HLPriceGuard.check(q, bounds, r);
        if (reason == HLPriceGuard.Breach.None) (reason, observed, limit) = latch.observe(q.oracle, params.maxJumpBps);
        if (reason != HLPriceGuard.Breach.None) revert Breach(reason, observed, limit);
        return q.oracle;
    }

    function _reduceOI(bool long, uint256 notional) internal {
        if (long) longOI -= notional;
        else shortOI -= notional;
    }

    function _fee(uint256 notional) internal view returns (uint256) {
        return notional * params.feeBps / 10_000;
    }

    function _pnl(Position memory p, uint256 price) internal pure returns (int256) {
        int256 notional = int256(p.margin * p.leverage);
        int256 move = (int256(price) - int256(p.entry)) * notional / int256(p.entry);
        return p.long ? move : -move;
    }

    function _close(uint256 id, Position storage ps, uint256 price) internal {
        Position memory p = ps;
        delete positions[id];
        uint256 notional = p.margin * p.leverage;
        _reduceOI(p.long, notional);
        uint256 fee = _fee(notional);
        int256 pnl = _pnl(p, price) - int256(fee);
        uint256 paid;
        uint256 queued;
        if (pnl >= 0) {
            uint256 profit = uint256(pnl); // already net of the close fee, which stays in the pool
            paid = profit <= poolBalance ? profit : poolBalance;
            poolBalance -= paid;
            queued = profit - paid;
            if (queued != 0) {
                debts.push(Debt(p.owner, queued));
                totalDebt += queued;
            }
            collateral.transfer(p.owner, p.margin + paid);
        } else {
            uint256 loss = uint256(-pnl);
            if (loss > p.margin) loss = p.margin; // liquidation should have come first
            collateral.transfer(p.owner, p.margin - loss);
            _income(loss);
            _mintShares(p.owner, loss > fee ? loss - fee : 0);
        }
        emit Closed(id, price, pnl, paid, queued);
    }

    /// New collateral for the pool: pay the debt queue first, keep the rest.
    function _income(uint256 amount) internal {
        while (amount != 0 && debtHead < debts.length) {
            Debt storage d = debts[debtHead];
            uint256 pay = amount < d.amount ? amount : d.amount;
            d.amount -= pay;
            totalDebt -= pay;
            amount -= pay;
            collateral.transfer(d.to, pay);
            if (d.amount == 0) debtHead++;
        }
        poolBalance += amount;
    }

    /// 100 shares per unit lost while the pool is below `shareTierBalance`, then falling with size.
    function _mintShares(address to, uint256 loss) internal {
        if (loss == 0) return;
        uint256 rate = poolBalance <= shareTierBalance ? 100 : 100 * shareTierBalance / poolBalance;
        uint256 s = loss * rate;
        shares[to] += s;
        totalShares += s;
        emit SharesMinted(to, loss, s);
    }
}
