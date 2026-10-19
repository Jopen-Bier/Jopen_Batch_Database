// ============================================================================
// batch-stages.js — stages of a batch and the list logic of the batch-report
// navigation pages (all-batches.html, active-batches.html).
//
// The stage itself is derived in the database (view batch_stages,
// docs/batch-report/business-rules.md); this module only labels, groups,
// filters and sorts. Loaded in the browser (<script src="batch-stages.js">)
// and in Node (tests/batch-stages.test.js).
// ============================================================================

// Stage codes in process order, as returned by batch_stages.stage.
// pill = [background, text colour] (mockup AllBatches).
const BATCH_STAGES = [
  { code: 'raw',          label: 'Raw material preparation', short: 'Raw mat.',     pill: ['#f1eee5', '#6b6355'] },
  { code: 'brewing',      label: 'Brewing',                  short: 'Brewing',      pill: ['#fdf1d8', '#7a4f17'] },
  { code: 'fermentation', label: 'Fermentation',             short: 'Fermentation', pill: ['#fbe3c8', '#7a4011'] },
  { code: 'lagering',     label: 'Lagering',                 short: 'Lagering',     pill: ['#dde7f0', '#244766'] },
  { code: 'hbt',          label: 'HBT',                      short: 'HBT',          pill: ['#e3def0', '#3f2f6b'] },
  { code: 'filling',      label: 'Filling',                  short: 'Filling',      pill: ['#d6ebe6', '#1f5448'] },
  { code: 'filled',       label: 'Filled',                   short: 'Filled',       pill: ['#e1ead9', '#33473a'] },
  { code: 'closed',       label: 'Closed',                   short: 'Closed',       pill: ['#33473a', '#ffffff'] },
];

// Blocks on Active batches, top to bottom. Cellar holds two stages.
const ACTIVE_SECTIONS = [
  { key: 'raw',     title: 'Raw material preparation', stages: ['raw'],
    rule: 'Batch created · not brewed yet' },
  { key: 'brewing', title: 'Brewing', stages: ['brewing'],
    rule: 'Brew 1 has started · until the last brew is done' },
  { key: 'cellar',  title: 'Cellar', stages: ['fermentation', 'lagering'],
    rule: 'Last brew done · until Processing has a date' },
  { key: 'hbt',     title: 'HBT', stages: ['hbt'],
    rule: 'Processing has a date · until the first filling input' },
  { key: 'filling', title: 'Filling', stages: ['filling'],
    rule: 'First filling input · until every HBT is finished' },
  { key: 'filled',  title: 'Filled', stages: ['filled'],
    rule: 'All HBTs finished · until the filling report is closed' },
];

function stageInfo(code) {
  return BATCH_STAGES.find((s) => s.code === code) || { code, label: code || '—', short: code || '—', pill: ['#f1eee5', '#6b6355'] };
}

function stageOrder(code) {
  const i = BATCH_STAGES.findIndex((s) => s.code === code);
  return i < 0 ? BATCH_STAGES.length : i;
}

/** Year of a batch from its number: '26346' → 2026. Unknown format → null. */
function batchYear(batchNumber) {
  const m = /^(\d{2})\d{3,}$/.exec(String(batchNumber || '').trim());
  return m ? 2000 + Number(m[1]) : null;
}

/** Number in a tank code: 'GLT21' → 21, 'HBT 12' → 12; no tank → null. */
function tankNumber(code) {
  const m = /\d+/.exec(String(code || ''));
  return m ? Number(m[0]) : null;
}

/** 'v15.3' from the recipe's version columns. */
function versionText(major, minor) {
  return `v${major ?? 1}.${minor ?? 0}`;
}

/**
 * One list row from a `batches` row (with embedded `recipes`) and its
 * `batch_stages` row. All later screens can add fields here.
 */
function toBatchRow(batch, stageRow) {
  const recipe = batch.recipes || {};
  return {
    id: batch.id,
    batchNumber: batch.batch_number,
    name: batch.name || recipe.name || '',
    version: versionText(recipe.version_major, recipe.version_minor),
    versionSort: (recipe.version_major ?? 1) * 1000 + (recipe.version_minor ?? 0),
    location: recipe.location || null,
    brewCount: batch.brew_count,
    orderPickingDate: batch.order_picking_date || null,
    stage: (stageRow && stageRow.stage) || 'raw',
    startDate: (stageRow && stageRow.start_date) || null,
    endDate: (stageRow && stageRow.end_date) || null,
    tankCode: null,   // fermentation tank, from phase 4 (batches.glt_tank_id)
    attention: [],    // "!" reasons; rules still to be agreed (open-questions #1)
  };
}

