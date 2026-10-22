// Deleting a whole batch (All batches, Batch creation). Needs the right
// "Delete batches" (permission module batch_deletion); RLS checks it too.
// The report tables go with the batch (ON DELETE CASCADE); beer received from
// a split and stock movements block the delete, so they are checked first and
// explained. The batch's document files are removed from storage after the row.

const BATCH_DOCUMENTS_BUCKET = 'batch-documents';

/** What links a batch to other records: { id, incoming: [text], outgoing: [batch numbers], stockMovements }. */
async function batchLinks(client, batchNumber) {
  const empty = { id: null, incoming: [], outgoing: [], stockMovements: 0 };
  const { data: batch } = await client.from('batches').select('id').eq('batch_number', String(batchNumber)).maybeSingle();
  if (!batch) return empty;
  const [incoming, outgoing, stock] = await Promise.all([
    client.from('batch_transfers').select('volume_hl, transferred_at, source:batches!batch_transfers_batch_id_fkey(batch_number)').eq('to_batch_id', batch.id),
    client.from('batch_transfers').select('to_batch:batches!batch_transfers_to_batch_id_fkey(batch_number)').eq('batch_id', batch.id).not('to_batch_id', 'is', null),
    client.from('stock_movements').select('id', { count: 'exact', head: true }).eq('batch_id', batch.id),
  ]);
  const day = (at) => new Date(at).toLocaleDateString('en-GB');
  return {
    id: batch.id,
    incoming: (incoming.data || []).map((t) => `${Number(t.volume_hl).toLocaleString('en-GB', { maximumFractionDigits: 1 })} hl from batch ${t.source ? t.source.batch_number : '?'} (${day(t.transferred_at)})`),
    outgoing: [...new Set((outgoing.data || []).map((t) => t.to_batch && t.to_batch.batch_number).filter(Boolean))],
    stockMovements: stock.count || 0,
  };
}

function deleteBlockedText(batchNumber, links) {
  const reasons = [];
  if (links.incoming.length) {
    reasons.push(`It received beer from a split: ${links.incoming.join('; ')}. Delete that transfer first on the source batch (Fermentation log, Processing or Filling report › Splits / transfers).`);
  }
  if (links.stockMovements) {
    reasons.push(`It has ${links.stockMovements} stock movement(s) in the inventory. Remove or rebook those first.`);
  }
  return `Batch ${batchNumber} cannot be deleted.\n\n` + (reasons.join('\n\n') || 'Another record still points to this batch.');
}

/** Confirmation text: what goes with the batch. */
function deleteConfirmText(batchNumber, links) {
  const out = links.outgoing.length
    ? ` This batch transferred beer to ${links.outgoing.join(', ')}: those transfers are deleted too, so that batch loses this incoming beer.`
    : '';
  return `Batch ${batchNumber} is deleted with its whole batch report (brews, fermentation log, processing, filling, documents).${out} This cannot be undone.`;
}

/** Deletes a batch: { ok: true, warning? } or { ok: false, message }. links: from batchLinks (fetched again when left out). */
async function deleteBatch(client, batchNumber, links) {
  links = links || await batchLinks(client, batchNumber);
  if (!links.id) return { ok: false, message: `Batch ${batchNumber} was not found.` };
  if (links.incoming.length || links.stockMovements) return { ok: false, message: deleteBlockedText(batchNumber, links) };
  const docs = await client.from('batch_documents').select('storage_path').eq('batch_id', links.id);
  if (docs.error) return { ok: false, message: 'Could not read the documents: ' + docs.error.message };
  const paths = (docs.data || []).map((d) => d.storage_path).filter(Boolean);
  const { data, error } = await client.from('batches').delete().eq('id', links.id).select('id');
  if (error) {
    return { ok: false, message: error.code === '23503' ? deleteBlockedText(batchNumber, await batchLinks(client, batchNumber)) : 'Could not delete batch: ' + error.message };
  }
  if (!data || !data.length) return { ok: false, message: `Batch ${batchNumber} was not deleted: you do not have the right "Delete batches".` };
  // The files after the row: a failure leaves only unused files, never a batch without its documents.
  if (paths.length) {
    const removed = await client.storage.from(BATCH_DOCUMENTS_BUCKET).remove(paths);
    if (removed.error) return { ok: true, warning: `Batch ${batchNumber} is deleted, but ${paths.length} document file(s) could not be removed from storage: ${removed.error.message}` };
  }
  return { ok: true };
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = { batchLinks, deleteBlockedText, deleteConfirmText, deleteBatch, BATCH_DOCUMENTS_BUCKET };
}
