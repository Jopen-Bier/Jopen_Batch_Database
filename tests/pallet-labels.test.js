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

// Best before: filling date + months, as 'OCT 2028'
assert.strictEqual(p.bestBeforeText('2026-10-29', 24), 'OCT 2028');
assert.strictEqual(p.bestBeforeText('2026-11-15', 2), 'JAN 2027');
assert.strictEqual(p.bestBeforeText('2026-10-29', null), '');
assert.strictEqual(p.labelDate('2026-10-29'), '29-10-2026');

// Print document: one label per keg sheet, two per bottle/can sheet
const keg = p.palletLabelsHtml({ kind: 'keg', beerName: 'So fresh, so clean', code: 'L26295/18', date: '2026-10-29', bestBefore: 'OCT 2028', sequence: [1, 1, 2] });
assert.strictEqual((keg.match(/<section class="sheet/g) || []).length, 3);
assert.strictEqual((keg.match(/class="lbl keg"/g) || []).length, 3);
assert.ok(keg.includes('L26295/18') && keg.includes('OCT 2028') && keg.includes(p.PALLET_LABEL_NOTE));
const pack = p.palletLabelsHtml({ kind: 'pack', beerName: 'Meesterstuk <2027>', code: 'L26298/17', date: '2026-10-29', sequence: [1, 1] });
assert.strictEqual((pack.match(/class="lbl pack"/g) || []).length, 4);
assert.ok(pack.includes('Meesterstuk &lt;2027&gt;') && pack.includes('29-10-2026'));
assert.ok(!pack.includes('class="order"'));

console.log('pallet-labels: all tests passed');
