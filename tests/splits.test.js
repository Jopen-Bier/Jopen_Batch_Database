// node tests/splits.test.js
const assert = require('assert');
const s = require('../splits.js');

// Next batch number of the year (YY + 3 digits)
assert.strictEqual(s.nextBatchNumber('26351', '26'), '26352');
assert.strictEqual(s.nextBatchNumber(null, '27'), '27001');
assert.strictEqual(s.nextBatchNumber('25999', '26'), '26001');   // last year's number does not count

// Log text as split_batch() writes it
assert.strictEqual(s.transferLogText({ volumeHl: 20, tankCode: 'GLT7', destination: 'new', batchNumber: '26352', recipeName: 'Nel Framboos', comment: ' base for blend ' }),
  'Transfer · 20.0 hl from GLT7 to new batch 26352 (Nel Framboos) · base for blend');
assert.strictEqual(s.transferLogText({ volumeHl: '5,5', destination: 'batch', batchNumber: '26420' }), 'Transfer · 5.5 hl to batch 26420');
assert.strictEqual(s.transferLogText({ volumeHl: 2, tankCode: 'HBT12', destination: 'discard', reason: 'tank bottom' }), 'Transfer · 2.0 hl from HBT12 discarded · tank bottom');
assert.strictEqual(s.transferLogText({ volumeHl: 1, destination: 'new' }), 'Transfer · 1.0 hl to new batch … (…)');

// What is left in the tank
const out = [{ from_tank_id: 7, volume_hl: 3 }, { from_tank_id: 12, volume_hl: 1 }];
assert.strictEqual(s.tankAfterTransfer(80, out, 7, '20'), 57);
assert.strictEqual(s.tankAfterTransfer(null, out, 7, 20), null);

// Incoming and base beer check: Mooie Nel 70 % + Bokbier 30 %
assert.strictEqual(s.incomingTotalHl([{ volume_hl: 12 }, { hl: '8' }]), 20);
const base = [{ source_recipe_group_id: 'nel', quantity: 70 }, { source_recipe_group_id: 'bok', quantity: '30' }];
const c = s.baseBeerCheck(base, [{ groupId: 'nel', hl: 14 }, { groupId: 'bok', hl: 4 }, { groupId: 'xpa', hl: 2 }]);
assert.strictEqual(c.totalHl, 20);
assert.deepStrictEqual(c.rows.map((r) => [r.groupId, r.sharePct, r.expectedHl, r.actualHl]), [['nel', 70, 14, 14], ['bok', 30, 6, 4]]);
assert.deepStrictEqual(c.unexpected, ['xpa']);
assert.deepStrictEqual(s.baseBeerCheck([], [{ groupId: 'nel', hl: 5 }]), { rows: [], unexpected: [], totalHl: 5 });

console.log('splits: all tests passed');
