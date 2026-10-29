// node tests/pallet-labels.test.js
const assert = require('assert');
const p = require('../pallet-labels.js');

// 2 labels per pallet × 10 pallets = 20 sheets, numbered 1-10, two of each
const seq = p.palletLabelSequence(2, 10);
assert.strictEqual(seq.length, 20);
assert.deepStrictEqual(seq.slice(0, 4), [1, 1, 2, 2]);
assert.strictEqual(seq[19], 10);
assert.deepStrictEqual(p.palletLabelSequence(1, 3), [1, 2, 3]);
assert.deepStrictEqual(p.palletLabelSequence(0, 3), []);
assert.deepStrictEqual(p.palletLabelSequence(2, 1.5), []);
assert.deepStrictEqual(p.palletLabelSequence(10, 100), []);   // more than 500 sheets: refused

// Batch code L<batch>/<HBT>
assert.strictEqual(p.palletBatchCode('26295', 18), 'L26295/18');
assert.strictEqual(p.palletBatchCode('26295', null), 'L26295');

assert.strictEqual(p.labelDate('2026-10-29'), '29-10-2026');
// THT date = filling date + months (x years × 12)
assert.strictEqual(p.thtDate('2026-10-29', 24), '2028-10-29');
assert.strictEqual(p.thtDate('2027-01-31', 1), '2027-02-28');
assert.strictEqual(p.thtDate('2028-02-29', 12), '2029-02-28');
assert.strictEqual(p.thtDate('2026-10-29', ''), '');
// Kegs show month and year only, bottle / can the full date
assert.strictEqual(p.bestBeforeLabel('2028-10-29', 'keg'), 'OCT 2028');
assert.strictEqual(p.bestBeforeLabel('2028-10-29', 'can'), '29-10-2028');
assert.strictEqual(p.bestBeforeLabel('', 'keg'), '');

// Print document: same layout for every package; one label per keg sheet, two per bottle/can sheet
const keg = p.palletLabelsHtml({ format: 'keg', beerName: 'So fresh, so clean', code: 'L26295/18', tht: '2027-04-29', sequence: [1, 1, 2] });
assert.strictEqual((keg.match(/<section class="sheet one/g) || []).length, 3);
assert.strictEqual((keg.match(/class="lbl"/g) || []).length, 3);
assert.ok(keg.includes('L26295/18') && keg.includes('Best Before <b>APR 2027</b>') && keg.includes(p.PALLET_LABEL_NOTE));
const can = p.palletLabelsHtml({ format: 'can', beerName: 'Meesterstuk <2027>', code: 'L26298/17', tht: '2027-10-29', sequence: [1, 1] });
assert.strictEqual((can.match(/<section class="sheet two/g) || []).length, 2);
assert.strictEqual((can.match(/class="lbl"/g) || []).length, 4);
assert.ok(can.includes('Meesterstuk &lt;2027&gt;') && can.includes('Best Before <b>29-10-2027</b>'));
assert.ok(can.indexOf('fit beer') < can.indexOf('fit code') && can.indexOf('fit code') < can.indexOf('fit bb'));

console.log('pallet-labels: all tests passed');
