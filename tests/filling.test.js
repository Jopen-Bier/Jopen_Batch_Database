// node tests/filling.test.js
const assert = require('assert');
const f = require('../filling.js');

// Limits: recipe values, else the house maxima; CO2 = spec ± tol
// CO2 per package from recipe_specs (Mooie Nel: bottle 5.5 ±0.1, can 5.0 ±0.2, keg 4.7, tolerance '-')
const specs = { co2_bottle: 5.5, co2_bottle_tol: '0.1', co2_can: 5, co2_can_tol: '0.2', co2_keg: 4.7, co2_keg_tol: '-' };
const lim = f.fillingLimits({ do_spec: 40 }, specs, 'bottle');
assert.deepStrictEqual(f.fillingLimits({}, specs, 'can').co2_gl, { lo: 4.8, hi: 5.2 });
assert.deepStrictEqual(lim.tpo_ppb, { lo: null, hi: 100 });
assert.deepStrictEqual(lim.do_ppb, { lo: null, hi: 40 });
assert.strictEqual(lim.co2_gl.lo.toFixed(2), '5.40');
assert.strictEqual(lim.co2_gl.hi.toFixed(2), '5.60');
assert.deepStrictEqual(lim.keg_co2_gl, { lo: 4.7, hi: 4.7 });
assert.strictEqual(f.fillingLimits({}, {}, 'bottle').co2_gl, null);
assert.deepStrictEqual(f.fillingLimits(null).keg_o2_ppb, { lo: null, hi: 50 });

// Out of spec: a maximum is "< limit"; a band includes its ends
assert.strictEqual(f.outOfSpec(100, lim.tpo_ppb), true);
assert.strictEqual(f.outOfSpec('99', lim.tpo_ppb), false);
assert.strictEqual(f.outOfSpec(5.6, lim.co2_gl), false);
assert.strictEqual(f.outOfSpec(5.65, lim.co2_gl), true);
assert.strictEqual(f.outOfSpec(5.35, lim.co2_gl), true);
assert.strictEqual(f.outOfSpec(5.0, null), false);
assert.strictEqual(f.outOfSpec('', lim.tpo_ppb), false);

// Normal distribution
assert.strictEqual(f.phi(0).toFixed(3), '0.500');
assert.strictEqual(f.phi(1.96).toFixed(3), '0.975');

// Capability: maximum only, and a band
const tpo = f.capability([80, 95, 70, 88], { lo: null, hi: 100 });
assert.strictEqual(tpo.n, 4);
assert.strictEqual(tpo.mean.toFixed(2), '83.25');
assert.strictEqual(tpo.sd.toFixed(2), '10.75');   // sqrt(346.75 / 3)
assert.strictEqual(tpo.cpk.toFixed(2), '0.52');
assert.strictEqual(f.cpkClass(tpo.cpk), 'bad');
const co2 = f.capability([5.5, 5.52, 5.48, 5.5], { lo: 5.4, hi: 5.6 });
assert.strictEqual(co2.cpk.toFixed(2), '2.04');
assert.strictEqual(f.cpkClass(co2.cpk), 'ok');
assert.ok(co2.inSpec > 0.99);
assert.strictEqual(f.cpkClass(1.1), 'warn');
assert.deepStrictEqual(f.capability([5], { lo: 5.4, hi: 5.6 }), { n: 1, mean: null, sd: null, cpk: null, inSpec: null });
assert.strictEqual(f.capability([5, 6], null).cpk, null);

// Quality rows over the measurements of the batch
const rows = f.qualityRows([{ tpo_ppb: 80, co2_gl: 5.5 }, { tpo_ppb: 95, co2_gl: 5.45 }, { keg_co2_gl: 4.7 }], {});
assert.deepStrictEqual(rows.map((r) => [r.label, r.n]), [['CO2 bottle', 2], ['CO2 can', 0], ['HSO bottle/can', 0], ['DO bottle/can', 0], ['TPO bottle/can', 2], ['CO2 keg', 1], ['Oxygen keg', 0]]);
assert.strictEqual(rows[0].cpk, null);          // no CO2 spec in the recipe
assert.ok(rows[4].cpk !== null);
// CO2 split by the package of the session, each against its own spec
const byFormat = f.qualityRows([{ s: 'bottle', co2_gl: 5.5 }, { s: 'bottle', co2_gl: 5.52 }, { s: 'can', co2_gl: 5.0 }, { s: 'can', co2_gl: 5.05 }], {}, specs, (m) => m.s);
assert.deepStrictEqual([byFormat[0].n, byFormat[0].limit], [2, lim.co2_gl]);
assert.deepStrictEqual([byFormat[1].n, byFormat[1].limit], [2, { lo: 4.8, hi: 5.2 }]);

// HBT filling status
const sessions = [{ batch_hbt_id: 1, is_hbt_finished: true }, { batch_hbt_id: 2, is_hbt_finished: false }];
assert.strictEqual(f.hbtFillStatus({ id: 1 }, sessions), 'finished');
assert.strictEqual(f.hbtFillStatus({ id: 2 }, sessions), 'filling');
assert.strictEqual(f.hbtFillStatus({ id: 3 }, sessions), 'not_started');

// Day number = day of the year, three digits (Jaap, 20-10)
assert.strictEqual(f.dayNumber('2026-01-01'), '001');
assert.strictEqual(f.dayNumber('2026-10-06'), '279');
assert.strictEqual(f.dayNumber(new Date(2026, 9, 6, 23, 30)), '279');
assert.strictEqual(f.dayNumber('2026-12-31'), '365');
assert.strictEqual(f.dayNumber('2024-12-31'), '366');   // leap year
assert.strictEqual(f.dayNumber(null), null);

console.log('filling: all tests passed');
