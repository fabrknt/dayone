// node --test keeper/krx.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { marketStatus } from './krx.mjs';

// a KST wall-clock time as a unix timestamp
const kst = (y, m, d, h, min = 0) => Date.UTC(y, m - 1, d, h, min) / 1000 - 9 * 3600;
const status = (...a) => marketStatus(kst(...a)).status;

test('regular session 09:00-15:30 KST', () => {
  assert.equal(status(2026, 10, 19, 8, 59), 'CLOSED');
  assert.equal(status(2026, 10, 19, 9, 0), 'OPEN');
  assert.equal(status(2026, 10, 19, 15, 29), 'OPEN');
  assert.equal(status(2026, 10, 19, 15, 30), 'CLOSED');
});

test('weekends and holidays are closed', () => {
  assert.equal(status(2026, 10, 17, 11), 'CLOSED'); // Saturday
  assert.equal(status(2026, 10, 9, 11), 'CLOSED'); // Hangeul Day
  assert.equal(status(2026, 9, 24, 11), 'CLOSED'); // Chuseok
  assert.equal(status(2026, 12, 31, 11), 'CLOSED'); // year-end closing
  assert.equal(status(2026, 10, 8, 11), 'OPEN');
});

test('CSAT day moves the session an hour later', () => {
  assert.equal(status(2026, 11, 19, 9, 30), 'CLOSED');
  assert.equal(status(2026, 11, 19, 16, 0), 'OPEN');
  assert.equal(status(2026, 11, 19, 16, 30), 'CLOSED');
});

test('the day boundary is KST, not UTC', () => {
  // 2026-10-19 00:30 UTC is 09:30 KST on Monday
  assert.equal(marketStatus(Date.UTC(2026, 9, 19, 0, 30) / 1000).status, 'OPEN');
  assert.equal(marketStatus(kst(2026, 10, 19, 10)).session_open_ts, kst(2026, 10, 19, 9));
});

test('outside the calendar it refuses rather than guessing', () => {
  assert.throws(() => marketStatus(kst(2027, 1, 4, 10)));
});
