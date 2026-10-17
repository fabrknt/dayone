// Korea Exchange (KOSPI/KOSDAQ) regular session, same shape as campana.mjs: status is a pure
// function of (unix timestamp, calendar). Used for xyz:SKHX and xyz:SMSN.
//
// Regular session 09:00-15:30 KST (UTC+9, no daylight saving). Calendar checked 2026-10-17
// against two holiday listings that agree (17 weekday closures) and the 2027 CSAT date; confirm
// against KRX's own notices before relying on it.

export const STATUS = Object.freeze({ OPEN: 'OPEN', CLOSED: 'CLOSED' });

export const KRX_2026 = {
  version: 2026_01,
  validFrom: Date.UTC(2026, 0, 1) / 1000 - 9 * 3600,
  validUntil: Date.UTC(2027, 0, 1) / 1000 - 9 * 3600,
  holidays: [
    '2026-01-01', '2026-02-16', '2026-02-17', '2026-02-18', '2026-03-02', '2026-05-01',
    '2026-05-05', '2026-05-25', '2026-06-03', '2026-07-17', '2026-08-17', '2026-09-24',
    '2026-09-25', '2026-10-05', '2026-10-09', '2026-12-25', '2026-12-31',
  ],
  // [open, close] in minutes after midnight KST, for days that differ from 09:00-15:30
  special: {
    '2026-01-02': [10 * 60, 15 * 60 + 30], // first trading day opens an hour late
    '2026-11-19': [10 * 60, 16 * 60 + 30], // CSAT: the whole session moves an hour later
  },
};

const OPEN_MIN = 9 * 60, CLOSE_MIN = 15 * 60 + 30, KST = 9 * 3600;
const pad = (n) => String(n).padStart(2, '0');

export function marketStatus(ts, cal = KRX_2026) {
  if (ts < cal.validFrom || ts >= cal.validUntil) throw new Error(`KRX calendar ${cal.version} does not cover ${ts}`);
  const w = new Date((ts + KST) * 1000);
  const date = `${w.getUTCFullYear()}-${pad(w.getUTCMonth() + 1)}-${pad(w.getUTCDate())}`;
  const min = w.getUTCHours() * 60 + w.getUTCMinutes();
  const wday = w.getUTCDay();
  const dayKind = wday === 0 || wday === 6 ? 'weekend' : cal.holidays.includes(date) ? 'holiday' : 'trading';
  const [open, close] = cal.special[date] ?? [OPEN_MIN, CLOSE_MIN];
  const isOpen = dayKind === 'trading' && min >= open && min < close;
  const midnight = Date.UTC(w.getUTCFullYear(), w.getUTCMonth(), w.getUTCDate()) / 1000 - KST;
  return {
    market_id: 'KRX_REGULAR',
    status: isOpen ? STATUS.OPEN : STATUS.CLOSED,
    dateKST: date,
    dayKind,
    session_open_ts: isOpen ? midnight + open * 60 : null,
    session_close_ts: isOpen ? midnight + close * 60 : null,
    calendar_version: cal.version,
  };
}
