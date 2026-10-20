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
    orderPickingComplete: !!batch.order_picking_completed_at,
    stage: (stageRow && stageRow.stage) || 'raw',
    startDate: (stageRow && stageRow.start_date) || null,
    endDate: (stageRow && stageRow.end_date) || null,
    brewsPlanned: (stageRow && stageRow.brews_planned) || 0,
    brewsStarted: (stageRow && stageRow.brews_started) || 0,
    brewsEnded: (stageRow && stageRow.brews_ended) || 0,
    lastBrewEndedAt: (stageRow && stageRow.last_brew_ended_at) || null,
    timeZero: (stageRow && stageRow.time_zero) || null,
    cellarStepsTotal: (stageRow && stageRow.cellar_steps_total) || 0,
    cellarStepsDone: (stageRow && stageRow.cellar_steps_done) || 0,
    nextCellarStep: (stageRow && stageRow.next_cellar_step) || null,
    hbtsTotal: (stageRow && stageRow.hbts_total) || 0,
    hbtsReleased: (stageRow && stageRow.hbts_released) || 0,
    hbtCodes: (stageRow && stageRow.hbt_codes) || null,
    hbtFormats: (stageRow && stageRow.hbt_formats) || [],
    // the tank the beer is in: the lager tank once it is pushed over, else the fermentation tank
    // (from HBT on: the bright beer tanks)
    tankCode: (['hbt', 'filling', 'filled'].includes(stageRow && stageRow.stage) && stageRow.hbt_codes)
      || (batch.lt_tank && batch.lt_tank.code) || (batch.glt_tank && batch.glt_tank.code) || null,
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
 * The two status lines of an Active batches tile: { line1, line2, isOk,
 * progress } (progress 0–1 for the bar, or null). Stages without data yet get
 * their lines in the phase that creates their tables.
 */
function tileLines(row, now = new Date()) {
  if (row.stage === 'raw') {
    return {
      line1: row.orderPickingDate ? `Order picking ${dayMonth(row.orderPickingDate)}` : 'No order picking date',
      line2: row.orderPickingComplete ? '✓ Picked' : 'Not picked yet',
      isOk: row.orderPickingComplete,
      progress: null,
    };
  }
  if (row.stage === 'brewing') {
    const planned = row.brewsPlanned || 0, ended = row.brewsEnded || 0;
    const busy = (row.brewsStarted || 0) > ended;
    return {
      line1: `Brew ${ended} / ${planned}`,
      line2: busy ? `Brewing: brew ${ended + 1}` : `Next: brew ${ended + 1}`,
      isOk: false,
      progress: planned ? Math.min(1, ended / planned) : null,
    };
  }
  if (row.stage === 'fermentation' || row.stage === 'lagering') {
    const total = row.cellarStepsTotal || 0, done = row.cellarStepsDone || 0;
    const days = row.timeZero ? (new Date(now) - new Date(row.timeZero)) / 86400000 : null;
    const allDone = total > 0 && done >= total;
    return {
      line1: [days !== null ? `Day ${Math.max(0, days).toFixed(1)}` : null, total ? `tasks ${done}/${total}` : 'no cellar plan'].filter(Boolean).join(' · '),
      line2: allDone ? '✓ All tasks done' : row.nextCellarStep ? `Next: ${row.nextCellarStep}` : '',
      isOk: allDone,
      progress: total ? Math.min(1, done / total) : null,
    };
  }
  if (row.stage === 'hbt') {
    const total = row.hbtsTotal || 0, released = row.hbtsReleased || 0;
    const allReleased = total > 0 && released >= total;
    return {
      line1: total ? formatsText(row.hbtFormats) : 'No HBT yet',
      line2: allReleased ? '✓ Released' : `${released}/${total} released`,
      isOk: allReleased,
      progress: null,
    };
  }
  return { line1: stageInfo(row.stage).label, line2: '', isOk: false, progress: null };
}

// Tabs in order; page = null until the phase that builds it.
const BATCH_TABS = [
  { key: 'overview', label: 'Overview', page: 'batch-overview.html' },
  { key: 'brewing', label: 'Brewing', page: 'batch-brewing.html' },
  { key: 'fermentation', label: 'Fermentation log', page: 'batch-fermentation.html' },
  { key: 'processing', label: 'Processing', page: 'batch-processing.html' },
  { key: 'filling', label: 'Filling', page: null, phase: 6 },
  { key: 'filling-report', label: 'Filling report', page: null, phase: 7 },
];

/** Link to a batch tab, e.g. batchTabHref('overview', 12). */
function batchTabHref(tabKey, batchId) {
  const tab = BATCH_TABS.find((t) => t.key === tabKey);
  return tab && tab.page ? `${tab.page}?id=${batchId}` : null;
}

// The tab a batch opens on from a list: the tab of its current stage once
// that tab exists, else the Overview.
const STAGE_TABS = { brewing: 'brewing', fermentation: 'fermentation', lagering: 'fermentation', hbt: 'processing' };

// Package formats of an HBT (batch_hbts.intended_formats), in this order.
const PACKAGE_FORMATS = [
  { code: 'bottle', label: 'Bottle' },
  { code: 'can', label: 'Can' },
  { code: 'keg', label: 'Keg' },
];

/** 'Bottle + Keg' from ['keg', 'bottle']. */
function formatsText(formats) {
  const set = new Set(formats || []);
  return PACKAGE_FORMATS.filter((f) => set.has(f.code)).map((f) => f.label).join(' + ') || '—';
}
function batchHref(stage, batchId) {
  return batchTabHref(STAGE_TABS[stage], batchId) || batchTabHref('overview', batchId);
}

// Progress strip on the batch tabs: one step per process tab.
const PROGRESS_STEPS = [
  { key: 'brewing', label: 'Brewing', stages: ['brewing'] },
  { key: 'fermentation', label: 'Fermentation & lagering', stages: ['fermentation', 'lagering'] },
  { key: 'processing', label: 'Processing', stages: ['hbt'] },
  { key: 'filling', label: 'Filling', stages: ['filling'] },
  { key: 'filling-report', label: 'Filling report', stages: ['filled'] },
];

/** [{ key, label, state: 'done'|'now'|'todo' }] for the stage of a batch. */
function progressSteps(stage) {
  const current = stageOrder(stage);
  return PROGRESS_STEPS.map((step) => {
    const first = stageOrder(step.stages[0]);
    const last = stageOrder(step.stages[step.stages.length - 1]);
    const state = current > last ? 'done' : current >= first ? 'now' : 'todo';
    return { key: step.key, label: step.label, state };
  });
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    BATCH_TABS, batchTabHref, batchHref, PACKAGE_FORMATS, formatsText,
    BATCH_STAGES, ACTIVE_SECTIONS,
    stageInfo, stageOrder, batchYear, tankNumber, versionText, toBatchRow,
    filterBatches, sortBatches, compareByTank, groupActiveBatches, dayMonth, tileLines,
    PROGRESS_STEPS, progressSteps,
  };
}
