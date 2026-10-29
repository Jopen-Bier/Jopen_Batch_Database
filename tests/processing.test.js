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
assert.deepStrictEqual(p.co2Spec(pack, 'tank'), { spec: 4.7, tol: 0.3 });   // tank beer: keg spec
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

// Day an HBT was filled: first processing date of its readings' sessions, else the row's day
const sess = [{ id: 1, processing_date: '2026-10-14' }, { id: 2, processing_date: '2026-10-01' }];
const rd = [{ batch_hbt_id: 5, processing_session_id: 1 }, { batch_hbt_id: 5, processing_session_id: 2 }, { batch_hbt_id: 6, processing_session_id: null }];
assert.strictEqual(p.hbtFilledOn({ id: 5 }, rd, sess), '2026-10-01');
assert.strictEqual(p.hbtFilledOn({ id: 6, created_at: '2026-10-20T08:00:00Z' }, rd, sess), '2026-10-20');
assert.strictEqual(p.hbtFilledOn({ id: 7 }, rd, sess), null);



// E-mail summary (wishlist #30)
{
  const sum = p.processingSummary({
    batchNumber: '26301', beerName: 'Mooie Nel',
    sessions: [{ number: 1, date: '28-10-2026', start: '07:30', end: '11:00', tank: 'LT12', operators: 'EVL / DS',
      centrifugeIn: { time: '07:45', o2: 12, co2: 5.1 }, centrifugeOut: { time: '10:50', o2: null, co2: 5.2 }, startFlow: 60, startTurbidity: 0.8 }],
    hbts: [{ name: 'HBT3', formats: 'Can', end: { hl: 120.5, o2: 20, co2: 5.4 }, readings: [{ hl: 60, o2: 18, co2: 5.3, flow: 55, turbidity: 0.6 }] }],
    tasting: { result: 'go', comment: 'Clean <fruity>' },
    comments: [{ time: '09:10', text: 'Bypass opened', by: 'DS' }],
  });
  assert.strictEqual(sum.subject, 'Processing 26301 Mooie Nel');
  assert.ok(sum.text.includes('Session 1 · 28-10-2026 · 07:30–11:00 · from LT12 · EVL / DS'));
  assert.ok(sum.text.includes('Centrifuge out 10:50: O2 —, CO2 5.2 g/l'));
  assert.ok(sum.text.includes('HBT3 (Can): 120.5 hl · O2 20 ppb · CO2 5.4 g/l'));
  assert.ok(sum.text.includes('Tasting: Go · Clean <fruity>'));
  assert.ok(sum.text.includes('09:10 Bypass opened (DS)'));
  assert.ok(sum.html.includes('Clean &lt;fruity&gt;') && !sum.html.includes('<fruity>'));
  assert.ok(sum.html.includes('<td style="padding:4px 8px;border-bottom:1px solid #ddd;">55</td>'));
  const empty = p.processingSummary({ batchNumber: '1', beerName: '', sessions: [], hbts: [], tasting: {}, comments: [] });
  assert.strictEqual(empty.subject, 'Processing 1');
  assert.ok(empty.text.includes('Tasting: —'));
}

console.log('processing: all tests passed');
