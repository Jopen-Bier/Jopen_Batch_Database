// ============================================================================
// batch-report-shell.js — shared frame of the batch tabs (batch-overview.html
// and the tabs of later phases): load the batch, header with stage pill and
// save status, tab bar, confirm dialog and the "deleted · Undo" toast.
// Needs: config.js, jopen-utils.js, nav.js, batch-stages.js; styles in
// batch-report.css. Spec: docs/batch-report/screens.md, "Shared behaviour".
// ============================================================================

// Tabs in order; page = null until the phase that builds it.
const BATCH_TABS = [
  { key: 'overview', label: 'Overview', page: 'batch-overview.html' },
  { key: 'brewing', label: 'Brewing', page: 'batch-brewing.html' },
  { key: 'fermentation', label: 'Fermentation log', page: 'batch-fermentation.html' },
  { key: 'processing', label: 'Processing', page: null, phase: 5 },
  { key: 'filling', label: 'Filling', page: null, phase: 6 },
  { key: 'filling-report', label: 'Filling report', page: null, phase: 7 },
];

/** Id of the batch in the page URL (?id=…), or null. */
function batchIdFromUrl() {
  const id = Number(new URLSearchParams(window.location.search).get('id'));
  return Number.isInteger(id) && id > 0 ? id : null;
}

/** Link to a batch tab, e.g. batchTabHref('overview', 12). */
function batchTabHref(tabKey, batchId) {
  const tab = BATCH_TABS.find((t) => t.key === tabKey);
  return tab && tab.page ? `${tab.page}?id=${batchId}` : null;
}

/**
 * The batch with its recipe and stage: { batch, recipe, stage }.
 * Throws when the batch does not exist or cannot be read (RLS).
 */
async function loadBatchContext(batchId) {
  const [batchRes, stageRes] = await Promise.all([
    supabaseClient.from('batches')
      .select('*, recipes(id, name, beer_style, location, version_major, version_minor, brew_volume_hl)')
      .eq('id', batchId)
      .maybeSingle(),
    supabaseClient.from('batch_stages').select('*').eq('batch_id', batchId).maybeSingle(),
  ]);
  if (batchRes.error) throw batchRes.error;
  if (!batchRes.data) throw new Error(`Batch ${batchId} not found.`);
  const { recipes: recipe, ...batch } = batchRes.data;
  return { batch, recipe: recipe || {}, stage: (stageRes.data && stageRes.data.stage) || 'raw', stageRow: stageRes.data || null };
}

/**
 * Header + tab bar into `container`. Returns a save indicator with
 * .saving() / .saved() / .failed(message).
 */
function renderBatchHeader(container, ctx, activeTab) {
  const st = stageInfo(ctx.stage);
  const version = versionText(ctx.recipe.version_major, ctx.recipe.version_minor);
  const tabs = BATCH_TABS.map((t) => {
    if (t.key === activeTab) return `<span class="br-tab on" aria-current="page">${escapeHtml(t.label)}</span>`;
    if (!t.page) return `<span class="br-tab off" title="Arrives in phase ${t.phase}">${escapeHtml(t.label)}</span>`;
    return `<a class="br-tab" href="${batchTabHref(t.key, ctx.batch.id)}">${escapeHtml(t.label)}</a>`;
  }).join('');
  container.innerHTML = `
    <div class="br-crumb"><a href="index.html">Home</a> › <a href="all-batches.html">Batch reports</a> › ${escapeHtml(ctx.batch.batch_number)}</div>
    <div class="br-head">
      <div class="br-title">
        <h1>${escapeHtml(ctx.batch.batch_number)}</h1>
        <span class="br-beer">${escapeHtml(ctx.batch.name || ctx.recipe.name || '')} <span class="br-version">${escapeHtml(version)}</span></span>
        ${ctx.recipe.location === 'jk' ? '<span class="br-jk">JK</span>' : ''}
        <span class="br-pill" style="background:${st.pill[0]}; color:${st.pill[1]};">${escapeHtml(st.label)}</span>
      </div>
    </div>`;
  // The tab bar goes right after the header, as a child of <main>: a sticky
  // element only sticks within its parent, and the header ends here.
  document.getElementById('br-tabbar')?.remove();
  const bar = document.createElement('div');
  bar.className = 'br-tabbar';
  bar.id = 'br-tabbar';
  bar.innerHTML = `
      <span class="br-tabbar-batch">${escapeHtml(ctx.batch.batch_number)} · ${escapeHtml(ctx.batch.name || ctx.recipe.name || '')}</span>
      <nav class="br-tabs" aria-label="Batch report tabs">${tabs}</nav>
      <span class="br-save" id="br-save-status" role="status"></span>`;
  container.after(bar);
  watchStickyTabBar(bar);
  const el = bar.querySelector('#br-save-status');
  let pending = 0;
  return {
    saving() { pending += 1; el.className = 'br-save'; el.textContent = 'Saving…'; },
    saved() { pending = Math.max(0, pending - 1); if (!pending) { el.className = 'br-save ok'; el.textContent = 'All changes saved'; } },
    failed(message) { pending = Math.max(0, pending - 1); el.className = 'br-save error'; el.textContent = 'Not saved: ' + message; },
  };
}

// The tab bar sticks below the nav bar (batch-report.css); once it is stuck
// it also shows the batch number, as the big header has scrolled away.
function watchStickyTabBar(bar) {
  const update = () => {
    const navHeight = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--jopen-nav-h')) || 0;
    const stuck = getComputedStyle(bar).position === 'sticky' && bar.getBoundingClientRect().top <= navHeight + 1;
    bar.classList.toggle('stuck', stuck);
  };
  window.addEventListener('scroll', update, { passive: true });
  window.addEventListener('resize', update);
  update();
}

