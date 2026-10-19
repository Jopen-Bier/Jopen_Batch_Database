// ============================================================================
// recipe-cellar-plan.js — "Cellar plan" block of the recipe editor
// (recept-invoer.html). Shows recipe_cellar_steps, lets the user edit,
// reorder, add and delete steps; the editor saves them with the rest of the
// recipe through rpc save_recipe_cellar_steps, which then regenerates the
// steps that come from the recipe data (generate_recipe_cellar_steps).
// Rules: docs/batch-report/business-rules.md ("Cellar plan generation").
// Needs: config.js, jopen-utils.js (escapeHtml).
// ============================================================================

const CELLAR_TRIGGER_TYPES = [
  { value: 'extract', label: 'At extract (°P)' },
  { value: 'temperature', label: 'At temperature (°C)' },
  { value: 'day', label: 'On day (from Time 0)' },
  { value: 'after_previous', label: 'After previous step' },
];

const cellarPlan = { steps: [], tags: [], loaded: false, nextTempId: -1 };

/** Loads the action tags and, for an existing recipe, its plan. */
async function loadCellarPlan(recipeId) {
  const [tags, steps] = await Promise.all([
    supabaseClient.from('cellar_action_tags').select('id, code, label, is_active, sort_order').order('sort_order').order('id'),
    recipeId
      ? supabaseClient.from('recipe_cellar_steps').select('*').eq('recipe_id', recipeId).order('sort_order').order('id')
      : Promise.resolve({ data: [], error: null }),
  ]);
  const container = document.getElementById('re-cellar-plan');
  if (tags.error || steps.error) {
    container.innerHTML = `<div class="re-leeg">Could not load the cellar plan: ${escapeHtml((tags.error || steps.error).message)}</div>`;
    return;
  }
  cellarPlan.tags = tags.data;
  cellarPlan.steps = steps.data;
  cellarPlan.loaded = true;
  renderCellarPlan();
}

function cellarStepStatus(step) {
  if (!step.generated_key) return { label: 'added by hand', cls: 'hand' };
  return step.is_generated ? { label: 'from recipe data', cls: 'gen' } : { label: 'edited', cls: 'edited' };
}

function renderCellarPlan() {
  const container = document.getElementById('re-cellar-plan');
  if (!cellarPlan.loaded) return;
  const tagOptions = (selected) => cellarPlan.tags.filter((t) => t.is_active || t.id === selected)
    .map((t) => `<option value="${t.id}"${t.id === selected ? ' selected' : ''}>${escapeHtml(t.label)}</option>`).join('');
  const num = (v) => (v === null || v === undefined ? '' : String(v));
  const rows = cellarPlan.steps.map((s, i) => {
    const st = cellarStepStatus(s);
    const usesValue = s.trigger_type === 'extract' || s.trigger_type === 'temperature';
    const links = (s.recipe_ingredient_ids || []).length;
    return `<tr data-step="${s.id}">
      <td class="re-cp-move">
        <button type="button" data-cp-move="-1" aria-label="Move up"${i === 0 ? ' disabled' : ''}>▲</button>
        <button type="button" data-cp-move="1" aria-label="Move down"${i === cellarPlan.steps.length - 1 ? ' disabled' : ''}>▼</button>
      </td>
      <td><input type="text" data-cp-field="title" value="${escapeHtml(s.title || '')}" aria-label="Step">
        <div class="re-cp-meta"><span class="re-cp-status ${st.cls}">${st.label}</span>${links ? ` · ${links} recipe ${links === 1 ? 'line' : 'lines'}` : ''}</div></td>
      <td><input type="text" data-cp-field="description" value="${escapeHtml(s.description || '')}" aria-label="What" placeholder="Instruction"></td>
      <td><select data-cp-field="tag_id" aria-label="Tag">${tagOptions(s.tag_id)}</select></td>
      <td><select data-cp-field="trigger_type" aria-label="When">${CELLAR_TRIGGER_TYPES.map((t) => `<option value="${t.value}"${t.value === s.trigger_type ? ' selected' : ''}>${t.label}</option>`).join('')}</select></td>
      <td><input type="number" step="any" data-cp-field="trigger_value" value="${escapeHtml(num(s.trigger_value))}" aria-label="Value"${usesValue ? '' : ' disabled'}></td>
      <td><input type="number" step="any" data-cp-field="trigger_tol" value="${escapeHtml(num(s.trigger_tol))}" aria-label="Tolerance"${usesValue ? '' : ' disabled'}></td>
      <td><input type="number" step="any" data-cp-field="planned_day" value="${escapeHtml(num(s.planned_day))}" aria-label="Day from Time 0"></td>
      <td style="text-align:center;"><input type="checkbox" data-cp-field="starts_lagering"${s.starts_lagering ? ' checked' : ''} aria-label="Lagering starts"></td>
      <td>${s.is_generated
        ? '<span class="re-cp-hint" title="Generated from the dry hops, cellar additions and fermentation data. Change those to remove it.">auto</span>'
        : '<button type="button" class="re-cp-del" data-cp-delete aria-label="Delete step">×</button>'}</td>
    </tr>`;
  }).join('');
  container.innerHTML = cellarPlan.steps.length ? `
    <table class="re-ing-table re-cp-table">
      <colgroup><col style="width:4%"><col style="width:22%"><col style="width:22%"><col style="width:11%"><col style="width:14%">
        <col style="width:6%"><col style="width:6%"><col style="width:6%"><col style="width:5%"><col style="width:4%"></colgroup>
      <thead><tr><th></th><th>Step</th><th>What</th><th>Tag</th><th>When</th><th>Value</th><th>±</th><th>Day</th><th>Lager</th><th></th></tr></thead>
      <tbody>${rows}</tbody>
    </table>`
    : '<div class="re-leeg">No steps yet. The plan is generated from the dry hops, cellar additions and fermentation data when you save the recipe.</div>';
}

