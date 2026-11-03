// ============================================================================
// recipe-brewhouse-design.js — the "Brewhouse design" card of the recipe page
// (recept-invoer.html): Brewcalc in the app (Jaap, 23-10 / 03-11). Reads the
// grist (Malt & Grains), Brouwsel (hl), the original extract and the brewing
// parameters it shares (mash thickness, mash-in temp, evaporation, mash
// filter chambers); its own inputs are saved in recipe_brewing_specs
// (design_*). The calculation is brewhouseDesign() of brewhouse-design.js.
// "Scale grist" changes the malt amounts; "Apply" fills the brewing
// parameters. Nothing is saved until Save recipe.
//
// Page hooks: fillBrewhouseDesign(brewingSpecs) after the brewing parameters
// are rendered, readBrewhouseDesign() into the recipe_brewing_specs upsert,
// bindBrewhouseDesignEvents() once. Needs alleIngredientenLijst with
// extract_pct and malt_equivalent per ingredient.
// ============================================================================

// The design inputs of the card: [column, label, unit, default, hint]
const BREWHOUSE_DESIGN_INPUTS = [
  ['design_cast_extract', 'Extract at casting', '°P', null, 'Empty = the original extract. Higher means dilution water to the GLT.'],
  ['design_brewhouse_loss_pct', 'Mash and filter loss', '% of lab extract', BREWHOUSE_DEFAULTS.brewhouseLossPct, 'Lab extract to the start of the boil (spent grains). Measured ~7 % over 62 WP brews.'],
  ['design_whirlpool_loss_pct', 'Whirlpool loss', '%', BREWHOUSE_DEFAULTS.whirlpoolLossPct, 'Standard whirlpool and transfer loss, times the hop factor.'],
  ['design_hop_correction', 'Hop factor', '×', BREWHOUSE_DEFAULTS.hopCorrection, '3 for hoppy beers, 2 for the others.'],
];

// Brewing parameters the card reads (and fills in when empty on Apply): page field key, default
const BREWHOUSE_SHARED = {
  waterGristRatio: ['beslag_dikte', BREWHOUSE_DEFAULTS.waterGristRatio, 'Mash thickness', 'l/kg'],
  mashInTemp: ['mash_inmaischen_temp', BREWHOUSE_DEFAULTS.mashInTemp, 'Mash-in temp', '°C'],
  evaporationPct: ['gewenste_verdamping', BREWHOUSE_DEFAULTS.evaporationPct, 'Desired evaporation', '%'],
  chambers: ['kamers_mashfilter', BREWHOUSE_DEFAULTS.chambers, 'Mash filter chambers', ''],
};

// Apply: result → brewing parameter field (page key), decimals
const BREWHOUSE_APPLY = [
  ['mashWaterHl', 'maischwater', 1, 'Mash water'],
  ['spargeWaterHl', 'cumm_sparging_vol', 1, 'Cumm. sparging volume'],
  ['boilStartHl', 'volume_kook', 1, 'Boil volume'],
  ['boilStartPlato', 'verwacht_extract_begin_kook', 1, 'Expected extract at start of boil'],
  ['dilutionHl', 'volume_water_additie_terugkoeling', 1, 'Water addition volume (back-cooling)'],
  ['toGltHl', 'eindvolume_brouwsel', 1, 'Final brew volume'],
];

const bhd = { values: {}, message: '' };

function bhdNumber(text) {
  const t = String(text ?? '').trim().replace(',', '.');
  if (t === '') return null;
  const n = Number(t);
  return Number.isFinite(n) ? n : null;
}
const bhdField = (key) => document.getElementById('veld-' + key);
const bhdFmt = (v, d = 1) => (v === null || v === undefined || !Number.isFinite(v) ? '—' : v.toLocaleString('en-GB', { minimumFractionDigits: d, maximumFractionDigits: d }));

/** The malt rows of the Malt & Grains table with their ingredient data. */
function bhdGrist() {
  const byId = new Map((typeof alleIngredientenLijst !== 'undefined' ? alleIngredientenLijst : []).map((i) => [i.id, i]));
  return Array.from(document.querySelectorAll('#re-ing-mout-tbody tr')).map((tr) => {
    const id = bhdNumber(tr.querySelector('.re-ing-ingredient')?.value);
    const ing = byId.get(id) || {};
    return {
      tr, name: ing.naam || '(no ingredient)', kg: bhdNumber(tr.querySelector('.re-ing-hoeveelheid')?.value) || 0,
      labYield: ing.extract_pct === null || ing.extract_pct === undefined ? null : Number(ing.extract_pct) / 100,
      meFactor: ing.malt_equivalent === null || ing.malt_equivalent === undefined ? 1 : Number(ing.malt_equivalent),
    };
  }).filter((g) => g.kg > 0);
}

