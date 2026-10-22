// node tests/batch-delete.test.js
const assert = require('assert');
const d = require('../batch-delete.js');

// A fake Supabase client: answers per table, records deletes and storage removals.
function fakeClient({ batch = { id: 7 }, incoming = [], outgoing = [], stock = 0, docs = [], deleted = [{ id: 7 }],
                      deleteError = null, storageError = null } = {}) {
  const calls = [];
  const query = (table) => {
    const q = { table, filters: [], op: 'select' };
    const result = () => {
      if (table === 'batches' && q.op === 'delete') return { data: deleteError ? null : deleted, error: deleteError };
      if (table === 'batches') return { data: batch, error: null };
      if (table === 'batch_transfers') {
        return { data: q.filters.some((f) => f[0] === 'to_batch_id') ? incoming : outgoing, error: null };
      }
      if (table === 'stock_movements') return { count: stock, error: null };
      if (table === 'batch_documents') return { data: docs, error: null };
      return { data: [], error: null };
    };
    const p = {
      select() { return p; },
      eq(col, v) { q.filters.push([col, v]); return p; },
      not() { return p; },
      maybeSingle() { return Promise.resolve(result()); },
      delete() { q.op = 'delete'; calls.push(['delete', table]); return p; },
      then(res, rej) { return Promise.resolve(result()).then(res, rej); },
    };
    return p;
  };
  return {
    calls,
    from: query,
    storage: { from: (bucket) => ({ remove: (paths) => { calls.push(['remove', bucket, paths]); return Promise.resolve({ error: storageError }); } }) },
  };
}

(async () => {
  // Plain batch with two documents: row deleted, then its files.
  let c = fakeClient({ docs: [{ storage_path: '7/other/a.pdf' }, { storage_path: '7/filling_report/b.pdf' }] });
  assert.deepStrictEqual(await d.deleteBatch(c, '26093'), { ok: true });
  assert.deepStrictEqual(c.calls, [['delete', 'batches'], ['remove', 'batch-documents', ['7/other/a.pdf', '7/filling_report/b.pdf']]]);

  // Beer received from a split blocks the delete; nothing is touched.
  c = fakeClient({ incoming: [{ volume_hl: 40, transferred_at: '2026-04-09T10:00:00Z', source: { batch_number: '26093' } }] });
  let r = await d.deleteBatch(c, '26132');
  assert.strictEqual(r.ok, false);
  assert.ok(r.message.includes('40 hl from batch 26093'), r.message);
  assert.deepStrictEqual(c.calls, []);

  // Stock movements block too.
  c = fakeClient({ stock: 3 });
  r = await d.deleteBatch(c, '26001');
  assert.ok(!r.ok && r.message.includes('3 stock movement(s)'), r.message);

  // RLS: no right -> 0 rows deleted, no files removed.
  c = fakeClient({ deleted: [], docs: [{ storage_path: 'x.pdf' }] });
  r = await d.deleteBatch(c, '26001');
  assert.ok(!r.ok && r.message.includes('Delete batches'), r.message);
  assert.deepStrictEqual(c.calls, [['delete', 'batches']]);

  // Files that cannot be removed: the batch is still deleted, with a warning.
  c = fakeClient({ docs: [{ storage_path: 'x.pdf' }], storageError: { message: 'denied' } });
  r = await d.deleteBatch(c, '26001');
  assert.ok(r.ok && r.warning.includes('1 document file(s)'), JSON.stringify(r));

  // Unknown batch.
  r = await d.deleteBatch(fakeClient({ batch: null }), '29999');
  assert.ok(!r.ok && r.message.includes('not found'));

  // Confirmation text names the batches that lose incoming beer.
  const text = d.deleteConfirmText('26093', { outgoing: ['26132', '26133'] });
  assert.ok(text.includes('26132, 26133') && text.includes('cannot be undone'));

  console.log('batch-delete: ok');
})().catch((e) => { console.error(e); process.exit(1); });
