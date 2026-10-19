// node web/room.test.mjs — the page's backing room against numbers the contract test
// test_r12_roomMatchesBacking settles and refuses (same state: a $100K long at $455, oracle back at $350).
import { readFileSync } from "node:fs";
import { stripTypeScriptTypes } from "node:module";
const src = stripTypeScriptTypes(readFileSync(new URL("./src/room.ts", import.meta.url), "utf8"));
const { backingRoom, fits } = await import("data:text/javascript," + encodeURIComponent(src));

const st = {
  oracle: 350n * 10n ** 18n, balance: 10_050_000_000n, totalDebt: 0n,
  stressed: [385n * 10n ** 18n + 1n, 315n * 10n ** 18n],
  longMin: 455n * 10n ** 18n, shortMax: 0n, longCount: 1n, shortCount: 0n,
  longUnits: 219_780_220n, shortUnits: 0n,
};
let ok = true;
const check = (name, cond) => { console.log(`${cond ? "ok  " : "FAIL"} ${name}`); ok &&= cond; };
const room = backingRoom(st, true);
console.log(`room for new longs: $${Number(room) / 1e6}`);
// the old long re-priced from $350: (10,050 - 219.78 x 35) / 10% = $23,576
check("long room is about $23,576, not the $100,500 the old formula showed", room > 23_500_000_000n && room < 23_600_000_000n);
check("$23,570 fits (the contract settles it)", fits(st, true, 23_570_000_000n));
check("$23,800 does not (the contract refuses it)", !fits(st, true, 23_800_000_000n));
check("shorts: +10% is the longs' problem; a new short only adds on the way down", backingRoom(st, false) > 0n);
check("nothing while a winner is queued", backingRoom({ ...st, totalDebt: 1n }, true) === 0n);
process.exit(ok ? 0 : 1);