/** Everything the calculation needs, with the defaults filled in, or a reason why not. */
function bhdState() {
  const grist = bhdGrist();
  const targetHl = bhdNumber(bhdField('brouwsel_hl')?.value);
  const originalExtract = bhdNumber(bhdField('origineel_extract')?.value);
  const shared = {};
  Object.entries(BREWHOUSE_SHARED).forEach(([opt, [key, def]]) => {
    const v = bhdNumber(bhdField(key)?.value);
    shared[opt] = v === null ? def : v;
  });
  const own = {};
  BREWHOUSE_DESIGN_INPUTS.forEach(([col, , , def]) => { own[col] = bhd.values[col] ?? def; });
  const castPlato = own.design_cast_extract ?? originalExtract;
  const missingYield = grist.filter((g) => g.labYield === null).map((g) => g.name);
  let problem = '';
  if (!grist.length) problem = 'Add the malts in Malt & Grains.';
  else if (originalExtract === null) problem = 'Fill in the original extract (End product specifications).';
  else if (missingYield.length) problem = `No extract % on the ingredient card of: ${missingYield.join(', ')}.`;
  const options = {
    ...shared, castPlato, transferPlato: originalExtract,
    brewhouseLossPct: own.design_brewhouse_loss_pct, whirlpoolLossPct: own.design_whirlpool_loss_pct, hopCorrection: own.design_hop_correction,
  };
  return { grist, targetHl, originalExtract, options, problem };
}

/** Draw the card: its inputs once, then the live part. */
function renderBrewhouseDesign() {
  const box = document.getElementById('re-brewhouse-design');
  if (!box) return;
  const inputs = BREWHOUSE_DESIGN_INPUTS.map(([col, label, unit, def, hint]) => `
    <div class="re-paramrow-simple" title="${escapeHtml(hint)}">
      <label for="bhd-${col}">${label} (${unit})</label>
      <input type="number" step="any" id="bhd-${col}" data-bhd="${col}" value="${bhd.values[col] ?? ''}" placeholder="${def ?? ''}" />
    </div>`).join('');
  box.innerHTML = `
    <div class="re-bhd-shared" id="bhd-shared"></div>
    <div class="re-bhd-grid">
      <div class="re-param-columns">${inputs}</div>
      <div id="bhd-results"></div>
    </div>
    <div class="re-bhd-actions">
      <button type="button" class="re-btn secundair" id="bhd-scale" disabled></button>
      <button type="button" class="re-btn secundair" id="bhd-apply" disabled>Apply to brewing parameters</button>
      <span class="re-bhd-msg" id="bhd-msg"></span>
    </div>`;
  updateBrewhouseDesign();
}

/** The live part: shared parameters, results, buttons, message. */
function updateBrewhouseDesign() {
  if (!document.getElementById('bhd-results')) return;
  const st = bhdState();
  const r = st.problem ? null : brewhouseDesign(st.grist, st.options);
  const shared = Object.entries(BREWHOUSE_SHARED).map(([opt, [key, def, label, unit]]) => {
    const fromPage = bhdNumber(bhdField(key)?.value) !== null;
    return `<span class="re-bhd-chip" title="${fromPage ? 'From Brewing parameters' : 'Empty in Brewing parameters: the default is used'}">${label} <b>${bhdFmt(st.options[opt], opt === 'chambers' || opt === 'mashInTemp' ? 0 : 2)}${unit ? ' ' + unit : ''}</b>${fromPage ? '' : ' <i>default</i>'}</span>`;
  }).join('');
  const castEl = document.getElementById('bhd-design_cast_extract');
  if (castEl) castEl.placeholder = st.originalExtract ?? '';
  let results = `<div class="re-bhd-problem">${escapeHtml(st.problem)}</div>`;
  if (r) {
    const diff = st.targetHl === null ? null : r.toGltHl - st.targetHl;
    const volOk = diff !== null && Math.abs(diff) <= 0.5;
    const row = (label, value, note = '', cls = '') => `<tr class="${cls}"><td>${label}</td><td class="re-bhd-n">${value}</td><td class="re-bhd-note">${note}</td></tr>`;
    results = `<table class="re-bhd-results"><tbody>
      ${row('<b>Volume to the GLT</b>', `<b>${bhdFmt(r.toGltHl)} hl</b>`, st.targetHl === null ? 'fill in Brouwsel (hl) to compare' : `${volOk ? '✓' : '✗'} target ${bhdFmt(st.targetHl)} hl (${diff >= 0 ? '+' : ''}${bhdFmt(diff)})`, st.targetHl === null ? '' : volOk ? 'ok' : 'bad')}
      ${row('<b>Load per chamber</b>', `<b>${bhdFmt(r.loadPerChamber)} kg</b>`, `${r.loadOk ? '✓' : '✗'} ${CHAMBER_LOAD.min}–${CHAMBER_LOAD.max} kg (nominal ${CHAMBER_LOAD.nominal}) · ${bhdFmt(r.meKg, 0)} kg malt equivalent / ${r.chambers} chambers`, r.loadOk ? 'ok' : 'bad')}
      ${row('Extract', `${bhdFmt(r.extractKg, 0)} kg`, `lab ${bhdFmt(r.labExtractKg, 0)} kg − ${bhdFmt(st.options.brewhouseLossPct)} % mash and filter`)}
      ${row('Mash water', `${bhdFmt(r.mashWaterHl)} hl`, `${bhdFmt(r.mashKg, 0)} kg × ${bhdFmt(st.options.waterGristRatio, 2)} l/kg`)}
      ${row('Sparge water', `${bhdFmt(r.spargeWaterHl)} hl`, 'water balance: wort at the start of the boil + water in the spent grains − mash water')}
      ${row('Start of boil', `${bhdFmt(r.boilStartHl)} hl · ${bhdFmt(r.boilStartPlato)} °P`, 'hot')}
      ${row('End of boil', `${bhdFmt(r.boilEndHl)} hl · ${bhdFmt(st.options.castPlato)} °P`, `hot · ${bhdFmt(st.options.evaporationPct)} % evaporation`)}
      ${row('Whirlpool loss', `${bhdFmt(r.wpLossHl)} hl`, `${bhdFmt(st.options.whirlpoolLossPct)} % × ${bhdFmt(st.options.hopCorrection)}`)}
      ${row('Dilution water', `${bhdFmt(r.dilutionHl)} hl`, r.dilutionHl > 0 ? 'casting above the original extract' : '')}
    </tbody></table>`;
  }
  document.getElementById('bhd-shared').innerHTML = shared;
  document.getElementById('bhd-results').innerHTML = results;
  const scale = document.getElementById('bhd-scale');
  scale.textContent = `Scale grist to ${st.targetHl === null ? 'Brouwsel (hl)' : bhdFmt(st.targetHl) + ' hl'}`;
  scale.disabled = !(r && st.targetHl);
  document.getElementById('bhd-apply').disabled = !r;
  document.getElementById('bhd-msg').textContent = bhd.message;
}

