// node tests/processing.test.js
const assert = require('assert');
const p = require('../processing.js');

// Duration
assert.strictEqual(p.durationMinutes('07:30', '09:50'), 140);
assert.strictEqual(p.durationText(140), '2h 20m');
assert.strictEqual(p.durationMinutes('22:30', '01:10'), 160);     // past midnight
assert.strictEqual(p.durationMinutes('07:30:00', null), null);
assert.strictEqual(p.durationText(null), '—');

// HBT end value = last reading by sort_order
assert.strictEqual(p.hbtEnd([{ id: 3, sort_order: 2, level_hl: 25 }, { id: 9, sort_order: 3, level_hl: 40.5 }, { id: 1, sort_order: 1, level_hl: 10 }]).level_hl, 40.5);
assert.strictEqual(p.hbtEnd([]), null);
assert.strictEqual(p.hbtEnd([{ id: 1, sort_order: 1, level_hl: 10 }, { id: 2, sort_order: 2, level_hl: null }]).level_hl, 10);   // new empty row

// CO2 spec per target from recipe_packaging (mockup: bottle / can 5.5 ±0.0, keg 4.7 ±0.3)
const pack = { co2_bottle_can_spec: 5.5, co2_bottle_can_tolerance: null, co2_keg_spec: 4.7, co2_keg_tolerance: 0.3 };
assert.deepStrictEqual(p.co2Spec(pack, 'can'), { spec: 5.5, tol: 0 });
assert.deepStrictEqual(p.co2Spec(pack, 'keg'), { spec: 4.7, tol: 0.3 });
assert.strictEqual(p.co2Spec(pack, null), null);
assert.strictEqual(p.co2Spec({}, 'keg'), null);
assert.strictEqual(p.co2Status('5.5', p.co2Spec(pack, 'can')), 'OK');
assert.strictEqual(p.co2Status(5.4, p.co2Spec(pack, 'bottle')), 'Low');
assert.strictEqual(p.co2Status(5.0, p.co2Spec(pack, 'keg')), 'OK');
assert.strictEqual(p.co2Status(5.1, p.co2Spec(pack, 'keg')), 'High');
assert.strictEqual(p.co2Status('', p.co2Spec(pack, 'keg')), null);

// O2, turbidity, PU
assert.strictEqual(p.o2High(50), true);
assert.strictEqual(p.o2High('49'), false);
assert.strictEqual(p.o2High(null), false);
assert.strictEqual(p.turbidityHigh(16, 15), true);
assert.strictEqual(p.turbidityHigh(15, 15), false);
assert.strictEqual(p.turbidityHigh(16, null), false);
assert.strictEqual(p.puOutOfSpec(18, 15, '2'), true);
assert.strictEqual(p.puOutOfSpec(16, 15, 2), false);

// Minimum maturation
const m = p.maturation('2026-10-01T08:00:00Z', 5, new Date('2026-10-08T15:12:00Z'));
assert.strictEqual(m.days.toFixed(1), '7.3');
assert.strictEqual(m.ok, true);
assert.strictEqual(p.maturation('2026-10-06T08:00:00Z', 5, new Date('2026-10-08T08:00:00Z')).ok, false);
assert.strictEqual(p.maturation(null, 5).ok, null);

// Cellar loss (mockup: 80.0 hl in GLT − 3.0 hl split − 75.5 hl in HBTs = 1.5 hl)
const loss = p.cellarLoss({ gltVolumeHl: 80, hbtTankIds: [12, 14], hbtEndTotalHl: 75.5,
  transfers: [{ from_tank_id: 7, volume_hl: 3 }, { from_tank_id: 14, volume_hl: 2 }] });
assert.strictEqual(loss.splitsHl, 3);
assert.strictEqual(loss.lossHl.toFixed(1), '1.5');
assert.strictEqual(loss.negative, false);
assert.strictEqual(p.cellarLoss({ gltVolumeHl: 70, hbtEndTotalHl: 75.5 }).negative, true);
assert.strictEqual(p.cellarLoss({ gltVolumeHl: null, hbtEndTotalHl: 10 }).lossHl, null);
// beer in from splits counts with the GLT volume; a split batch has no GLT volume
assert.strictEqual(p.cellarLoss({ gltVolumeHl: 80, incomingHl: 20, hbtEndTotalHl: 98 }).lossHl, 2);
assert.strictEqual(p.cellarLoss({ gltVolumeHl: null, incomingHl: '25.5', hbtEndTotalHl: 25 }).lossHl, 0.5);

console.log('processing: all tests passed');
