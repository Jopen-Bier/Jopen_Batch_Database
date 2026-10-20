// ============================================================================
// batch-report-cards.js — parts shared by several batch tabs (Fermentation
// log, Processing, later Filling report): the "Splits / transfers out" card
// (batch_transfers) and the cellar calculators window (Nagardo, PGA /
// alginate). Needs: config.js, jopen-utils.js, batch-report-shell.js,
// fermentation-log.js (nagardoDose, alginateDose); styles in batch-report.css.
// ============================================================================

const TRANSFER_SELECT = '*, to_batch:batches!batch_transfers_to_batch_id_fkey(batch_number)';
const CARD_TRASH_ICON = '<svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true"><path d="M2.5 4h9M5.5 4V2.5h3V4M3.5 4l.6 8h5.8l.6-8"></path></svg>';

/**
 * Insert one row with the save status, add it to `list`; returns the row or
 * null (the error is shown in the save status).
 */
async function insertBatchRow({ table, values, list, saveStatus, userId, stampUpdatedBy = true, select = '*' }) {
  saveStatus.saving();
  const payload = stampUpdatedBy && userId ? { ...values, updated_by: userId } : values;
  const { data, error } = await supabaseClient.from(table).insert(payload).select(select).single();
  if (error) { saveStatus.failed(error.message); return null; }
  if (list) list.push(data);
  saveStatus.saved();
  return data;
}

/**
 * "Splits / transfers out" card. ctx() returns { batchId, transfers, tanks,
 * fromTanks, canEdit, canDelete, userId, saveStatus } with fromTanks the
 * tanks the beer can leave from (GLT / LT, and the HBTs on Processing).
 * Returns { render, handleChange(el), handleClick(el) }; the page calls the
 * handlers from its own change / click listeners (true = handled).
 */
