// node tests/report-comments.test.js
const assert = require('assert');
const { reportCommentLines, reportCommentCells, REPORT_COMMENT_ROWS, REPORT_COMMENT_LINE_WIDTH } = require('../report-comments.js');

// 1. Empty / missing comments: nothing to write
assert.deepStrictEqual(reportCommentLines(null), []);
assert.deepStrictEqual(reportCommentLines([]), []);
assert.deepStrictEqual(reportCommentLines(['', '  ']), []);

// 2. Mooie Nel: one long comment wraps over several rows, extra spaces collapse
const mooieNel = 'LET OP: pH correcton in the Wort Copper only during the 3d boiling (to achive higher hop utilization). wMooieNel,     goods entry - MooieNel Mix BH. If you have problems with filtration add 150ml Ultraflow. This is a mash test.';
let lines = reportCommentLines([mooieNel]);
assert.strictEqual(lines.length, 3);
lines.forEach((l) => assert.ok(l.length <= REPORT_COMMENT_LINE_WIDTH, l));
assert.strictEqual(lines.join(' '), mooieNel.replace(/\s+/g, ' '));

// 3. Each comment and each line break starts on a new row
lines = reportCommentLines(['Add salts at the end.', 'Yeast: 50 g/hl\nNO Ultraflow']);
assert.deepStrictEqual(lines, ['Add salts at the end.', 'Yeast: 50 g/hl', 'NO Ultraflow']);

// 4. A word longer than the width is cut, not lost
lines = reportCommentLines(['x'.repeat(10) + ' ab'], 4);
assert.deepStrictEqual(lines, ['xxxx', 'xxxx', 'xx', 'ab']);

// 5. Overflow goes into the last row, nothing is dropped
lines = reportCommentLines(['a', 'b', 'c', 'd'], 75, 3);
assert.deepStrictEqual(lines, ['a', 'b', 'c d']);

// 6. Cells start at Brew Sheet!A44, only rows with text, never past row 52
const cells = reportCommentCells(['one', 'two']);
assert.deepStrictEqual(cells, [
  { cell: 'Brew Sheet!A44', value: 'one', styleFrom: null },
  { cell: 'Brew Sheet!A45', value: 'two', styleFrom: null },
]);
const many = reportCommentCells(Array.from({ length: 20 }, (_, i) => `c${i}`));
assert.strictEqual(many.length, REPORT_COMMENT_ROWS);
assert.strictEqual(many[many.length - 1].cell, 'Brew Sheet!A52');
// Centred template rows 46-51 take the left-aligned style of A45; 52 keeps its border
assert.deepStrictEqual(many.map((c) => c.styleFrom), [null, null, ...Array(6).fill('Brew Sheet!A45'), null]);

console.log('report-comments: all tests passed');