function cellarStepOf(el) {
  const tr = el.closest('tr[data-step]');
  return tr ? cellarPlan.steps.find((s) => String(s.id) === tr.dataset.step) : null;
}

function bindCellarPlanEvents() {
  const container = document.getElementById('re-cellar-plan');
  container.addEventListener('change', (e) => {
    const step = cellarStepOf(e.target);
    const field = e.target.dataset.cpField;
    if (!step || !field) return;
    if (field === 'starts_lagering') step[field] = e.target.checked;
    else if (field === 'tag_id') step[field] = Number(e.target.value);
    else if (['trigger_value', 'trigger_tol', 'planned_day'].includes(field)) step[field] = e.target.value === '' ? null : Number(e.target.value);
    else step[field] = e.target.value;
    // A changed step is no longer overwritten by the generator.
    step.is_generated = false;
    if (field === 'trigger_type') {
      if (step.trigger_type !== 'extract' && step.trigger_type !== 'temperature') { step.trigger_value = null; step.trigger_tol = null; }
    }
    renderCellarPlan();
  });
  container.addEventListener('click', (e) => {
    const move = e.target.closest('button[data-cp-move]');
    const del = e.target.closest('button[data-cp-delete]');
    const step = (move || del) && cellarStepOf(e.target);
    if (!step) return;
    const i = cellarPlan.steps.indexOf(step);
    if (move) {
      const j = i + Number(move.dataset.cpMove);
      if (j < 0 || j >= cellarPlan.steps.length) return;
      [cellarPlan.steps[i], cellarPlan.steps[j]] = [cellarPlan.steps[j], cellarPlan.steps[i]];
    } else {
      cellarPlan.steps.splice(i, 1);
    }
    renderCellarPlan();
  });
  document.getElementById('re-cellar-plan-add').addEventListener('click', () => {
    const tag = cellarPlan.tags.find((t) => t.code === 'other') || cellarPlan.tags[0];
    cellarPlan.steps.push({ id: cellarPlan.nextTempId--, title: '', description: '', tag_id: tag ? tag.id : null, trigger_type: 'after_previous',
      trigger_value: null, trigger_tol: null, planned_day: null, starts_lagering: false, is_generated: false, generated_key: null, recipe_ingredient_ids: [] });
    renderCellarPlan();
    const inputs = document.querySelectorAll('#re-cellar-plan [data-cp-field="title"]');
    inputs[inputs.length - 1].focus();
  });
}

/**
 * Steps to save, in screen order (null while the plan did not load: the
 * caller then leaves the plan alone). New steps have no id; a step without a
 * title is skipped.
 */
function readCellarPlan() {
  if (!cellarPlan.loaded) return null;
  return cellarPlan.steps.filter((s) => String(s.title || '').trim() && s.tag_id).map((s, i) => ({
    id: s.id > 0 ? s.id : null,
    sort_order: (i + 1) * 10,
    tag_id: s.tag_id,
    title: String(s.title).trim(),
    description: s.description || null,
    trigger_type: s.trigger_type,
    trigger_value: s.trigger_value,
    trigger_tol: s.trigger_tol,
    planned_day: s.planned_day,
    starts_lagering: !!s.starts_lagering,
    is_generated: !!s.is_generated,
    generated_key: s.generated_key || null,
  }));
}

/** A step "On day" needs a day; returns a problem text or ''. */
function cellarPlanProblem() {
  const lines = readCellarPlan() || [];
  const bad = lines.find((s) => s.trigger_type === 'day' && (s.planned_day === null || s.planned_day === undefined));
  return bad ? `Cellar plan: step "${bad.title}" is "On day" but has no day.` : '';
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = { CELLAR_TRIGGER_TYPES, cellarPlan, readCellarPlan, cellarPlanProblem };
}