function createTransfersCard(container, ctx, renderSoon) {
  let draft = null;
  const pad = (n) => String(n).padStart(2, '0');
  const when = (at) => { const d = new Date(at); return `${pad(d.getDate())}-${pad(d.getMonth() + 1)}-${d.getFullYear()} ${pad(d.getHours())}:${pad(d.getMinutes())}`; };
  const fmt = (v) => (v === null || v === undefined ? '—' : Number(v).toLocaleString('en-GB', { maximumFractionDigits: 1 }));
  const sort = (list) => list.sort((a, b) => new Date(a.transferred_at) - new Date(b.transferred_at) || a.id - b.id);

  function render() {
    const c = ctx();
    const tankCode = (id) => (c.tanks.find((t) => t.id === id) || {}).code || '—';
    const rows = c.transfers.map((t) => `<tr>
      <td>${when(t.transferred_at)}</td><td class="n">${fmt(t.volume_hl)}</td><td>${escapeHtml(tankCode(t.from_tank_id))}</td>
      <td>${t.destination === 'discard' ? 'Discard' : 'To batch'}</td>
      <td>${t.to_batch ? `<a href="batch-overview.html?id=${t.to_batch_id}">${escapeHtml(t.to_batch.batch_number)}</a>` : '—'}</td>
      <td class="small">${escapeHtml([t.reason, t.comment].filter(Boolean).join(' · ') || '—')}</td>
      <td>${c.canDelete ? `<button class="br-del" type="button" data-delete-transfer="${t.id}" aria-label="Delete transfer">${CARD_TRASH_ICON}</button>` : ''}</td></tr>`).join('');
    const d = draft;
    const draftRow = d ? `<tr class="fl-draft">
      <td><input class="br-in l" type="datetime-local" data-draft="at" value="${escapeHtml(d.at || '')}" aria-label="Date and time"></td>
      <td><input class="br-in" inputmode="decimal" data-draft="volume" value="${escapeHtml(d.volume || '')}" aria-label="Volume (hl)" placeholder="hl"></td>
      <td><select class="br-in" data-draft="fromTankId" aria-label="From"><option value="">—</option>${c.fromTanks.map((t) => `<option value="${t.id}"${String(t.id) === String(d.fromTankId) ? ' selected' : ''}>${escapeHtml(t.code)}</option>`).join('')}</select></td>
      <td><select class="br-in" data-draft="destination" aria-label="Destination"><option value="batch"${d.destination === 'batch' ? ' selected' : ''}>To batch</option><option value="discard"${d.destination === 'discard' ? ' selected' : ''}>Discard</option></select></td>
      <td>${d.destination === 'batch' ? `<input class="br-in l" data-draft="batchNumber" value="${escapeHtml(d.batchNumber || '')}" placeholder="26…" aria-label="Receiving batch">` : '—'}</td>
      <td><div style="display:flex; gap:6px;">${d.destination === 'discard' ? `<input class="br-in l" data-draft="reason" value="${escapeHtml(d.reason || '')}" placeholder="Reason (required)" aria-label="Reason">` : ''}
        <input class="br-in l" data-draft="comment" value="${escapeHtml(d.comment || '')}" placeholder="Comment" aria-label="Comment"></div></td>
      <td></td></tr>` : '';
    container.innerHTML = `
      <div class="br-head" style="align-items:baseline;">
        <div class="br-label">Splits / transfers out</div>
        <span class="br-note">Same record on Fermentation log, Processing and Filling report · fill in once</span>
      </div>
      ${c.transfers.length || d ? `<div class="br-table-wrap"><table class="br-ing" style="min-width:820px;">
        <thead><tr><th style="width:170px;">Date</th><th class="r" style="width:90px;">Volume (hl)</th><th style="width:110px;">From</th>
          <th style="width:130px;">Destination</th><th style="width:120px;">Batch</th><th>Reason · comment</th><th style="width:34px;"></th></tr></thead>
        <tbody>${rows}${draftRow}</tbody></table></div>` : '<div class="br-note">No splits or transfers.</div>'}
      ${d ? `<div class="br-buttons"><button class="br-primary" type="button" id="fl-transfer-save">Save transfer</button>
          <button class="br-ghost" type="button" id="fl-transfer-cancel">Cancel</button>
          <span class="br-note error" role="alert">${escapeHtml(d.problem || '')}</span></div>`
        : c.canEdit ? '<div><button class="br-ghost" type="button" id="fl-transfer-add">+ Split / transfer</button></div>' : ''}`;
  }

  function problem(text) { draft.problem = text; renderSoon(); }

  async function save() {
    const c = ctx();
    const d = draft;
    const volume = parseNumberInput(d.volume);
    if (!d.at) return problem('Fill in the date and time of the transfer.');
    if (!volume || volume <= 0) return problem('Fill in the volume in hl (more than 0).');
    let toBatchId = null;
    if (d.destination === 'batch') {
      const number = String(d.batchNumber || '').trim();
      if (!number) return problem('Fill in the batch number that receives the beer.');
      const { data, error } = await supabaseClient.from('batches').select('id').eq('batch_number', number).maybeSingle();
      if (error) return problem(error.message);
      if (!data) return problem(`Batch ${number} does not exist.`);
      if (data.id === c.batchId) return problem('A batch cannot transfer to itself.');
      toBatchId = data.id;
    } else if (!String(d.reason || '').trim()) {
      return problem('Give the reason for discarding.');
    }
    const saved = await insertBatchRow({
      table: 'batch_transfers', list: c.transfers, saveStatus: c.saveStatus, userId: c.userId, select: TRANSFER_SELECT,
      values: {
        batch_id: c.batchId, transferred_at: new Date(d.at).toISOString(), volume_hl: volume,
        from_tank_id: d.fromTankId ? Number(d.fromTankId) : null, destination: d.destination, to_batch_id: toBatchId,
        reason: String(d.reason || '').trim() || null, comment: String(d.comment || '').trim() || null,
      },
    });
    if (saved) { draft = null; sort(c.transfers); }
    renderSoon();
  }

  async function remove(t) {
    const c = ctx();
    const ok = await confirmDialog({ title: 'Delete this transfer?', text: 'You can undo this right after deleting. The deletion is recorded in the audit trail.' });
    if (!ok) return;
    c.saveStatus.saving();
    const { error } = await supabaseClient.from('batch_transfers').delete().eq('id', t.id).select('id').single();
    if (error) { c.saveStatus.failed(error.message); return; }
    c.transfers.splice(c.transfers.indexOf(t), 1);
    c.saveStatus.saved();
    renderSoon();
    showUndoToast('Transfer', async () => {
      const { id, created_at, updated_at, updated_by, to_batch, ...values } = t;
      await insertBatchRow({ table: 'batch_transfers', values, list: c.transfers, saveStatus: c.saveStatus, userId: c.userId, select: TRANSFER_SELECT });
      sort(c.transfers);
      renderSoon();
    });
  }

  function handleChange(el) {
    if (!el.dataset.draft || !draft) return false;
    draft[el.dataset.draft] = el.value;
    if (el.dataset.draft === 'destination') renderSoon();
    return true;
  }

  function handleClick(target) {
    const del = target.closest('button[data-delete-transfer]');
    if (del) { remove(ctx().transfers.find((x) => x.id === Number(del.dataset.deleteTransfer))); return true; }
    if (target.closest('#fl-transfer-add')) {
      const from = ctx().fromTanks;
      draft = { at: toDateTimeLocal(new Date()), volume: '', fromTankId: from.length ? from[from.length - 1].id : '', destination: 'batch', batchNumber: '', reason: '', comment: '' };
      renderSoon('[data-draft="volume"]');
      return true;
    }
    if (target.closest('#fl-transfer-cancel')) { draft = null; renderSoon(); return true; }
    if (target.closest('#fl-transfer-save')) { save(); return true; }
    return false;
  }

  return { render, handleChange, handleClick };
}

