// The backing room the page shows: the largest new position, at today's oracle, that the
// pool's _checkBacking would still accept. Kept apart from App.tsx so web/room.test.mjs can run it.

export type RoomState = {
  oracle: bigint; balance: bigint; totalDebt: bigint; stressed: bigint[]; // [up price + 1, down price]
  longMin: bigint; shortMax: bigint; longCount: bigint; shortCount: bigint; longUnits: bigint; shortUnits: bigint;
};

const E = 10n ** 18n;
const longsAt = (p: bigint, units: bigint, min: bigint) => (p > min ? (units * (p - min)) / E : 0n);
const shortsAt = (p: bigint, units: bigint, n: bigint, max: bigint) => (p < max ? ((units + n) * (max - p)) / E : 0n);

/// The pool's profitBound after adding a position of `notional` at the oracle. The new one can
/// move its side's entry extreme, which re-prices every unit already on that side.
export function fits(st: RoomState, long: boolean, notional: bigint): boolean {
  const u = (notional * E) / st.oracle + 1n;
  const lMin = long && !(st.longCount > 0n && st.longMin < st.oracle) ? st.oracle : st.longMin;
  const sMax = !long && !(st.shortCount > 0n && st.shortMax > st.oracle) ? st.oracle : st.shortMax;
  return st.stressed.every((p) => {
    const l = long ? longsAt(p, st.longUnits + u, lMin) : st.longCount > 0n ? longsAt(p, st.longUnits, lMin) : 0n;
    const sh = long
      ? st.shortCount > 0n ? shortsAt(p, st.shortUnits, st.shortCount, sMax) : 0n
      : shortsAt(p, st.shortUnits + u, st.shortCount + 1n, sMax);
    return l + sh + 2n <= st.balance; // the pool rounds each side up; the open fee, which helps, is left out
  });
}

/// The largest notional that fits, to the dollar, by bisection; 0 while winners are queued.
export function backingRoom(st: RoomState, long: boolean): bigint {
  if (st.totalDebt > 0n || !fits(st, long, 0n)) return 0n;
  let lo = 0n, hi = st.balance * 1_000n;
  if (fits(st, long, hi)) return hi;
  while (hi - lo > 1_000_000n) {
    const mid = (lo + hi) / 2n;
    if (fits(st, long, mid)) lo = mid; else hi = mid;
  }
  return lo;
}
