// node tests/batch-brews.test.js
const assert = require('assert');
const b = require('../batch-brews.js');

const close = (a, e, msg) => assert.ok(Math.abs(a - e) < 1e-6, `${msg}: ${a} ≠ ${e}`);

// Rows: every input row is a batch_brews column; brewhouse filter
const keys = b.BREW_LOG_ROWS.filter((r) => r.kind !== 'section' && r.kind !== 'calc').map((r) => r.key);
assert.strictEqual(new Set(keys).size, keys.length, 'no duplicate rows');
assert.ok(b.brewLogRows('wp').some((r) => r.key === 'cumulative_sparge_volume_hl'));
// Wort cooling temp. between Aeration and Water addition, against the recipe pitching temp (wishlist #11)
const order = b.BREW_LOG_ROWS.map((r) => r.key);
assert.strictEqual(order.indexOf('wort_cooling_temp_c'), order.indexOf('aeration_ppm') + 1);
assert.strictEqual(order.indexOf('water_addition_hl'), order.indexOf('wort_cooling_temp_c') + 1);
assert.strictEqual(b.BREW_LOG_ROWS.find((r) => r.key === 'wort_cooling_temp_c').recipe, 'pitching_temp');
assert.strictEqual(b.BREW_LOG_ROWS.find((r) => r.key === 'boil_time_min').recipe, 'boil_time_min');
// Filtration time from start/end (wishlist #24)
assert.ok(b.BREW_LOG_ROWS.find((r) => r.key === 'lauter_time_min').timeSpan);
assert.strictEqual(b.minutesBetween('10:15', '12:05'), 110);
assert.strictEqual(b.minutesBetween('23:40', '01:10'), 90);
assert.strictEqual(b.minutesBetween('8:00', '8:00'), 0);
assert.strictEqual(b.minutesBetween('10:15', ''), null);
assert.strictEqual(b.minutesBetween('25:00', '10:00'), null);
assert.ok(!b.brewLogRows('wp').some((r) => r.key === 'ckt_cip_program'));
assert.ok(b.brewLogRows('jk').some((r) => r.key === 'ckt_cip_program'));
assert.ok(!b.brewLogRows('jk').some((r) => r.label === 'Filtration · mash filter'));
assert.ok(!b.brewLogRows(null).some((r) => r.only));

// Single values
close(b.evaporationPct(14.6, 15.1), (15.1 - 14.6) / 14.6 * 100, 'evaporation');
assert.strictEqual(b.evaporationPct(null, 15), null);
assert.strictEqual(b.evaporationPct(0, 15), null);
close(b.volumeToGlt(40.1, 0.3), 40.4, 'volume to GLT');
close(b.volumeToGlt('40,0', null), 40, 'volume to GLT, comma, no water');
assert.strictEqual(b.volumeToGlt(null, 0.3), null);
close(b.extractToGlt(15.2, 40.1, 0.3), 15.2 * 40.1 / 40.4, 'extract to GLT');
assert.strictEqual(b.pauseMinutes('00:20'), 20);
assert.strictEqual(b.pauseMinutes('1:05'), 65);
assert.strictEqual(b.pauseMinutes('20 min'), 0);
close(b.totalBrewingHours('2026-09-27T22:30', '2026-09-28T05:40'), 7 + 10 / 60, 'brewing time');
close(b.totalBrewingHours('2026-09-27T22:30', '2026-09-28T05:40', '00:20'), 6 + 50 / 60, 'brewing time minus pause');
assert.strictEqual(b.totalBrewingHours('2026-09-28T05:40', '2026-09-27T22:30'), null);
assert.strictEqual(b.totalBrewingHours(null, '2026-09-28T05:40'), null);

// Two brews of the mockup (Mooie Nel), given out of order
const calc = b.brewCalculations([
  { brew_number: 2, brew_volume_hl: 40.0, water_addition_hl: 0.2, whirlpool_extract: 15.1, whirlpool_ph: 5.15, boil_start_extract: 14.5, boil_end_extract: 15.0 },
  { brew_number: 1, brew_volume_hl: 40.1, water_addition_hl: 0.3, whirlpool_extract: 15.2, whirlpool_ph: 5.16, boil_start_extract: 14.6, boil_end_extract: 15.1,
    mash_in_started_at: '2026-09-27T22:30', brewing_ended_at: '2026-09-28T05:40' },
]);
assert.deepStrictEqual(calc.map((c) => c.brewNumber), [1, 2]);
close(calc[0].glt.volumeHl, 40.4, 'GLT after brew 1');
close(calc[0].glt.extract, 15.2 * 40.1 / 40.4, 'GLT extract after brew 1');
close(calc[1].glt.volumeHl, 80.6, 'GLT after brew 2');
const ex1 = 15.2 * 40.1 / 40.4, ex2 = 15.1 * 40 / 40.2;
close(calc[1].glt.extract, (40.4 * ex1 + 40.2 * ex2) / 80.6, 'GLT extract volume-weighted');
assert.strictEqual(calc[1].glt.brews, 2);
assert.ok(!('ph' in calc[1].glt), 'no GLT pH: a pH cannot be averaged');
// GLT total in spec: extract vs OG ± tol, volume vs brews × brew volume ± 0.5 hl per brew
const g = calc[1].glt;   // 80.6 hl, ~15.07 °P
assert.deepStrictEqual(b.gltTotalCheck(g, 15, '0.2', 40), { extractOk: true, volumeOk: true, plannedHl: 80, volumeTolHl: 1 });
assert.strictEqual(b.gltTotalCheck(g, 15.5, '±0.2', 40).extractOk, false);
assert.strictEqual(b.gltTotalCheck(g, 15, '0.2', 39.5).volumeOk, false);   // 79 ± 1
assert.deepStrictEqual(b.gltTotalCheck(null, 15, '0.2', 40), { extractOk: null, volumeOk: null, plannedHl: null, volumeTolHl: 0 });
assert.strictEqual(b.gltTotalCheck(g, null, null, null).extractOk, null);
close(calc[0].totalBrewingH, 7 + 10 / 60, 'total brewing time brew 1');
assert.strictEqual(calc[1].totalBrewingH, null);
// a brew without volume does not count for the GLT total
const partial = b.brewCalculations([{ brew_number: 1, brew_volume_hl: 40, whirlpool_extract: 15 }, { brew_number: 2 }]);
close(partial[1].glt.volumeHl, 40, 'GLT ignores incomplete brew');
assert.strictEqual(b.brewCalculations([{ brew_number: 1 }])[0].glt.volumeHl, null);

// Spec checks
assert.strictEqual(b.toleranceValue('±0.5'), 0.5);
assert.strictEqual(b.toleranceValue('0,2'), 0.2);
assert.strictEqual(b.toleranceValue(''), null);
assert.strictEqual(b.withinSpec(15.4, 15, 0.5), true);
assert.strictEqual(b.withinSpec(15.5, 15, 0.5), true);
assert.strictEqual(b.withinSpec(15.6, 15, 0.5), false);
assert.strictEqual(b.withinSpec(40.4, 40, b.VOLUME_TOL_HL), true);
assert.strictEqual(b.withinSpec(null, 15, 0.5), null);
assert.strictEqual(b.withinSpec(15, null, 0.5), null);

assert.strictEqual(b.nextBrewNumber([]), 1);
assert.strictEqual(b.nextBrewNumber([{ brew_number: 1 }, { brew_number: 3 }]), 4);

console.log('batch-brews: all tests passed');
