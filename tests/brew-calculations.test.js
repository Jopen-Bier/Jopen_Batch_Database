// node tests/brew-calculations.test.js
const assert = require('assert');
const {
  HOP_SG_COLUMNS, HOP_UTILIZATION_TABLE,
  hopWortSg, hopSgColumnIndex, hopUtilizationPct, hopEbu, maltColorEbc,
} = require('../brew-calculations.js');

const close = (actual, expected, msg) =>
  assert.ok(Math.abs(actual - expected) < 1e-9, `${msg}: ${actual} != ${expected}`);

// Table shape: every row has one value per SG column
HOP_UTILIZATION_TABLE.forEach((r) => assert.strictEqual(r.utilizationPct.length, HOP_SG_COLUMNS.length, `row ${r.boilTimeMin}`));

// Wort SG from °P: only the first two characters count, 259 / (259 - P), 2 decimals
assert.strictEqual(hopWortSg(12), 1.05);      // 259/247 = 1.0486
assert.strictEqual(hopWortSg(18.7), 1.07);    // "18" -> 259/241 = 1.0747
assert.strictEqual(hopWortSg('16.2'), 1.07);  // "16" -> 259/243 = 1.0658
assert.strictEqual(hopWortSg(5), 1.02);       // "5" -> 259/254 = 1.0197
assert.strictEqual(hopWortSg(null), null);
assert.strictEqual(hopWortSg(undefined), null);
assert.strictEqual(hopWortSg(''), null);

// SG column: largest column <= SG
assert.strictEqual(hopSgColumnIndex(1.05), 3);
assert.strictEqual(hopSgColumnIndex(1.019), -1);
assert.strictEqual(hopSgColumnIndex(1.2), 11);

// Utilization lookup
assert.strictEqual(hopUtilizationPct(60, 12), 31);     // 60 min, SG 1.05
assert.strictEqual(hopUtilizationPct(60, 15), 27.07);  // 259/244 = 1.06
assert.strictEqual(hopUtilizationPct(10, 20), 7);      // 259/239 = 1.08
assert.strictEqual(hopUtilizationPct(75, 5), null);    // empty cell (SG 1.02, 75 min)
assert.strictEqual(hopUtilizationPct(61, 12), null);   // boil time not in table (exact match)
assert.strictEqual(hopUtilizationPct(60, null), null); // no original extract
assert.strictEqual(hopUtilizationPct(60, 2), null);    // SG 1.01 -> below first column

// EBU: (g*1000) * alpha% * utilization% / liters
// 5000 * 1000 * 0.085 * 0.31 / 4000 = 32.9375
close(hopEbu(5000, 8.5, 60, 12, 40), 32.9375, 'EBU 60 min');
close(hopEbu(1200, 4.2, 10, 20, 85), 1200 * 1000 * 0.042 * 0.07 / 8500, 'EBU 10 min');
assert.strictEqual(hopEbu(5000, 0, 60, 12, 40), 0);           // alpha 0 is a value
assert.strictEqual(hopEbu(5000, null, 60, 12, 40), null);     // alpha unknown
assert.strictEqual(hopEbu(5000, undefined, 60, 12, 40), null);
assert.strictEqual(hopEbu(0, 8.5, 60, 12, 40), null);         // no weight
assert.strictEqual(hopEbu(5000, 8.5, 60, 12, 0), null);       // no volume
assert.strictEqual(hopEbu(5000, 8.5, 61, 12, 40), null);      // no utilization

// Malt color: sum(kg * EBC * 0.08) / hl + 1.75
// (1000*6 + 50*900) * 0.08 / 40 + 1.75 = 102 + 1.75
close(maltColorEbc([{ kg: 1000, ebc: 6 }, { kg: 50, ebc: 900 }], 40), 103.75, 'color');
close(maltColorEbc([{ kg: 1000, ebc: null }, { kg: '', ebc: 900 }], 40), 1.75, 'empty values count as 0');
close(maltColorEbc([], 40), 1.75, 'no malt');
assert.strictEqual(maltColorEbc([{ kg: 1000, ebc: 6 }], 0), null);
assert.strictEqual(maltColorEbc([{ kg: 1000, ebc: 6 }], null), null);

console.log('brew-calculations: ok');