function matchesLocation(row, location) {
  return !location || row.location === location;
}

function matchesSearch(row, q, withTank) {
  const needle = String(q || '').trim().toLowerCase();
  if (!needle) return true;
  const hay = [row.batchNumber, row.name, withTank ? row.tankCode : ''].join(' ').toLowerCase();
  return hay.includes(needle);
}

/**
 * All batches: filter on search text (batch number, name), stage, year
 * (number) and location ('wp' / 'jk'); empty filters are ignored.
 */
function filterBatches(rows, { q = '', stage = '', year = null, location = '' } = {}) {
  return rows.filter((r) =>
    matchesSearch(r, q, false) &&
    (!stage || r.stage === stage) &&
    (!year || batchYear(r.batchNumber) === Number(year)) &&
    matchesLocation(r, location));
}

const SORT_KEYS = {
  batchNumber: (r) => r.batchNumber,
  name: (r) => r.name.toLowerCase(),
  version: (r) => r.versionSort,
  stage: (r) => stageOrder(r.stage),
  startDate: (r) => r.startDate || '9999',
  endDate: (r) => r.endDate || '9999',
};

/** Sorted copy; dir 1 = ascending, -1 = descending. Ties: newest batch first. */
function sortBatches(rows, key = 'batchNumber', dir = -1) {
  const k = SORT_KEYS[key] || SORT_KEYS.batchNumber;
  return rows.slice().sort((a, b) => {
    const x = k(a), y = k(b);
    const c = x < y ? -1 : x > y ? 1 : 0;
    return c * dir || String(b.batchNumber).localeCompare(String(a.batchNumber));
  });
}

/** Active batches order: tank number, batches without a tank last, then batch number. */
function compareByTank(a, b) {
  const ta = tankNumber(a.tankCode), tb = tankNumber(b.tankCode);
  if (ta !== tb) {
    if (ta === null) return 1;
    if (tb === null) return -1;
    return ta - tb;
  }
  return String(a.batchNumber).localeCompare(String(b.batchNumber));
}

/**
 * Active batches: rows grouped into ACTIVE_SECTIONS (closed batches left out).
 * Filters: search (beer, batch, tank), location, attentionOnly.
 * Section counts are after filtering; `summary` counts per stage use the
 * location filter only, like the mockup.
 */
function groupActiveBatches(rows, { q = '', location = '', attentionOnly = false } = {}) {
  const active = rows.filter((r) => r.stage !== 'closed' && matchesLocation(r, location));
  const visible = active.filter((r) => matchesSearch(r, q, true) && (!attentionOnly || r.attention.length > 0));
  const sections = ACTIVE_SECTIONS.map((sec) => {
    const groups = sec.stages.map((code) => {
      const items = visible.filter((r) => r.stage === code).sort(compareByTank);
      return { stage: code, label: sec.stages.length > 1 ? stageInfo(code).label : '', items };
    });
    const items = groups.flatMap((g) => g.items);
    return { ...sec, groups, count: items.length, attentionCount: items.filter((r) => r.attention.length).length };
  });
  const summary = BATCH_STAGES.filter((s) => s.code !== 'closed')
    .map((s) => ({ stage: s.code, label: s.short, count: active.filter((r) => r.stage === s.code).length }));
  return {
    sections,
    summary,
    total: active.length,
    attentionTotal: active.filter((r) => r.attention.length).length,
  };
}

/** 'dd-mm' for a yyyy-mm-dd date. */
function dayMonth(isoDate) {
  const m = /^\d{4}-(\d{2})-(\d{2})/.exec(String(isoDate || ''));
  return m ? `${m[2]}-${m[1]}` : '';
}

/**
 * The two status lines of an Active batches tile: { line1, line2, isOk }.
 * Only Raw material preparation has data so far; the other stages get their
 * lines in the phase that creates their tables.
 */
function tileLines(row) {
  if (row.stage === 'raw') {
    const brews = Number(row.brewCount) || 0;
    return {
      line1: row.orderPickingDate ? `Order picking ${dayMonth(row.orderPickingDate)}` : 'No order picking date',
      line2: `${brews} ${brews === 1 ? 'brew' : 'brews'}`,
      isOk: false,
    };
  }
  return { line1: stageInfo(row.stage).label, line2: '', isOk: false };
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    BATCH_STAGES, ACTIVE_SECTIONS,
    stageInfo, stageOrder, batchYear, tankNumber, versionText, toBatchRow,
    filterBatches, sortBatches, compareByTank, groupActiveBatches, dayMonth, tileLines,
  };
}
