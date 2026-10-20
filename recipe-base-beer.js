// ============================================================================
// recipe-base-beer.js — "Base beer" block of the recipe editor
// (recept-invoer.html), for recipes made from a split of another beer (a
// blend, a fruit or barrel-aged version). A line references the source beer
// by recipe group (all its versions) with its share in %; the editor saves
// the lines with the other ingredient lines (rpc save_recipe_ingredients,
// addition_type 'base_beer'). The volume comes from the Split / transfer
// popup. Rules: docs/batch-report/business-rules.md ("Transfers (splits)").
// Needs: config.js, jopen-utils.js (escapeHtml).
// ============================================================================

const baseBeer = { lines: [], groups: [], ownGroupId: null, nextTempId: -1 };

/** Beers to choose from: one per recipe group, named after its newest version. */
async function loadBaseBeerGroups(ownGroupId) {
  baseBeer.ownGroupId = ownGroupId || null;
  const { data, error } = await supabaseClient.from('recipes').select('id, name, recipe_group_id, version_major, version_minor, status');
  const newest = new Map();
  (error ? [] : data || []).forEach((r) => {
    const cur = newest.get(r.recipe_group_id);
    if (!cur || r.version_major > cur.version_major || (r.version_major === cur.version_major && r.version_minor > cur.version_minor)) newest.set(r.recipe_group_id, r);
  });
  baseBeer.groups = [...newest.values()].map((r) => ({ groupId: r.recipe_group_id, name: r.name, archived: r.status === 'archived' }))
    .sort((a, b) => a.name.localeCompare(b.name));
}

/** Lines of the recipe (rows as loaded, Dutch or English keys). */
function fillBaseBeerLines(rows) {
  baseBeer.lines = (rows || []).filter((r) => (r.rol || r.addition_type) === 'base_beer').map((r) => ({
    id: r.id ?? null,
    groupId: r.source_recipe_group_id,
    share: r.hoeveelheid ?? r.quantity ?? '',
    note: r.notitie ?? r.note ?? '',
  }));
  renderBaseBeer();
}

function renderBaseBeer() {
  const el = document.getElementById('re-base-beer');
  if (!el) return;
  const option = (g, selected) => `<option value="${escapeHtml(g.groupId)}"${g.groupId === selected ? ' selected' : ''}>${escapeHtml(g.name)}${g.archived ? ' (archived)' : ''}</option>`;
  const rows = baseBeer.lines.map((l, i) => `<tr data-bb="${i}">
    <td><select class="re-bb-group" aria-label="Beer"><option value="">Choose beer</option>
      ${baseBeer.groups.filter((g) => g.groupId !== baseBeer.ownGroupId || g.groupId === l.groupId).map((g) => option(g, l.groupId)).join('')}</select></td>
    <td><input type="number" class="re-bb-share" min="0" max="100" step="any" value="${escapeHtml(String(l.share ?? ''))}" aria-label="Share %"></td>
    <td><input type="text" class="re-bb-note" value="${escapeHtml(l.note || '')}" aria-label="Note"></td>
    <td><button type="button" class="re-bb-del" aria-label="Remove base beer" title="Remove">×</button></td></tr>`).join('');
  const total = baseBeer.lines.reduce((s, l) => s + (Number(l.share) || 0), 0);
  el.innerHTML = baseBeer.lines.length ? `<table class="re-ing-table re-bb-table">
      <colgroup><col style="width:42%"><col style="width:14%"><col style="width:40%"><col style="width:4%"></colgroup>
      <thead><tr><th>Beer (all versions)</th><th>Share %</th><th>Note</th><th></th></tr></thead>
      <tbody>${rows}</tbody>
      <tfoot><tr><td>Total</td><td class="${Math.abs(total - 100) > 1e-9 ? 're-bb-off' : ''}">${total.toLocaleString('en-GB', { maximumFractionDigits: 2 })} %</td><td colspan="2"></td></tr></tfoot>
    </table>` : '<div class="re-leeg">No base beer: the recipe is brewed. Add one for a recipe made from a split of another beer.</div>';
}

/** Problem text before saving, or '' (each line a beer and a share above 0 up to 100). */
function baseBeerProblem() {
  const bad = baseBeer.lines.find((l) => !l.groupId || !(Number(l.share) > 0 && Number(l.share) <= 100));
  return bad ? 'Base beer: choose the beer and a share above 0 up to 100 % on every line.' : '';
}

/** Lines for save_recipe_ingredients (English keys). */
function readBaseBeerLines() {
  return baseBeer.lines.map((l, i) => ({
    id: l.id && l.id > 0 ? l.id : null, addition_type: 'base_beer', ingredient_id: null,
    source_recipe_group_id: l.groupId, quantity: Number(l.share), unit: '%', sort_order: i + 1,
    note: String(l.note || '').trim() || null, timing: null,
  }));
}

function bindBaseBeerEvents() {
  const el = document.getElementById('re-base-beer');
  document.getElementById('re-base-beer-add').addEventListener('click', () => {
    baseBeer.lines.push({ id: null, groupId: '', share: baseBeer.lines.length ? '' : 100, note: '' });
    renderBaseBeer();
    el.querySelector(`tr[data-bb="${baseBeer.lines.length - 1}"] .re-bb-group`)?.focus();
  });
  el.addEventListener('change', (e) => {
    const tr = e.target.closest('tr[data-bb]');
    if (!tr) return;
    const line = baseBeer.lines[Number(tr.dataset.bb)];
    if (e.target.classList.contains('re-bb-group')) line.groupId = e.target.value;
    if (e.target.classList.contains('re-bb-share')) line.share = e.target.value;
    if (e.target.classList.contains('re-bb-note')) line.note = e.target.value;
    renderBaseBeer();
  });
  el.addEventListener('click', (e) => {
    const del = e.target.closest('.re-bb-del');
    if (!del) return;
    baseBeer.lines.splice(Number(del.closest('tr').dataset.bb), 1);
    renderBaseBeer();
  });
}
