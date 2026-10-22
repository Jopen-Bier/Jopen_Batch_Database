// node tests/dosing-checks.test.js
const assert = require('assert');
const d = require('../dosing-checks.js');

const brews = [{ id: 12, brew_number: 2 }, { id: 11, brew_number: 1 }, { id: 13, brew_number: 3 }];

// a line per brew: a tick box in every brew; "all in the first brew": brew 1 only
assert.deepStrictEqual(d.brewColumns({ all_in_first_brew: false }, brews).map((c) => [c.brew.brew_number, c.applies]), [[1, true], [2, true], [3, true]]);
assert.deepStrictEqual(d.brewColumns({ all_in_first_brew: true }, brews).map((c) => [c.brew.brew_number, c.applies]), [[1, true], [2, false], [3, false]]);
assert.deepStrictEqual(d.brewColumns({}, []), []);

// ticks
const checks = [
  { id: 1, batch_ingredient_id: 501, batch_brew_id: 11, checked_by: 'u1', checked_at: '2026-09-07T02:31:00Z' },
  { id: 2, batch_ingredient_id: 501, batch_brew_id: 12, checked_by: 'u2', checked_at: '2026-09-07T05:00:00Z' },
  { id: 3, batch_ingredient_id: 601, batch_hbt_id: 51, checked_by: 'u1', checked_at: '2026-10-01T08:00:00Z' },
];
assert.strictEqual(d.dosingCheck(checks, 501, 'brew', 12).id, 2);
assert.strictEqual(d.dosingCheck(checks, 501, 'brew', 13), null);
assert.strictEqual(d.dosingCheck(checks, 601, 'hbt', 51).id, 3);
assert.strictEqual(d.dosingCheck(checks, 601, 'brew', 51), null, 'a brew id is not an HBT id');

// progress over lines x targets: line 501 in 3 brews, line 502 brew 1 only
const lines = [{ id: 501, all_in_first_brew: false }, { id: 502, all_in_first_brew: true }];
const targets = (line) => d.brewColumns(line, brews).filter((c) => c.applies).map((c) => c.brew.id);
assert.deepStrictEqual(d.dosingProgress(lines, 'brew', targets, checks), { done: 2, total: 4 });
assert.deepStrictEqual(d.dosingProgress([{ id: 601 }], 'hbt', () => [51, 52], checks), { done: 1, total: 2 });

// tooltip
const initials = (id) => ({ u1: 'JL', u2: 'FH' }[id] || '');
assert.match(d.dosingTitle(checks[0], initials), /^JL · 07-09 \d\d:31$/);
assert.strictEqual(d.dosingTitle(null, initials), '');

console.log('dosing-checks: all tests passed');
