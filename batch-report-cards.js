// ============================================================================
// batch-report-cards.js — parts shared by several batch tabs (Fermentation
// log, Processing, later Filling report): the "Splits / transfers out" card
// (batch_transfers) and the cellar calculators window (Nagardo, PGA /
// alginate). Needs: config.js, jopen-utils.js, batch-report-shell.js,
// fermentation-log.js (nagardoDose, alginateDose), splits.js and
// batch-ingredients.js (the split popup), batch-stages.js (stageInfo,
// versionText), dosing-checks.js (the addition tick boxes); styles in
// batch-report.css.
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
 * Tick boxes for additions per brew / per HBT (batch_dosing_checks; helpers
 * in dosing-checks.js). ctx() returns { batchId, checks, userId, canEdit,
 * saveStatus, initialsOf }. cellHtml(line, kind 'brew'|'hbt', targetId, note) is
 * one table cell (note: small text under the box, e.g. the amount); handleChange(el) saves a tick (insert) or untick (delete) and
 * returns true when it handled the element.
 */
function createDosingChecks(ctx, renderSoon) {
  function cellHtml(line, kind, targetId, note) {
    const c = ctx();
    const check = dosingCheck(c.checks, line.id, kind, targetId);
    const title = check ? `Added · ${dosingTitle(check, c.initialsOf)}` : 'Not added yet';
    return `<td class="bd-check"><input type="checkbox" data-dosing-line="${line.id}" data-dosing-kind="${kind}" data-dosing-target="${targetId}"
      aria-label="${escapeHtml(title)}" title="${escapeHtml(title)}"${check ? ' checked' : ''}${c.canEdit ? '' : ' disabled'}>${note ? `<div class="bd-amount">${escapeHtml(note)}</div>` : ''}</td>`;
  }

  async function save(el) {
    const c = ctx();
    const lineId = Number(el.dataset.dosingLine), kind = el.dataset.dosingKind, targetId = Number(el.dataset.dosingTarget);
    const field = kind === 'brew' ? 'batch_brew_id' : 'batch_hbt_id';
    const check = dosingCheck(c.checks, lineId, kind, targetId);
    if (el.checked && !check) {
      const row = await insertBatchRow({
        table: 'batch_dosing_checks', list: c.checks, saveStatus: c.saveStatus, userId: c.userId, stampUpdatedBy: false,
        values: { batch_id: c.batchId, batch_ingredient_id: lineId, [field]: targetId, checked_by: c.userId, checked_at: new Date().toISOString() },
      });
      if (!row) el.checked = false;
    } else if (!el.checked && check) {
      c.saveStatus.saving();
      const { error } = await supabaseClient.from('batch_dosing_checks').delete().eq('id', check.id).select('id').single();
      if (error) { el.checked = true; c.saveStatus.failed(error.message); return; }
      c.checks.splice(c.checks.indexOf(check), 1);
      c.saveStatus.saved();
    }
    renderSoon();
  }

  function handleChange(el) {
    if (!el.dataset || !el.dataset.dosingLine) return false;
    save(el);
    return true;
  }

  return { cellHtml, handleChange };
}

/**
 * "Splits / transfers" card: transfers out (batch_transfers of this batch)
 * and the incoming beer (transfers to this batch). ctx() returns { batchId,
 * batch, recipe, transfers, incoming, tanks, fromTanks, tankStartHl(tankId)
 * (optional: volume in a tank before transfers, for "after transfer"),
 * canEdit, canDelete, userId, saveStatus, onSaved(result) (reloads the page
 * data) }. fromTanks = the tanks the beer can leave from (GLT / LT, the
 * HBTs). "+ Split / transfer" opens the popup (openSplitDialog). Returns
 * { render, handleChange(el), handleClick(el) }; the page calls the handlers
 * from its own change / click listeners (true = handled).
 */