/** Confirm dialog; resolves true when confirmed. */
function confirmDialog({ title, text, okLabel = 'Delete' }) {
  return new Promise((resolve) => {
    const overlay = document.createElement('div');
    overlay.className = 'br-dialog-overlay';
    overlay.innerHTML = `
      <div class="br-dialog" role="alertdialog" aria-modal="true" aria-labelledby="br-dialog-title">
        <div class="br-dialog-title" id="br-dialog-title">${escapeHtml(title)}</div>
        <div class="br-dialog-text">${escapeHtml(text)}</div>
        <div class="br-dialog-buttons">
          <button type="button" class="br-ghost" data-answer="no">Cancel</button>
          <button type="button" class="br-danger" data-answer="yes">${escapeHtml(okLabel)}</button>
        </div>
      </div>`;
    const close = (answer) => { overlay.remove(); document.removeEventListener('keydown', onKey); resolve(answer); };
    const onKey = (e) => { if (e.key === 'Escape') close(false); };
    overlay.addEventListener('click', (e) => {
      const btn = e.target.closest('button[data-answer]');
      if (btn) close(btn.dataset.answer === 'yes');
      else if (e.target === overlay) close(false);
    });
    document.addEventListener('keydown', onKey);
    document.body.appendChild(overlay);
    overlay.querySelector('[data-answer="yes"]').focus();
  });
}

let _brToastTimer = null;
/** Toast "<label> removed" with Undo for 10 s; onUndo is called on Undo. */
function showUndoToast(label, onUndo) {
  document.querySelectorAll('.br-toast').forEach((t) => t.remove());
  clearTimeout(_brToastTimer);
  const toast = document.createElement('div');
  toast.className = 'br-toast';
  toast.setAttribute('role', 'status');
  toast.innerHTML = `<span>${escapeHtml(label)} removed</span>
    <button type="button" class="br-toast-undo">Undo</button>
    <button type="button" class="br-toast-close" aria-label="Dismiss">×</button>`;
  const close = () => { clearTimeout(_brToastTimer); toast.remove(); };
  toast.querySelector('.br-toast-undo').addEventListener('click', () => { close(); onUndo(); });
  toast.querySelector('.br-toast-close').addEventListener('click', close);
  document.body.appendChild(toast);
  _brToastTimer = setTimeout(close, 10000);
}

// ---------------------------------------------------------------- autosave

/**
 * Selector that finds the same control again after a re-render: its id, or
 * all its data-* attributes (e.g. [data-id="12"][data-field="quantity"]).
 */
function focusKeyOf(el) {
  if (!el || el === document.body || !el.dataset) return null;
  if (el.id) return '#' + CSS.escape(el.id);
  const attrs = Object.keys(el.dataset);
  if (!attrs.length) return null;
  return attrs.map((k) => `[data-${k.replace(/[A-Z]/g, (c) => '-' + c.toLowerCase())}="${CSS.escape(el.dataset[k])}"]`).join('');
}

/**
 * Returns renderSoon(focusSelector?): re-renders after the current event and
 * puts focus back on the control the user moved to (a change event fires
 * before focus leaves the input), or on focusSelector when given.
 */
function createRenderer(render) {
  let timer = null, wanted = null;
  return function renderSoon(focusSelector) {
    if (focusSelector) wanted = focusSelector;
    clearTimeout(timer);
    timer = setTimeout(() => {
      const key = wanted || focusKeyOf(document.activeElement);
      wanted = null;
      render();
      const target = key && document.querySelector(key);
      if (target) target.focus();
    }, 0);
  };
}

/**
 * Optimistic save of one row: patch the local `row`, re-render, write
 * `patch` (+ updated_by when the table has it) to `table`, and roll back on
 * an error. Returns true when saved.
 */
async function saveRowPatch({ table, row, patch, saveStatus, renderSoon, userId, stampUpdatedBy = true }) {
  const before = { ...row };
  Object.assign(row, patch);
  renderSoon();
  saveStatus.saving();
  const payload = stampUpdatedBy && userId ? { ...patch, updated_by: userId } : patch;
  const { error } = await supabaseClient.from(table).update(payload).eq('id', row.id).select('id').single();
  if (error) {
    Object.keys(row).forEach((k) => { if (!(k in before)) delete row[k]; });
    Object.assign(row, before);
    renderSoon();
    saveStatus.failed(error.message);
    return false;
  }
  saveStatus.saved();
  return true;
}

/** Number from an input ('2,75' → 2.75); undefined when the text is not a number, null when empty. */
function parseNumberInput(text) {
  const t = String(text ?? '').trim();
  if (t === '') return null;
  const n = Number(t.replace(',', '.'));
  return Number.isFinite(n) ? n : undefined;
}

/** Value for a datetime-local input from a timestamptz (local time). */
function toDateTimeLocal(value) {
  if (!value) return '';
  const d = new Date(value);
  const pad = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

/** Initials per user id, from users.initials. */
async function loadUserInitials() {
  const { data } = await supabaseClient.from('users').select('id, name, initials, is_active').order('name');
  const users = data || [];
  return { users, initialsOf: (id) => (users.find((u) => u.id === id) || {}).initials || '' };
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = { BATCH_TABS, batchIdFromUrl, batchTabHref, parseNumberInput };
}
