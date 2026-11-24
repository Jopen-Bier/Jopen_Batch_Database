// node tests/jopen-utils.test.js
const assert = require('assert');
const { escapeHtml, fetchAllRows, formatDate, codeFromLabel } = require('../jopen-utils.js');

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

// codeFromLabel: accents dropped, everything else becomes one underscore
assert.strictEqual(codeFromLabel('Dry hop @2 °C'), 'dry_hop_2_c');
assert.strictEqual(codeFromLabel('Box 24x33cl · blank'), 'box_24x33cl_blank');
assert.strictEqual(codeFromLabel('Crème brûlée'), 'creme_brulee');
assert.strictEqual(codeFromLabel('  ·  '), '');
assert.strictEqual(codeFromLabel(null), '');

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

// isPasswordPwned: fake HIBP range API. SHA-1("password") =
// 5BAA61E4C9B93F3F0682250B6CF8331B7EE68FD8 -> prefix 5BAA6, suffix 1E4C9B…
(async () => {
  const { isPasswordPwned } = require('../jopen-utils.js');
  const asked = [];
  const fakeFetch = (body, ok = true) => async (url) => { asked.push(url); return { ok, text: async () => body }; };
  const hit = '0018A45C4D1DEF81644B54AB7F969B88D65:1\r\n1E4C9B93F3F0682250B6CF8331B7EE68FD8:9659365\r\n';
  assert.strictEqual(await isPasswordPwned('password', fakeFetch(hit)), true);
  assert.strictEqual(asked[0], 'https://api.pwnedpasswords.com/range/5BAA6', 'only the 5-character prefix is sent');
  // Padding rows (count 0) never count as a hit
  assert.strictEqual(await isPasswordPwned('password', fakeFetch('1E4C9B93F3F0682250B6CF8331B7EE68FD8:0\r\n')), false);
  assert.strictEqual(await isPasswordPwned('a-long-unique-passphrase-4471', fakeFetch(hit)), false);
  // API down or offline: not a reason to refuse the password
  assert.strictEqual(await isPasswordPwned('password', fakeFetch('', false)), false);
  assert.strictEqual(await isPasswordPwned('password', async () => { throw new Error('offline'); }), false);
  assert.strictEqual(await isPasswordPwned('', fakeFetch(hit)), false);
  console.log('isPasswordPwned: ok');
})().catch((e) => { console.error(e); process.exit(1); });