function createTransfersCard(container, ctx, renderSoon) {
  let saved = null;   // { batchNumber, toBatchId } of the last save, for the link
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
      <td style="text-align:center;"><input type="checkbox" data-empties-transfer="${t.id}"${t.empties_tank ? ' checked' : ''}${c.canEdit ? '' : ' disabled'}
        aria-label="Tank empty: this was the whole batch" title="Tank empty: this was the whole batch"></td>
      <td>${c.canDelete ? `<button class="br-del" type="button" data-delete-transfer="${t.id}" aria-label="Delete transfer">${CARD_TRASH_ICON}</button>` : ''}</td></tr>`).join('');
    const incoming = c.incoming || [];
    const inRows = incoming.map((t) => `<tr>
      <td>${when(t.transferred_at)}</td><td class="n">${fmt(t.volume_hl)}</td>
      <td><a href="batch-overview.html?id=${t.batch_id}">${escapeHtml(t.source ? t.source.batch_number : '?')}</a></td>
      <td>${escapeHtml((t.source && t.source.recipes && t.source.recipes.name) || '—')}</td>
      <td class="small">${escapeHtml(t.comment || '—')}</td></tr>`).join('');
    container.innerHTML = `
      <div class="br-head" style="align-items:baseline;">
        <div class="br-label">Splits / transfers out</div>
        <span class="br-note">Same record on Fermentation log, Processing and Filling report · fill in once</span>
      </div>
      ${c.transfers.length ? `<div class="br-table-wrap"><table class="br-ing" style="min-width:820px;">
        <thead><tr><th style="width:170px;">Date</th><th class="r" style="width:90px;">Volume (hl)</th><th style="width:110px;">From</th>
          <th style="width:130px;">Destination</th><th style="width:120px;">Batch</th><th>Reason · comment</th><th style="width:90px; text-align:center;">Tank empty</th><th style="width:34px;"></th></tr></thead>
        <tbody>${rows}</tbody></table></div>` : '<div class="br-note">No splits or transfers.</div>'}
      ${saved ? `<div class="br-note sp-saved">Saved${saved.toBatchId ? ` · <a href="batch-overview.html?id=${saved.toBatchId}">batch ${escapeHtml(saved.batchNumber || '')}</a>` : ''} · a Transfer entry is on the fermentation log</div>` : ''}
      ${c.canEdit ? '<div><button class="br-ghost" type="button" id="fl-transfer-add">+ Split / transfer</button></div>' : ''}
      ${incoming.length ? `<div class="br-label" style="margin-top:14px;">Incoming beer</div>
        <div class="br-table-wrap"><table class="br-ing" style="min-width:640px;">
          <thead><tr><th style="width:170px;">Date</th><th class="r" style="width:90px;">Volume (hl)</th><th style="width:110px;">From batch</th><th style="width:200px;">Beer</th><th>Comment</th></tr></thead>
          <tbody>${inRows}<tr class="tot"><td>Total</td><td class="n">${fmt(incomingTotalHl(incoming))}</td><td colspan="3"></td></tr></tbody></table></div>` : ''}`;
  }

  async function remove(t) {
    const c = ctx();
    const ok = await confirmDialog({ title: 'Delete this transfer?', text: 'You can undo this right after deleting. The deletion is recorded in the audit trail. A batch made by the split and the log entry stay.' });
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

  // "Tank empty": the whole batch went out with this transfer; the batch then
  // counts as Filled (view batch_stages) and waits for the filling report checks.
  function handleChange(el) {
    if (!el.dataset.emptiesTransfer) return false;
    const c = ctx();
    const t = c.transfers.find((x) => x.id === Number(el.dataset.emptiesTransfer));
    if (t) setEmptiesTank(t, el.checked, c.saveStatus).then(() => { if (c.onSaved) c.onSaved(null); renderSoon(); });
    return true;
  }

  function handleClick(target) {
    const del = target.closest('button[data-delete-transfer]');
    if (del) { remove(ctx().transfers.find((x) => x.id === Number(del.dataset.deleteTransfer))); return true; }
    if (target.closest('#fl-transfer-add')) {
      openSplitDialog(ctx(), async (result) => {
        saved = { batchNumber: result && result.batch_number, toBatchId: result && result.to_batch_id };
        const c = ctx();
        if (c.onSaved) await c.onSaved(result);
        renderSoon();
      });
      return true;
    }
    return false;
  }

  return { render, handleChange, handleClick };
}

async function setEmptiesTank(transfer, value, saveStatus) {
  saveStatus.saving();
  const { error } = await supabaseClient.from('batch_transfers').update({ empties_tank: value }).eq('id', transfer.id).select('id').single();
  if (error) { saveStatus.failed(error.message); return false; }
  transfer.empties_tank = value;
  saveStatus.saved();
  return true;
}

// Incoming transfers of a batch with the source batch and its beer.
const INCOMING_SELECT = '*, source:batches!batch_transfers_batch_id_fkey(batch_number, recipes(name, recipe_group_id))';

/**
 * Split / transfer popup (mockup SplitBatch.dc.html): moment, volume, from
 * tank, destination New batch / Existing batch / Discard, with a preview of
 * the receiving batch (incoming beer, base beer check, recipe ingredients
 * dosed on the total volume). Saves with rpc split_batch (one transaction:
 * new batch, transfer, Transfer log entry); onDone(result) after a save.
 * c = the card context (see createTransfersCard).
 */
function openSplitDialog(card, onDone) {
  document.getElementById('sp-dialog')?.remove();
  // a tank used for two fills of the batch is one "from" tank
  const c = { ...card, fromTanks: [...new Map(card.fromTanks.map((t) => [t.id, t])).values()] };
  const fmt1 = (v) => (v === null || v === undefined || v === '' ? '—' : Number(v).toFixed(1));
  const yy = String(new Date().getFullYear()).slice(2);
  const st = {
    at: toDateTimeLocal(new Date()), volume: '', fromTankId: c.fromTanks.length ? String(c.fromTanks[0].id) : '',
    destination: 'new', recipeId: '', batchNumber: '', reason: '', comment: '', empties: false, problem: '', saving: false,
    recipes: [], lastNumber: null, target: null, targetProblem: '', groupNames: new Map(),
  };
  const overlay = document.createElement('div');
  overlay.className = 'br-dialog-overlay';
  overlay.id = 'sp-dialog';
  document.body.appendChild(overlay);
  const close = () => { overlay.remove(); document.removeEventListener('keydown', onKey); };
  const onKey = (e) => { if (e.key === 'Escape') close(); };
  document.addEventListener('keydown', onKey);
  const tankCode = (id) => (c.tanks.find((t) => String(t.id) === String(id)) || {}).code || '';
  const recipeText = (r) => (r && r.name ? `${r.name} ${versionText(r.version_major, r.version_minor)}` : '');

  async function groupNames(ids) {
    const missing = ids.filter((g) => g && !st.groupNames.has(g));
    if (!missing.length) return;
    const { data } = await supabaseClient.from('recipes').select('name, recipe_group_id, version_major, version_minor').in('recipe_group_id', missing);
    (data || []).sort((a, b) => a.version_major - b.version_major || a.version_minor - b.version_minor)
      .forEach((r) => st.groupNames.set(r.recipe_group_id, r.name));   // the newest version wins
  }

  async function namesOf(lines) {
    const ids = [...new Set(lines.map((l) => l.ingredient_id).filter(Boolean))];
    if (!ids.length) return {};
    const { data } = await supabaseClient.from('ingredients').select('id, name').in('id', ids);
    return Object.fromEntries((data || []).map((i) => [i.id, i.name]));
  }

  // Receiving batch: a new one from the chosen recipe, or an existing batch.
  async function loadTarget() {
    st.target = null; st.targetProblem = ''; st.problem = '';
    if (st.destination === 'new' && st.recipeId) {
      const recipe = st.recipes.find((r) => String(r.id) === st.recipeId);
      const { data } = await supabaseClient.from('recipe_ingredients').select('*').eq('recipe_id', recipe.id).order('addition_type').order('sort_order');
      const lines = data || [];
      st.target = { isNew: true, number: nextBatchNumber(st.lastNumber, yy), recipe, brewCount: 0, incoming: [], lines, names: await namesOf(lines), status: 'New · 0 brews' };
    } else if (st.destination === 'batch' && st.batchNumber.trim()) {
      const number = st.batchNumber.trim();
      const { data: b, error } = await supabaseClient.from('batches')
        .select('id, batch_number, brew_count, recipe_id, recipes(name, version_major, version_minor, brew_volume_hl, recipe_group_id)').eq('batch_number', number).maybeSingle();
      if (error) { st.targetProblem = error.message; return; }
      if (!b) { st.targetProblem = `Batch ${number} does not exist.`; return; }
      if (b.id === c.batchId) { st.targetProblem = 'A batch cannot transfer to itself.'; return; }
      const [stage, incoming, lines] = await Promise.all([
        supabaseClient.from('batch_stages').select('stage').eq('batch_id', b.id).maybeSingle(),
        supabaseClient.from('batch_transfers').select(INCOMING_SELECT).eq('to_batch_id', b.id).order('transferred_at'),
        supabaseClient.from('batch_ingredients').select('*').eq('batch_id', b.id).eq('is_removed', false).order('addition_type').order('sort_order'),
      ]);
      st.target = {
        isNew: false, id: b.id, number: b.batch_number, recipe: b.recipes || {}, brewCount: b.brew_count,
        incoming: incoming.data || [], lines: lines.data || [], names: await namesOf(lines.data || []),
        status: stageInfo((stage.data && stage.data.stage) || 'raw').label,
      };
    }
    if (st.target) {
      await groupNames([c.recipe && c.recipe.recipe_group_id,
        ...st.target.lines.filter((l) => l.addition_type === 'base_beer').map((l) => l.source_recipe_group_id),
        ...st.target.incoming.map((t) => t.source && t.source.recipes && t.source.recipes.recipe_group_id)]);
    }
  }

  function previewHtml() {
    if (st.destination === 'discard') {
      return `<div class="br-label">Preview</div><div class="sp-big">No receiving batch</div>
        <div class="br-note">${fmt1(parseNumberInput(st.volume))} hl is booked as discarded on ${escapeHtml(c.batch.batch_number)} and shows in the volume balance of the Filling report.</div>`;
    }
    if (st.targetProblem) return `<div class="br-note error">${escapeHtml(st.targetProblem)}</div>`;
    const t = st.target;
    if (!t) return `<div class="br-note">${st.destination === 'new' ? 'Choose the recipe of the new product.' : 'Fill in the receiving batch number.'}</div>`;
    const vol = parseNumberInput(st.volume) || 0;
    const thisRow = { batch: c.batch.batch_number, beer: c.recipe.name, groupId: c.recipe.recipe_group_id, when: st.at ? st.at.replace('T', ' ') : '—', hl: vol, isThis: true };
    const rows = t.incoming.map((x) => ({ batch: x.source ? x.source.batch_number : '?', beer: x.source && x.source.recipes ? x.source.recipes.name : '?',
      groupId: x.source && x.source.recipes ? x.source.recipes.recipe_group_id : null, when: toDateTimeLocal(x.transferred_at).replace('T', ' '), hl: Number(x.volume_hl) || 0 }))
      .concat([thisRow]);
    const totalHl = incomingTotalHl(rows);
    const base = t.lines.filter((l) => l.addition_type === 'base_beer');
    const check = baseBeerCheck(base, rows.map((r) => ({ groupId: r.groupId, hl: r.hl })));
    const groupName = (g) => st.groupNames.get(g) || '?';
    const thisUnexpected = base.length && check.unexpected.includes(c.recipe.recipe_group_id);
    const dctx = { brewCount: t.brewCount, brewVolumeHl: t.recipe.brew_volume_hl, incomingHl: totalHl };
    const dosed = t.lines.filter((l) => l.addition_type !== 'base_beer').map((l) => {
      const basis = amountBasis(l.addition_type, l.unit);
      if (!basis || (basis.per === 'brew' && !(Number(t.brewCount) > 0))) return null;
      const a = batchAmount(l.addition_type, l.unit, l.quantity, dctx);
      return a ? `<tr><td><b>${escapeHtml(t.names[l.ingredient_id] || l.note || '(no ingredient)')}</b></td><td class="c">${escapeHtml(String(l.quantity ?? ''))} ${escapeHtml(l.unit || '')}</td><td class="n">${escapeHtml(formatAmount(a))}</td></tr>` : null;
    }).filter(Boolean).join('');
    return `<div class="br-label">Preview · receiving batch</div>
      <div class="sp-target"><span class="sp-big">${escapeHtml(t.number)}${t.isNew ? ' <span class="br-note">next in sequence</span>' : ''}</span>
        <b>${escapeHtml(recipeText(t.recipe))}</b><span class="br-pill" style="background:#e1ead9; color:#33473a;">${escapeHtml(t.status)}</span></div>
      <div class="br-head" style="align-items:baseline; margin-top:10px;"><div class="br-label">Incoming beer</div><span class="br-note">One line per source beer</span></div>
      <table class="br-ing"><thead><tr><th>Batch</th><th>Beer</th><th>Moment</th><th class="r">hl</th></tr></thead>
        <tbody>${rows.map((r) => `<tr${r.isThis ? ' class="sp-this"' : ''}><td><b>${escapeHtml(r.batch)}</b></td><td>${escapeHtml(r.beer || '')}${r.isThis ? ' <span class="br-note">· this transfer</span>' : ''}</td>
          <td class="small">${escapeHtml(r.when)}</td><td class="n">${fmt1(r.hl)}</td></tr>`).join('')}
          <tr class="tot"><td colspan="3">Total incoming${Number(t.brewCount) > 0 ? ` · + ${fmt1(Number(t.brewCount) * (Number(t.recipe.brew_volume_hl) || 0))} hl brewed` : ''}</td><td class="n">${fmt1(totalHl)}</td></tr></tbody></table>
      ${base.length ? `<div class="br-label" style="margin-top:10px;">Base beer · recipe</div>
        <table class="br-ing"><thead><tr><th>Beer</th><th class="r">Share</th><th class="r">Expected hl</th><th class="r">Incoming hl</th></tr></thead>
          <tbody>${check.rows.map((x) => `<tr><td><b>${escapeHtml(groupName(x.groupId))}</b></td><td class="c">${fmt1(x.sharePct)} %</td><td class="c">${fmt1(x.expectedHl)}</td><td class="n">${fmt1(x.actualHl)}</td></tr>`).join('')}</tbody></table>
        ${thisUnexpected ? `<div class="sp-warning">${escapeHtml(c.recipe.name || 'This beer')} is not a base beer of ${escapeHtml(t.recipe.name || 'this recipe')}. Check the recipe or the receiving batch.</div>` : ''}`
        : '<div class="br-note" style="margin-top:8px;">The recipe has no base beer line.</div>'}
      <div class="br-head" style="align-items:baseline; margin-top:10px;"><div class="br-label">Recipe ingredients · dosed on ${fmt1(dosingVolumeHl(dctx))} hl</div></div>
      ${dosed ? `<table class="br-ing"><thead><tr><th>Ingredient</th><th class="r">Dosing</th><th class="r">Amount</th></tr></thead><tbody>${dosed}</tbody></table>`
        : '<div class="br-note">No additional ingredients in this recipe · only the incoming beer.</div>'}
      <div class="br-note" style="margin-top:6px;">Amounts follow the total volume: every incoming transfer recalculates the dosing.</div>`;
  }

  // Parts that follow what is typed; updated without redrawing the fields
  // (a redraw puts the cursor back at the start).
  function afterHtml() {
    const start = c.tankStartHl && st.fromTankId ? c.tankStartHl(Number(st.fromTankId)) : null;
    if (start === null || start === undefined) return '';
    const after = tankAfterTransfer(start, c.transfers, Number(st.fromTankId), parseNumberInput(st.volume));
    return `<div class="sp-after${after < 0 ? ' bad' : ''}"><span>${escapeHtml(tankCode(st.fromTankId))} after transfer</span><b>${fmt1(after)} hl</b></div>`;
  }

  function logText() {
    const t = st.target;
    const recipe = st.recipes.find((r) => String(r.id) === st.recipeId);
    return transferLogText({ volumeHl: parseNumberInput(st.volume), tankCode: tankCode(st.fromTankId), destination: st.destination,
      batchNumber: t ? t.number : (st.destination === 'batch' ? st.batchNumber.trim() : ''), recipeName: recipe && recipe.name, reason: st.reason, comment: st.comment });
  }

  function updateLive() {
    const set = (id, html) => { const el = document.getElementById(id); if (el) el.innerHTML = html; };
    set('sp-after-wrap', afterHtml());
    set('sp-log', escapeHtml(logText()));
    set('sp-preview', previewHtml());
  }

  function render() {
    const t = st.target;
    const seg = (v, label) => `<button type="button" data-sp-dest="${v}" class="${st.destination === v ? 'on' : ''}">${label}</button>`;
    const saveLabel = st.destination === 'new' ? `Create ${t ? t.number : 'batch'} & save transfer` : st.destination === 'batch' ? 'Save transfer' : 'Save discard';
    overlay.innerHTML = `<div class="br-dialog sp-dialog" role="dialog" aria-modal="true" aria-labelledby="sp-title">
      <div class="sp-grid">
        <div class="sp-form">
          <div><div class="br-note">Batch ${escapeHtml(c.batch.batch_number)} · ${escapeHtml(recipeText(c.recipe))}</div>
            <div class="br-dialog-title" id="sp-title" style="font-size:20px;">Split / transfer out</div></div>
          <div class="sp-row">
            <div class="br-field"><label class="br-label" for="sp-at">Transfer moment</label><input class="br-input" id="sp-at" type="datetime-local" value="${escapeHtml(st.at)}"></div>
            <div class="br-field"><label class="br-label" for="sp-volume">Volume (hl)</label><input class="br-input" id="sp-volume" inputmode="decimal" value="${escapeHtml(st.volume)}"></div>
          </div>
          <div class="br-field"><label class="br-label" for="sp-tank">From tank</label><select class="br-input" id="sp-tank"><option value="">—</option>
            ${c.fromTanks.map((tk) => { const s = c.tankStartHl ? c.tankStartHl(tk.id) : null; return `<option value="${tk.id}"${String(tk.id) === st.fromTankId ? ' selected' : ''}>${escapeHtml(tk.code)}${s !== null && s !== undefined ? ' · ' + fmt1(tankAfterTransfer(s, c.transfers, tk.id, 0)) + ' hl' : ''}</option>`; }).join('')}</select></div>
          <div class="br-note">Volume counts on both batches from the transfer moment.</div>
          <div class="br-field"><span class="br-label">Destination</span><div class="br-seg" role="group">${seg('new', 'New batch')}${seg('batch', 'Existing batch')}${seg('discard', 'Discard')}</div></div>
          ${st.destination === 'new' ? `<div class="sp-box">
            <div class="br-field"><label class="br-label" for="sp-recipe">Recipe of the new product</label><select class="br-input" id="sp-recipe"><option value="">Choose recipe</option>
              ${st.recipes.map((r) => `<option value="${r.id}"${String(r.id) === st.recipeId ? ' selected' : ''}>${escapeHtml(recipeText(r))}</option>`).join('')}</select></div>
            <div class="br-note">Only existing recipes · not listed? Create it in Recipes first.</div>
            <div class="sp-row"><div><span class="br-label">New batch number</span><div class="br-calc-box">${escapeHtml(nextBatchNumber(st.lastNumber, yy))} <span class="br-note">next in sequence</span></div></div>
              <div><span class="br-label">Brews</span><div class="br-calc-box">0 <span class="br-note">no brewhouse</span></div></div></div>
          </div>` : st.destination === 'batch' ? `<div class="br-field"><label class="br-label" for="sp-batch">Receiving batch</label>
            <input class="br-input" id="sp-batch" value="${escapeHtml(st.batchNumber)}" placeholder="${escapeHtml(yy)}…"></div>`
            : `<div class="br-field"><label class="br-label" for="sp-reason">Reason</label><input class="br-input" id="sp-reason" value="${escapeHtml(st.reason)}" placeholder="e.g. off-flavour, tank bottom"></div>`}
          <div class="br-field"><label class="br-label" for="sp-comment">Comment</label><input class="br-input" id="sp-comment" value="${escapeHtml(st.comment)}"></div>
          <label class="br-check"><input type="checkbox" id="sp-empties"${st.empties ? ' checked' : ''}> Tank empty: this is the whole batch
            <span class="br-note">(the batch goes to Filled and waits for the filling report checks)</span></label>
          <div id="sp-after-wrap">${afterHtml()}</div>
          <div class="br-note">Saving adds a log entry with tag <b>Transfer</b> on this batch:</div>
          <div class="sp-log" id="sp-log">${escapeHtml(logText())}</div>
          <div class="br-dialog-buttons">
            <span class="br-note error" role="alert" style="margin-right:auto;">${escapeHtml(st.problem)}</span>
            <button type="button" class="br-ghost" id="sp-cancel">Cancel</button>
            <button type="button" class="br-primary" id="sp-save"${st.saving ? ' disabled' : ''}>${escapeHtml(saveLabel)}</button>
          </div>
        </div>
        <div class="sp-preview" id="sp-preview">${previewHtml()}</div>
      </div></div>`;
  }

  const refresh = (focusId) => {
    const active = focusId || (document.activeElement && overlay.contains(document.activeElement) ? document.activeElement.id : null);
    render();
    if (active) { const el = document.getElementById(active); if (el) el.focus(); }
  };

  async function save() {
    const vol = parseNumberInput(st.volume);
    const problem = !st.at ? 'Fill in the transfer moment.'
      : !vol || vol <= 0 ? 'Fill in the volume in hl (more than 0).'
        : st.destination === 'new' && !st.recipeId ? 'Choose the recipe of the new product.'
          : st.destination === 'batch' && !(st.target && st.target.id) ? (st.targetProblem || 'Fill in the receiving batch number.')
            : st.destination === 'discard' && !st.reason.trim() ? 'Give the reason for discarding.' : '';
    if (problem) { st.problem = problem; return refresh(); }
    st.saving = true; st.problem = ''; refresh();
    c.saveStatus.saving();
    const { data, error } = await supabaseClient.rpc('split_batch', {
      p_batch_id: c.batchId, p_transferred_at: new Date(st.at).toISOString(), p_volume_hl: vol,
      p_from_tank_id: st.fromTankId ? Number(st.fromTankId) : null, p_destination: st.destination,
      p_recipe_id: st.destination === 'new' ? Number(st.recipeId) : null,
      p_to_batch_id: st.destination === 'batch' ? st.target.id : null,
      p_reason: st.destination === 'discard' ? st.reason.trim() : null, p_comment: st.comment.trim() || null,
    });
    st.saving = false;
    if (error) { c.saveStatus.failed(error.message); st.problem = error.message; return refresh(); }
    if (st.empties && data && data.transfer_id) {
      const { error: e2 } = await supabaseClient.from('batch_transfers').update({ empties_tank: true }).eq('id', data.transfer_id).select('id').single();
      if (e2) { c.saveStatus.failed('Transfer saved, but "tank empty" was not: ' + e2.message); close(); onDone(data); return; }
    }
    c.saveStatus.saved();
    close();
    onDone(data);
  }

  overlay.addEventListener('click', (e) => {
    if (e.target === overlay || e.target.closest('#sp-cancel')) return close();
    const dest = e.target.closest('button[data-sp-dest]');
    if (dest) {
      st.destination = dest.dataset.spDest; st.problem = '';
      refresh();
      loadTarget().then(() => refresh());
      return;
    }
    if (e.target.closest('#sp-save')) save();
  });
  overlay.addEventListener('input', (e) => {
    const map = { 'sp-volume': 'volume', 'sp-comment': 'comment', 'sp-reason': 'reason', 'sp-batch': 'batchNumber', 'sp-at': 'at' };
    if (map[e.target.id]) {
      st[map[e.target.id]] = e.target.value;
      updateLive();
    }
  });
  overlay.addEventListener('change', (e) => {
    if (e.target.id === 'sp-tank') { st.fromTankId = e.target.value; refresh(); }
    if (e.target.id === 'sp-empties') st.empties = e.target.checked;
    if (e.target.id === 'sp-recipe') { st.recipeId = e.target.value; refresh(); loadTarget().then(() => refresh()); }
    if (e.target.id === 'sp-batch') loadTarget().then(() => refresh());
  });

  render();
  (async () => {
    const [recipes, last] = await Promise.all([
      supabaseClient.from('recipes').select('id, name, version_major, version_minor, brew_volume_hl, recipe_group_id, status').eq('status', 'active').order('name'),
      supabaseClient.from('batches').select('batch_number').like('batch_number', `${yy}___`).order('batch_number', { ascending: false }).limit(1),
    ]);
    st.recipes = recipes.data || [];
    st.lastNumber = last.data && last.data[0] ? last.data[0].batch_number : null;
    refresh();
    document.getElementById('sp-volume')?.focus();
  })();
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

/**
 * Zinc sulphate calculator (Brewing, Additions brewers; Jaap, 23-10):
 * 4 ml solution × hl per brew × brews on the first day (typed in), all added
 * in the first brew of that day. onApply(dose) gets zincSulphateDose().
 */
/**
 * Filtration time popup (wishlist #24): start and end time from the
 * Brewmaxx graph → minutes, handed to onApply. Only the minutes are stored.
 */
function openTimeSpanCalculator({ title, onApply }) {
  document.getElementById('bw-span-calc')?.remove();
  const overlay = document.createElement('div');
  overlay.className = 'br-dialog-overlay';
  overlay.id = 'bw-span-calc';
  overlay.innerHTML = `<div class="br-dialog" role="dialog" aria-modal="true" aria-labelledby="bw-span-title">
    <div class="br-dialog-title" id="bw-span-title">${escapeHtml(title)}</div>
    <div class="br-note">Start and end time from the graph; past midnight is fine.</div>
    <div class="br-field"><label class="br-label" for="bw-span-start">Start</label><input class="br-input" id="bw-span-start" type="time"></div>
    <div class="br-field"><label class="br-label" for="bw-span-end">End</label><input class="br-input" id="bw-span-end" type="time"></div>
    <div class="fl-calc-out"><span class="br-note">Fill in both times.</span></div>
    <div class="br-dialog-buttons">
      <button type="button" class="br-ghost" id="bw-span-close">Close</button>
      <button type="button" class="br-primary" id="bw-span-apply" disabled>Use minutes</button>
    </div></div>`;
  const minutes = () => minutesBetween(overlay.querySelector('#bw-span-start').value, overlay.querySelector('#bw-span-end').value);
  const close = () => { overlay.remove(); document.removeEventListener('keydown', onKey); };
  const onKey = (e) => { if (e.key === 'Escape') close(); };
  overlay.addEventListener('click', (e) => { if (e.target === overlay) close(); });
  overlay.addEventListener('input', () => {
    const m = minutes();
    overlay.querySelector('.fl-calc-out').innerHTML = m === null ? '<span class="br-note">Fill in both times.</span>'
      : `<div><span>Duration</span><b>${m} min</b></div>`;
    overlay.querySelector('#bw-span-apply').disabled = m === null;
  });
  overlay.querySelector('#bw-span-close').addEventListener('click', close);
  overlay.querySelector('#bw-span-apply').addEventListener('click', () => {
    const m = minutes();
    if (m === null) return;
    close();
    onApply(m);
  });
  document.addEventListener('keydown', onKey);
  document.body.appendChild(overlay);
  overlay.querySelector('#bw-span-start').focus();
}

function openZincCalculator({ brewVolumeHl, brews, onApply }) {
  document.getElementById('bw-zinc-calc')?.remove();
  const state = { hl: brewVolumeHl ?? '', brews: brews ?? '' };
  const outHtml = (r) => (r ? `<div><span>Solution · all in the first brew</span><b style="white-space:nowrap;">${escapeHtml(formatAmount({ q: r.ml, unit: 'ml' }))}</b></div>`
    : '<span class="br-note">Fill in both values.</span>');
  const overlay = document.createElement('div');
  overlay.className = 'br-dialog-overlay';
  overlay.id = 'bw-zinc-calc';
  overlay.innerHTML = `<div class="br-dialog" role="dialog" aria-modal="true" aria-labelledby="bw-zinc-title">
    <div class="br-dialog-title" id="bw-zinc-title">Zinc sulphate</div>
    <div class="br-note">${ZINC_ML_PER_HL} ml solution per hl, only on the first brewing day, all in one go in the first brew.</div>
    <div class="br-field"><label class="br-label" for="bw-zinc-hl">Brew volume (hl)</label><input class="br-input" id="bw-zinc-hl" inputmode="decimal" value="${escapeHtml(String(state.hl))}"></div>
    <div class="br-field"><label class="br-label" for="bw-zinc-brews">Brews on the first day</label><input class="br-input" id="bw-zinc-brews" inputmode="numeric" value="${escapeHtml(String(state.brews))}"></div>
    <div class="fl-calc-out">${outHtml(null)}</div>
    <div class="br-dialog-buttons">
      <button type="button" class="br-ghost" id="bw-zinc-close">Close</button>
      ${onApply ? '<button type="button" class="br-primary" id="bw-zinc-apply" disabled>Apply to batch</button>' : ''}
    </div></div>`;
  const dose = () => zincSulphateDose(parseNumberInput(state.hl), parseNumberInput(state.brews));
  const close = () => { overlay.remove(); document.removeEventListener('keydown', onKey); };
  const onKey = (e) => { if (e.key === 'Escape') close(); };
  overlay.addEventListener('click', (e) => { if (e.target === overlay) close(); });
  overlay.addEventListener('input', (e) => {
    if (e.target.id === 'bw-zinc-hl') state.hl = e.target.value;
    if (e.target.id === 'bw-zinc-brews') state.brews = e.target.value;
    const r = dose();
    overlay.querySelector('.fl-calc-out').innerHTML = outHtml(r);
    const btn = overlay.querySelector('#bw-zinc-apply');
    if (btn) btn.disabled = !r;
  });
  overlay.querySelector('#bw-zinc-close').addEventListener('click', close);
  overlay.querySelector('#bw-zinc-apply')?.addEventListener('click', () => {
    const r = dose();
    if (!r) return;
    close();
    onApply(r, parseNumberInput(state.brews));
  });
  document.addEventListener('keydown', onKey);
  document.body.appendChild(overlay);
  // prefilled (brews on the first day are stored on the batch): show the result straight away
  if (dose()) {
    overlay.querySelector('.fl-calc-out').innerHTML = outHtml(dose());
    const btn = overlay.querySelector('#bw-zinc-apply');
    if (btn) btn.disabled = false;
  }
  overlay.querySelector('#bw-zinc-brews').focus();
}
