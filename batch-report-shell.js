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
  { key: 'brewing', label: 'Brewing', page: null, phase: 3 },
  { key: 'fermentation', label: 'Fermentation log', page: null, phase: 4 },
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
    supabaseClient.from('batch_stages').select('stage, start_date, end_date').eq('batch_id', batchId).maybeSingle(),
  ]);
  if (batchRes.error) throw batchRes.error;
  if (!batchRes.data) throw new Error(`Batch ${batchId} not found.`);
  const { recipes: recipe, ...batch } = batchRes.data;
  return { batch, recipe: recipe || {}, stage: (stageRes.data && stageRes.data.stage) || 'raw' };
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
      <span class="br-save" id="br-save-status" role="status"></span>
    </div>
    <nav class="br-tabs" aria-label="Batch report tabs">${tabs}</nav>`;
  const el = container.querySelector('#br-save-status');
  let pending = 0;
  return {
    saving() { pending += 1; el.className = 'br-save'; el.textContent = 'Saving…'; },
    saved() { pending = Math.max(0, pending - 1); if (!pending) { el.className = 'br-save ok'; el.textContent = 'All changes saved'; } },
    failed(message) { pending = Math.max(0, pending - 1); el.className = 'br-save error'; el.textContent = 'Not saved: ' + message; },
  };
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

if (typeof module !== 'undefined' && module.exports) {
  module.exports = { BATCH_TABS, batchIdFromUrl, batchTabHref };
}