/** Fill the card's own inputs from the recipe's brewing specs (English keys) and draw it. */
function fillBrewhouseDesign(specs) {
  bhd.values = {};
  BREWHOUSE_DESIGN_INPUTS.forEach(([col]) => {
    const v = specs ? specs[col] : null;
    bhd.values[col] = v === null || v === undefined || v === '' ? null : Number(v);
  });
  bhd.message = '';
  renderBrewhouseDesign();
}

/** The card's inputs for the recipe_brewing_specs upsert (empty = default). */
function readBrewhouseDesign() {
  const out = {};
  BREWHOUSE_DESIGN_INPUTS.forEach(([col]) => { out[col] = bhd.values[col] ?? null; });
  return out;
}

function bhdSetField(key, value) {
  const el = bhdField(key);
  if (!el) return false;
  el.value = value;
  el.classList.add('re-bhd-filled');
  setTimeout(() => el.classList.remove('re-bhd-filled'), 2500);
  return true;
}

function bhdApply() {
  const st = bhdState();
  if (st.problem) return;
  const r = brewhouseDesign(st.grist, st.options);
  // the shared parameters the design used, where the recipe had none
  Object.entries(BREWHOUSE_SHARED).forEach(([opt, [key]]) => {
    if (bhdNumber(bhdField(key)?.value) === null) bhdSetField(key, st.options[opt]);
  });
  const filled = BREWHOUSE_APPLY.filter(([res, key, d]) => bhdSetField(key, Math.round(r[res] * 10 ** d) / 10 ** d)).map((a) => a[3]);
  bhd.message = `Filled: ${filled.join(', ')}. Save the recipe to keep them.`;
  updateBrewhouseDesign();
}

function bhdScale() {
  const st = bhdState();
  if (st.problem || !st.targetHl) return;
  const f = gristFactorForVolume(st.grist, st.options, st.targetHl);
  st.grist.forEach((g) => {
    const el = g.tr.querySelector('.re-ing-hoeveelheid');
    el.value = Math.round(g.kg * f);
    el.dispatchEvent(new Event('input', { bubbles: true }));
  });
  bhd.message = `Grist × ${f.toFixed(3)}: malt amounts rounded to whole kg. Save the recipe to keep them.`;
  updateBrewhouseDesign();
}

function bindBrewhouseDesignEvents() {
  let pending = null;
  const soon = () => { clearTimeout(pending); pending = setTimeout(updateBrewhouseDesign, 150); };
  document.addEventListener('input', (e) => {
    const el = e.target;
    if (el.dataset && el.dataset.bhd) { bhd.values[el.dataset.bhd] = bhdNumber(el.value); bhd.message = ''; return soon(); }
    if (el.closest && (el.closest('#re-ing-mout-tbody') || ['veld-brouwsel_hl', 'veld-origineel_extract'].includes(el.id)
      || Object.values(BREWHOUSE_SHARED).some(([key]) => el.id === 'veld-' + key))) soon();
  });
  // a malt picked or removed in the table changes the grist without an input event
  document.addEventListener('change', (e) => { if (e.target.closest && e.target.closest('#re-ing-mout-tbody')) soon(); });
  document.addEventListener('click', (e) => {
    if (e.target.closest('#bhd-apply')) return bhdApply();
    if (e.target.closest('#bhd-scale')) return bhdScale();
    if (e.target.closest('#re-ing-mout-tbody')) soon();
  });
}