/**
 * Which cellar calculators a batch needs (business-rules.md "Calculators"):
 * { nagardo, alginate } from the names of its ingredients.
 */
function cellarCalculatorsFor(ingredients, names) {
  const nameOf = (r) => (names[r.ingredient_id] || r.note || '').toLowerCase();
  return {
    nagardo: ingredients.some((r) => nameOf(r).includes('nagardo')),
    alginate: ingredients.some((r) => r.addition_type === 'cellar_addition' && /pga|alginat/.test(nameOf(r))),
  };
}

function cellarCalcResult(kind, volume, rate) {
  if (kind === 'nagardo') {
    const r = nagardoDose(volume, rate);
    return r && { lines: [['Nagardo', `${r.weightG.toFixed(1)} g`], ['Water (1 % solution)', `${r.waterL.toFixed(1)} l`]],
      text: `Nagardo ${r.weightG.toFixed(1)} g in ${r.waterL.toFixed(1)} l water (${rate} ppm on ${volume} l)` };
  }
  const r = alginateDose(volume, rate);
  return r && { lines: [['Volume before centrifuge', `${r.preL.toFixed(1)} l`], ['Alginate', `${r.alginateG.toFixed(1)} g`], ['Hot water', `${r.waterL.toFixed(1)} l`]],
    text: `PGA/alginate ${r.alginateG.toFixed(1)} g in ${r.waterL.toFixed(1)} l hot water (${rate} l/hl on ${volume} l)` };
}

/**
 * Calculator window. onSave(text) is called with the result text when the
 * user clicks the save button (saveLabel); without onSave there is no button.
 */
function openCellarCalculator({ kind, volumeL, saveLabel = 'Save to log', onSave }) {
  document.getElementById('fl-calc')?.remove();
  const state = { volume: volumeL ?? '', rate: '' };
  const outHtml = (r) => (r ? r.lines.map(([k, v]) => `<div><span>${escapeHtml(k)}</span><b>${escapeHtml(v)}</b></div>`).join('') : '<span class="br-note">Fill in both values.</span>');
  const overlay = document.createElement('div');
  overlay.className = 'br-dialog-overlay';
  overlay.id = 'fl-calc';
  overlay.innerHTML = `<div class="br-dialog" role="dialog" aria-modal="true" aria-labelledby="fl-calc-title">
    <div class="br-dialog-title" id="fl-calc-title">${kind === 'nagardo' ? 'Nagardo' : 'PGA / alginate'}</div>
    <div class="br-field"><label class="br-label" for="fl-calc-volume">Beer volume (l)</label><input class="br-input" id="fl-calc-volume" inputmode="decimal" value="${escapeHtml(String(state.volume))}"></div>
    <div class="br-field"><label class="br-label" for="fl-calc-rate">${kind === 'nagardo' ? 'Dose (ppm)' : 'Rate (l/hl)'}</label><input class="br-input" id="fl-calc-rate" inputmode="decimal" value=""></div>
    <div class="fl-calc-out">${outHtml(null)}</div>
    <div class="br-dialog-buttons">
      <button type="button" class="br-ghost" id="fl-calc-close">Close</button>
      ${onSave ? `<button type="button" class="br-primary" id="fl-calc-log" disabled>${escapeHtml(saveLabel)}</button>` : ''}
    </div></div>`;
  const close = () => { overlay.remove(); document.removeEventListener('keydown', onKey); };
  const onKey = (e) => { if (e.key === 'Escape') close(); };
  overlay.addEventListener('click', (e) => { if (e.target === overlay) close(); });
  overlay.addEventListener('input', (e) => {
    if (e.target.id === 'fl-calc-volume') state.volume = e.target.value;
    if (e.target.id === 'fl-calc-rate') state.rate = e.target.value;
    const r = cellarCalcResult(kind, state.volume, state.rate);
    overlay.querySelector('.fl-calc-out').innerHTML = outHtml(r);
    const btn = overlay.querySelector('#fl-calc-log');
    if (btn) btn.disabled = !r;
  });
  overlay.querySelector('#fl-calc-close').addEventListener('click', close);
  overlay.querySelector('#fl-calc-log')?.addEventListener('click', () => {
    const r = cellarCalcResult(kind, state.volume, state.rate);
    if (!r) return;
    close();
    onSave(r.text);
  });
  document.addEventListener('keydown', onKey);
  document.body.appendChild(overlay);
  overlay.querySelector('#fl-calc-rate').focus();
}
