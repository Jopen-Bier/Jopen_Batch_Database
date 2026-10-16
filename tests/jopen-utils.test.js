// node tests/jopen-utils.test.js
const assert = require('assert');
const { escapeHtml, fetchAllRows, formatDate } = require('../jopen-utils.js');

// escapeHtml: text and attribute contexts, empty values
assert.strictEqual(escapeHtml('Bier & Brood <b>'), 'Bier &amp; Brood &lt;b&gt;');
assert.strictEqual(escapeHtml('Jopen "Kerk" \'WP\''), 'Jopen &quot;Kerk&quot; &#39;WP&#39;');
assert.strictEqual(escapeHtml(null), '');
assert.strictEqual(escapeHtml(undefined), '');
assert.strictEqual(escapeHtml(0), '0');
assert.strictEqual(escapeHtml(26351), '26351');

// formatDate
assert.strictEqual(formatDate(null), '—');
assert.strictEqual(formatDate(''), '—');
assert.strictEqual(formatDate('2026-10-16'), '16 Oct 2026');

// fetchAllRows: fake Supabase query with 2.500 rows → 3 pages
function fakeQuery(total, failOnPage = -1) {
  const calls = [];
  return {
    calls,
    range(from, to) {
      calls.push([from, to]);
      if (calls.length - 1 === failOnPage) return Promise.resolve({ data: null, error: { message: 'boom' } });
      const data = [];
      for (let i = from; i <= Math.min(to, total - 1); i++) data.push({ id: i });
      return Promise.resolve({ data, error: null });
    },
  };
}

(async () => {
  let q = fakeQuery(2500);
  let r = await fetchAllRows(q);
  assert.strictEqual(r.error, null);
  assert.strictEqual(r.data.length, 2500);
  assert.deepStrictEqual(q.calls, [[0, 999], [1000, 1999], [2000, 2999]]);
  assert.strictEqual(r.data[2499].id, 2499);

  q = fakeQuery(1000);                       // exactly one full page → one extra empty call
  r = await fetchAllRows(q);
  assert.strictEqual(r.data.length, 1000);
  assert.strictEqual(q.calls.length, 2);

  q = fakeQuery(0);
  r = await fetchAllRows(q);
  assert.deepStrictEqual(r, { data: [], error: null });

  q = fakeQuery(2500, 1);                    // error on 2nd page → error, no partial data
  r = await fetchAllRows(q);
  assert.strictEqual(r.data, null);
  assert.strictEqual(r.error.message, 'boom');

  console.log('jopen-utils: all tests passed');
})().catch((e) => { console.error(e); process.exit(1); });
