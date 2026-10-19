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
/// (docs/design.md). Run by the market's deployer.
///
/// - Starts empty. Traders' losses and fees fill it. Losers get pool shares worth `rebateBps` of
///   their loss; winners give up `winHaircutBps` of their profit. Keeping rebate < haircut is
///   what makes washing between two own accounts (one long, one short) lose money.
/// - Profits the pool cannot pay yet wait in a FIFO queue, paid from later losses. Paying it
///   is O(1) however long it is: income only moves a cumulative counter, and each winner's
///   paid part is sent by claim(id) (anyone may call it; the keeper does).
/// - Opens and closes are two-step: request now, settle at the guarded oracle at least
///   `settleDelay` seconds later.
/// - Opens and closes each have a rolling notional cap (ExposureBudget.Rolling): on replay, the
///   cap is what made Papertrade's push unprofitable. Separate lanes, so opens cannot use up
///   the budget that due closes need.
/// - Any guard breach (bounds, reference, jump latch) makes settlement revert; requests wait.
/// - Parameter changes take effect `paramsDelay` after they are proposed, and positions keep
///   the fee and haircut they were opened with.
contract LaunchPool {
    using ExposureBudget for ExposureBudget.Rolling;
    using HLPriceGuard for HLPriceGuard.JumpLatch;

    uint16 public constant MIN_REDEEM_BUFFER_BPS = 100;
    /// HL perp prices have `6 - szDecimals` decimals, so szDecimals is at most 6. Larger values
    /// would scale prices far enough to overflow the PnL and equity products.
    uint8 public constant MAX_SZ_DECIMALS = 6;
    /// A rebate that would push the share count past this is skipped, so a share price driven
    /// toward zero can never overflow the count and block a close or liquidation.
    uint256 public constant MAX_SHARES = 2 ** 128;

    struct Params {
        uint16 maxLeverage;
        uint16 maintenanceBps; // liquidatable when equity < notional * maintenanceBps / 1e4
        uint16 feeBps; // on notional, at open and at close
        uint64 settleDelay; // seconds between request and settlement
        uint64 capWindow; // seconds; a multiple of ExposureBudget.SLICES
        uint256 capPerWindow; // notional per rolling window, per lane (opens, closes)
        uint256 minNotional; // per position: no dust that rounds fees to zero
        uint256 maxNotional; // per position
        uint16 maxJumpBps;
        uint256 maxNetNotional; // |long OI - short OI|: what the pool can lose to one move
        // Share of each profit the pool keeps, falling with the size of the win: winHaircutBps
        // while the price has moved at most haircutFromMoveBps from entry, winHaircutMinBps from
        // haircutToMoveBps on, linear in between. Measured on the price move, not on return on
        // margin, so leverage cannot buy a lower rate.
        uint16 winHaircutBps;
        uint16 winHaircutMinBps;
        uint16 haircutFromMoveBps;
        uint16 haircutToMoveBps;
        uint16 rebateBps; // value of shares minted per unit of loss; must be below winHaircutMinBps
        uint16 redeemBufferBps; // of net OI, held back from redemption on top of minReserve
    }

    struct Position {
        address owner;
        bool long;
        uint16 leverage;
        uint256 margin;
        uint256 entry; // 1e18; 0 while the open is pending
        uint64 requestedAt; // pending open or close
        bool closing;
        uint16 feeBps; // fixed at request: the close fee is charged at this rate
        uint64 haircut; // the curve fixed at request: max, min, from, to (16 bits each)
        uint16 maintenanceBps; // fixed at request: a later raise cannot liquidate this position
        uint256 openFee; // paid at request; refunded on cancel, pool income on settle
        uint16 rebateBps; // fixed at request, with the haircut curve, so rebate < floor holds per position
    }

    /// A queued winner. Paid in order: debt `id` is paid once debtPaid passes `start`, the
    /// total queued before it.
    struct Debt {
        address to;
        uint256 start;
        uint256 amount;
        uint256 claimed;
    }

    IERC20 public immutable collateral;
    uint64 public immutable paramsDelay;
    address public operator;
    address public pauser; // may only pause and resume opens for trading hours (the keeper)
    HLPriceGuard.Asset public asset;
    HLPriceGuard.Bounds public bounds;
    IRefSource public refSource;
    Params internal _params;

    Params internal _pendingParams;
    HLPriceGuard.Bounds internal _pendingBounds;
    IRefSource internal _pendingRef;
    uint64 public pendingAt; // 0 = nothing pending

    bool public operatorPaused; // set and cleared by the operator only
    bool public hoursPaused; // out of trading hours: set and cleared by the pauser or the operator
    bool public graduated; // book is deep enough: no new opens, closes still settle

    uint256 public poolBalance; // collateral the pool can pay out from
    uint256 public totalShares;
    mapping(address => uint256) public shares; // shares[address(this)] = locked, never redeemable
    uint256 public minReserve; // never redeemable

    Debt[] public debts;
    uint256 public debtQueued; // all ever queued
    uint256 public debtPaid; // all ever paid into the queue, in order
    uint256 public totalDebt; // debtQueued - debtPaid: still owed to queued winners
    uint256 public unclaimed; // paid into the queue, not yet sent by claim()
    uint256 public pendingOpens; // margin + open fee held for requested, unsettled opens

    mapping(uint256 => Position) public positions;
    uint256 public nextId = 1;
    uint256[] internal _active; // pending or open positions, for keepers
    mapping(uint256 => uint256) internal _activeIndex; // id => index + 1

    uint256 public longOI;
    uint256 public shortOI;
    uint256 public longMargin;
    uint256 public shortMargin;
    // sum of notional * 1e18 / entry per side, rounded so the pool's liability is never
    // understated (longs up, shorts down): open positions' PnL at price P without a loop
    uint256 public longUnits;
    uint256 public shortUnits;

    ExposureBudget.Rolling internal _openLane;
    ExposureBudget.Rolling internal _closeLane;
    HLPriceGuard.JumpLatch public latch;

    event OpenRequested(uint256 indexed id, address indexed owner, bool long, uint256 margin, uint16 leverage);
    event Opened(uint256 indexed id, uint256 entry);
    event CloseRequested(uint256 indexed id);
    event Closed(uint256 indexed id, uint256 exit, int256 pnl, uint256 paid, uint256 queued);
    event Liquidated(uint256 indexed id, uint256 price, uint256 lost);
    event SharesMinted(address indexed to, uint256 lossAmount, uint256 shares, uint256 locked);
    event Redeemed(address indexed by, uint256 shares, uint256 amount);
    event ParamsProposed(uint64 effectiveAt);
    event ParamsApplied();
    event PauserSet(address pauser);
    event Claimed(uint256 indexed id, address indexed to, uint256 amount);

    error NotOperator();
    error NotPauser();
    error NotOwner();
    error OpensClosed();
    error BadRequest();
    error BadParams();
    error TooEarly();
    error NotLiquidatable();
    error NetExposureExceeded(uint256 net, uint256 limit);
    error RebateNotBelowHaircut();
    error RedeemBlocked(uint256 amount, uint256 available);
    error Breach(HLPriceGuard.Breach reason, uint256 observedBps, uint256 limitBps);

    uint256 private _lock = 1;

    /// The collateral is assumed to be a plain ERC20; this also covers tokens with transfer hooks.
    modifier nonReentrant() {
        if (_lock != 1) revert BadRequest();
        _lock = 2;
        _;
        _lock = 1;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    constructor(
        IERC20 collateral_,
        HLPriceGuard.Asset memory asset_,
        HLPriceGuard.Bounds memory bounds_,
        Params memory params_,
        uint256 minReserve_,
        uint64 paramsDelay_
    ) {
        _validate(params_);
        if (asset_.szDecimals > MAX_SZ_DECIMALS) revert BadParams();
        collateral = collateral_;
        paramsDelay = paramsDelay_;
        operator = msg.sender;
        asset = asset_;
        bounds = bounds_;
        _params = params_;
        minReserve = minReserve_;
    }

    // ---- views ----

    /// New opens are refused while either the operator or trading hours hold them.
    function opensPaused() public view returns (bool) {
        return operatorPaused || hoursPaused;
    }

    function getParams() external view returns (Params memory) {
        return _params;
    }

    function pendingParams() external view returns (Params memory, HLPriceGuard.Bounds memory, IRefSource, uint64) {
        return (_pendingParams, _pendingBounds, _pendingRef, pendingAt);
    }

    function activeIds() external view returns (uint256[] memory) {
        return _active;
    }

    function debtCount() external view returns (uint256) {
        return debts.length;
    }

    /// What claim(id) would send now.
    function claimable(uint256 id) public view returns (uint256) {
        Debt storage d = debts[id];
        uint256 paid = debtPaid > d.start ? debtPaid - d.start : 0;
        return (paid < d.amount ? paid : d.amount) - d.claimed;
    }

    function openLaneUsed() external view returns (uint256) {
        return _openLane.used();
    }

    function closeLaneUsed() external view returns (uint256) {
        return _closeLane.used();
    }

    // ---- operator ----

    /// The operator's own pause. The pauser cannot clear it.
    function setOpensPaused(bool p) external onlyOperator {
        operatorPaused = p;
    }

    /// address(0) removes the pauser.
    function setPauser(address p) external onlyOperator {
        pauser = p;
        emit PauserSet(p);
    }

    // ---- pauser ----

    function setHoursPaused(bool p) external {
        if (msg.sender != pauser && msg.sender != operator) revert NotPauser();
        hoursPaused = p;
    }

    function graduate() external onlyOperator {
        graduated = true;
    }

    /// New parameters, bounds and reference source, effective `paramsDelay` from now via
    /// applyParams(). Traders see them coming and can close first.
    function proposeParams(Params calldata p, HLPriceGuard.Bounds calldata b, IRefSource r) external onlyOperator {
        _validate(p);
        _pendingParams = p;
        _pendingBounds = b;
        _pendingRef = r;
        pendingAt = uint64(block.timestamp) + paramsDelay;
        emit ParamsProposed(pendingAt);
    }

    /// Anyone, once the delay has passed. A higher cap or a new window also needs opens paused
    /// (setOpensPaused) and reverts until the rolling lanes have drained under the old settings.
    function applyParams() external {
        if (pendingAt == 0 || block.timestamp < pendingAt) revert TooEarly();
        Params memory p = _pendingParams;
        bool lowerCapOnly = p.capWindow == _params.capWindow && p.capPerWindow <= _params.capPerWindow;
        // Raising the cap or changing the window waits until nothing settled under the old one is
        // in the window. With opens paused that is bounded: each open position closes only once.
        // Otherwise a trader could recycle a small position to keep the lanes busy forever.
        if (!lowerCapOnly && !opensPaused()) revert OpensClosed();
        if (p.capPerWindow != _params.capPerWindow || p.capWindow != _params.capWindow) {
            _openLane.reconfigure(p.capPerWindow, p.capWindow);
            _closeLane.reconfigure(p.capPerWindow, p.capWindow);
        }
        _params = p;
        bounds = _pendingBounds;
        refSource = _pendingRef;
        pendingAt = 0;
        emit ParamsApplied();
    }

    /// After a real gap trips the jump latch. Only once an independent reference agrees.
    /// Immediate (an emergency lever); the operator already controls this market's oracle.
    function rearm(uint256 price) external onlyOperator {
        latch.rearm(price);
    }

    // ---- traders ----

    function requestOpen(bool long, uint256 margin, uint16 leverage) external nonReentrant returns (uint256 id) {
        Params storage P = _params;
        if (opensPaused() || graduated) revert OpensClosed();
        if (margin == 0 || leverage == 0 || leverage > P.maxLeverage) revert BadRequest();
        uint256 notional = margin * leverage;
        if (notional < P.minNotional || notional > P.maxNotional) revert BadRequest();
        // the open fee is collected on top of margin, so notional stays margin * leverage
        uint256 openFee = _bpsUp(notional, P.feeBps);
        collateral.transferFrom(msg.sender, address(this), margin + openFee);
        pendingOpens += margin + openFee;
        id = nextId++;
        positions[id] = Position(
            msg.sender,
            long,
            leverage,
            margin,
            0,
            uint64(block.timestamp),
            false,
            P.feeBps,
            _packHaircut(P),
            P.maintenanceBps,
            openFee,
            P.rebateBps
        );
        _active.push(id);
        _activeIndex[id] = _active.length;
        emit OpenRequested(id, msg.sender, long, margin, leverage);
    }

    /// Withdraw a pending open, e.g. while the guard keeps rejecting the price.
    function cancelOpen(uint256 id) external nonReentrant {
        Position memory p = positions[id];
        if (p.owner != msg.sender) revert NotOwner();
        if (p.entry != 0) revert BadRequest();
        _remove(id);
        pendingOpens -= p.margin + p.openFee;
        collateral.transfer(msg.sender, p.margin + p.openFee);
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
    function settle(uint256 id) external nonReentrant {
        Position storage p = positions[id];
        if (p.owner == address(0) || (p.entry != 0 && !p.closing)) revert BadRequest();
        if (block.timestamp < p.requestedAt + _params.settleDelay) revert TooEarly();
        uint256 notional = p.margin * p.leverage;
        uint256 price = _price();
        if (p.entry == 0) {
            if (opensPaused() || graduated) revert OpensClosed();
            _openLane.spend(notional, _params.capPerWindow, _params.capWindow);
            _addOI(p.long, notional, p.margin, price);
            uint256 net = _net();
            if (net > _params.maxNetNotional) revert NetExposureExceeded(net, _params.maxNetNotional);
            p.entry = price; // state before the token transfers in _income
            pendingOpens -= p.margin + p.openFee;
            _income(p.openFee);
            emit Opened(id, price);
        } else {
            _closeLane.spend(notional, _params.capPerWindow, _params.capWindow);
            _close(id, p, price);
        }
    }

    function liquidate(uint256 id) external nonReentrant {
        Position memory p = positions[id];
        if (p.entry == 0) revert BadRequest();
        uint256 price = _price();
        uint256 notional = p.margin * p.leverage;
        int256 posEquity = int256(p.margin) + _pnl(p, price);
        if (posEquity >= int256(_bpsUp(notional, p.maintenanceBps))) revert NotLiquidatable();
        _remove(id);
        _reduceOI(p.long, notional, p.margin, p.entry);
        uint256 left = posEquity > 0 ? uint256(posEquity) : 0;
        if (left != 0) collateral.transfer(p.owner, left);
        uint256 lost = p.margin - left;
        _income(lost);
        _mintShares(p.owner, lost, p.rebateBps);
        emit Liquidated(id, price, lost);
    }

    /// Keepers call this on every oracle update. The latch's anchor only moves in a transaction
    /// that succeeds, so without it a quiet spell plus normal drift would trip the latch.
    function poke() external returns (uint256) {
        return _price();
    }

    /// Send queued winner `id` what the queue has paid them so far. Anyone may call; the
    /// money only goes to the winner.
    function claim(uint256 id) external nonReentrant returns (uint256 amount) {
        if (id >= debts.length) revert BadRequest();
        amount = claimable(id);
        if (amount == 0) revert BadRequest();
        Debt storage d = debts[id];
        d.claimed += amount;
        unclaimed -= amount;
        collateral.transfer(d.to, amount);
        emit Claimed(id, d.to, amount);
    }

    // ---- shares ----

    /// Burn shares for their part of the pool's equity, at the guarded oracle. Blocked while
    /// winners are queued, and limited to equity above minReserve plus a buffer on net OI.
    function redeem(uint256 amountShares) external nonReentrant returns (uint256 amount) {
        if (totalDebt != 0 || amountShares == 0 || amountShares > shares[msg.sender]) revert BadRequest();
        uint256 eq = equity(_price());
        amount = amountShares * eq / totalShares;
        uint256 hold = minReserve + _net() * _params.redeemBufferBps / 10_000;
        uint256 available = eq > hold ? eq - hold : 0;
        if (amount == 0 || amount > available) revert RedeemBlocked(amount, available);
        shares[msg.sender] -= amountShares;
        totalShares -= amountShares;
        poolBalance -= amount;
        collateral.transfer(msg.sender, amount);
        emit Redeemed(msg.sender, amountShares, amount);
    }

    /// Pool balance minus an upper bound on what open positions could be paid at `price`.
    ///
    /// Per side, the winners' total is at most the side's aggregate PnL plus the side's margin
    /// (each loser can lose at most its margin before it is liquidated), so open losses are
    /// never counted as the pool's, and one side's losers never offset the other side's winners.
    function equity(uint256 price) public view returns (uint256) {
        uint256 longValue = _mulUp(longUnits, price); // what longs' units are worth, rounded up
        uint256 shortValue = shortUnits * price / 1e18; // rounded down: shorts gain when it is low
        uint256 longOwed = longValue + longMargin > longOI ? longValue + longMargin - longOI : 0;
        uint256 shortOwed = shortOI + shortMargin > shortValue ? shortOI + shortMargin - shortValue : 0;
        uint256 owed = longOwed + shortOwed;
        return owed >= poolBalance ? 0 : poolBalance - owed;
    }

    /// The most the pool can be worth from what is open or requested now: balance, plus every
    /// open position's margin (a position can lose at most its margin), plus each pending open's
    /// margin and fee (the fee becomes income at settle), minus what is owed to queued winners. New shares are priced here, so nothing that happens to today's positions can
    /// make them worth more than their rebate; only losses on positions opened later can, and
    /// that income is meant for holders. Redemption uses equity(), the low end, so minting
    /// high and redeeming low leaves nothing to arbitrage.
    function shareValuation() public view returns (uint256) {
        uint256 v = poolBalance + longMargin + shortMargin + pendingOpens;
        return v > totalDebt ? v - totalDebt : 0;
    }

    // ---- internals ----

    function _validate(Params memory p) internal pure {
        // the rebate stays below the lowest point of the curve, so washing loses at every size
        if (p.rebateBps >= p.winHaircutMinBps) revert RebateNotBelowHaircut();
        if (p.winHaircutMinBps > p.winHaircutBps || p.haircutFromMoveBps >= p.haircutToMoveBps || p.haircutToMoveBps > 10_000) {
            revert BadParams();
        }
        if (p.redeemBufferBps < MIN_REDEEM_BUFFER_BPS) revert BadParams();
        if (p.minNotional == 0 || p.minNotional > p.maxNotional) revert BadParams();
        if (p.capWindow < ExposureBudget.SLICES || p.capWindow % ExposureBudget.SLICES != 0) revert BadParams();
        if (p.maxLeverage == 0 || p.winHaircutBps > 10_000 || p.feeBps > 1_000) revert BadParams();
        if (p.maintenanceBps == 0 || p.maintenanceBps > 10_000) revert BadParams();
    }

    function _price() internal returns (uint256 price) {
        HLPriceGuard.Ref memory r;
        if (address(refSource) != address(0)) r = refSource.ref();
        HLPriceGuard.Quote memory q = HLPriceGuard.quote(asset);
        (HLPriceGuard.Breach reason, uint256 observed, uint256 limit) = HLPriceGuard.check(q, bounds, r);
        if (reason == HLPriceGuard.Breach.None) {
            (reason, observed, limit) = latch.observe(q.oracle, _params.maxJumpBps);
        }
        if (reason != HLPriceGuard.Breach.None) revert Breach(reason, observed, limit);
        return q.oracle;
    }

    function _remove(uint256 id) internal {
        uint256 i = _activeIndex[id];
        uint256 last = _active[_active.length - 1];
        _active[i - 1] = last;
        _activeIndex[last] = i;
        _active.pop();
        delete _activeIndex[id];
        delete positions[id];
    }

    /// Fees, maintenance and haircuts: rounded up, in the pool's favor.
    function _bpsUp(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return (amount * bps + 9_999) / 10_000;
    }

    function _mulUp(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b + 1e18 - 1) / 1e18;
    }

    function _units(bool long, uint256 notional, uint256 entry) internal pure returns (uint256) {
        return long ? (notional * 1e18 + entry - 1) / entry : notional * 1e18 / entry;
    }

    function _addOI(bool long, uint256 notional, uint256 margin, uint256 entry) internal {
        uint256 u = _units(long, notional, entry);
        if (long) {
            longOI += notional;
            longMargin += margin;
            longUnits += u;
        } else {
            shortOI += notional;
            shortMargin += margin;
            shortUnits += u;
        }
    }

    function _reduceOI(bool long, uint256 notional, uint256 margin, uint256 entry) internal {
        uint256 u = _units(long, notional, entry);
        if (long) {
            longOI -= notional;
            longMargin -= margin;
            longUnits -= u;
        } else {
            shortOI -= notional;
            shortMargin -= margin;
            shortUnits -= u;
        }
    }

    function _net() internal view returns (uint256) {
        return longOI > shortOI ? longOI - shortOI : shortOI - longOI;
    }

    function _packHaircut(Params storage P) internal view returns (uint64) {
        return uint64(P.winHaircutBps) << 48 | uint64(P.winHaircutMinBps) << 32 | uint64(P.haircutFromMoveBps) << 16
            | uint64(P.haircutToMoveBps);
    }

    /// The haircut for a win, from the curve stored with the position and the price move since
    /// entry. Never below the curve's minimum, so never at or below the rebate.
    function _haircutBps(uint64 c, uint256 entry, uint256 price) internal pure returns (uint256) {
        uint256 hi = uint16(c >> 48);
        uint256 lo = uint16(c >> 32);
        uint256 from = uint256(uint16(c >> 16)) * 100; // in hundredths of a bp, so the
        uint256 to = uint256(uint16(c)) * 100; // rate moves smoothly, not in whole-bp steps
        uint256 move = (price > entry ? price - entry : entry - price) * 1_000_000 / entry;
        if (move <= from) return hi;
        if (move >= to) return lo;
        return hi - (hi - lo) * (move - from) / (to - from);
    }

    /// The haircut a position closed at `price` would pay, for UIs and keepers.
    function haircutAt(uint256 id, uint256 price) external view returns (uint256) {
        Position storage p = positions[id];
        return p.entry == 0 ? 0 : _haircutBps(p.haircut, p.entry, price);
    }

    /// Rounded down (toward minus infinity), so neither side gains from the division.
    function _pnl(Position memory p, uint256 price) internal pure returns (int256 pnl) {
        int256 notional = int256(p.margin * p.leverage);
        int256 move = int256(price) - int256(p.entry);
        int256 x = (p.long ? move : -move) * notional;
        int256 e = int256(p.entry);
        pnl = x / e;
        if (x < 0 && x % e != 0) pnl -= 1;
    }

    function _close(uint256 id, Position storage ps, uint256 price) internal {
        Position memory p = ps;
        _remove(id);
        uint256 notional = p.margin * p.leverage;
        _reduceOI(p.long, notional, p.margin, p.entry);
        uint256 fee = _bpsUp(notional, p.feeBps);
        int256 pnl = _pnl(p, price) - int256(fee);
        uint256 paid;
        uint256 queued;
        if (pnl >= 0) {
            // net of the close fee and the win haircut, both of which stay in the pool
            uint256 profit = uint256(pnl) - _bpsUp(uint256(pnl), _haircutBps(p.haircut, p.entry, price));
            paid = profit <= poolBalance ? profit : poolBalance;
            poolBalance -= paid;
            queued = profit - paid;
            if (queued != 0) {
                debts.push(Debt(p.owner, debtQueued, queued, 0));
                debtQueued += queued;
                totalDebt += queued;
            }
            collateral.transfer(p.owner, p.margin + paid);
        } else {
            uint256 loss = uint256(-pnl);
            if (loss > p.margin) loss = p.margin; // liquidation should have come first
            collateral.transfer(p.owner, p.margin - loss);
            _income(loss);
            _mintShares(p.owner, loss > fee ? loss - fee : 0, p.rebateBps);
        }
        emit Closed(id, price, pnl, paid, queued);
    }

    /// New collateral for the pool: pay the debt queue first, keep the rest. No loop: the
    /// paid part waits in `unclaimed` until claim() sends it.
    function _income(uint256 amount) internal {
        uint256 pay = amount < totalDebt ? amount : totalDebt;
        if (pay != 0) {
            debtPaid += pay;
            totalDebt -= pay;
            unclaimed += pay;
        }
        poolBalance += amount - pay;
    }

    /// Shares worth `rebateBps` (the position's own, fixed at request) of the loss, priced at
    /// shareValuation().
    ///
    /// The first mint also creates locked shares (held by this contract, never redeemable) for
    /// the rest of the valuation, so the first loser's shares are worth the rebate and no more.
    function _mintShares(address to, uint256 loss, uint256 rebateBps) internal {
        uint256 value = loss * rebateBps / 10_000;
        if (value == 0) return;
        // the loss is already in poolBalance, so v >= loss > value unless winners are queued
        uint256 v = shareValuation();
        if (v <= value) return; // everything is owed to queued winners: no rebate
        uint256 s_;
        uint256 locked;
        if (totalShares == 0) {
            s_ = value; // 1 share = 1 collateral unit at the start
            locked = v - value;
        } else {
            s_ = value * totalShares / (v - value);
        }
        if (totalShares + s_ + locked > MAX_SHARES) return; // the rebate is skipped, the loss still settles
        shares[to] += s_;
        if (locked != 0) shares[address(this)] += locked;
        totalShares += s_ + locked;
        emit SharesMinted(to, loss, s_, locked);
    }
}
