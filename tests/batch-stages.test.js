// node tests/batch-stages.test.js
const assert = require('assert');
const s = require('../batch-stages.js');

// Stage codes must match view batch_stages (business-rules.md, "Stage of a batch").
assert.deepStrictEqual(s.BATCH_STAGES.map((x) => x.code),
  ['raw', 'brewing', 'fermentation', 'lagering', 'hbt', 'filling', 'filled', 'closed']);
// every stage except closed appears in exactly one Active batches block
const inSections = s.ACTIVE_SECTIONS.flatMap((x) => x.stages);
assert.deepStrictEqual(inSections, ['raw', 'brewing', 'fermentation', 'lagering', 'hbt', 'filling', 'filled']);
assert.strictEqual(s.stageInfo('hbt').label, 'HBT');
assert.strictEqual(s.stageInfo('unknown').label, 'unknown');
assert.ok(s.stageOrder('closed') > s.stageOrder('raw'));

assert.strictEqual(s.batchYear('26346'), 2026);
assert.strictEqual(s.batchYear('25001'), 2025);
assert.strictEqual(s.batchYear('26-0412'), null);
assert.strictEqual(s.batchYear(null), null);

assert.strictEqual(s.tankNumber('GLT21'), 21);
assert.strictEqual(s.tankNumber('HBT 12'), 12);
assert.strictEqual(s.tankNumber(null), null);

assert.strictEqual(s.versionText(15, 3), 'v15.3');
assert.strictEqual(s.versionText(null, null), 'v1.0');
assert.strictEqual(s.dayMonth('2026-10-14'), '14-10');

// toBatchRow: name falls back to the recipe, stage defaults to raw
const row = (o) => s.toBatchRow(
  { id: o.id, batch_number: o.no, name: o.name, brew_count: o.brews ?? 1, order_picking_date: o.pick || null,
    order_picking_completed_at: o.picked ? '2026-10-19T08:00:00Z' : null,
    recipes: { name: 'Recipe ' + o.id, version_major: o.maj ?? 1, version_minor: o.min ?? 0, location: o.loc === undefined ? 'wp' : o.loc } },
  o.stage ? { stage: o.stage, start_date: o.start || null, end_date: null } : null);
const r1 = row({ id: 1, no: '26346' });
assert.strictEqual(r1.name, 'Recipe 1');
assert.strictEqual(r1.stage, 'raw');
assert.deepStrictEqual(r1.attention, []);

const rows = [
  row({ id: 1, no: '26346', name: 'Beppie Kraft 45', stage: 'raw', maj: 5 }),
  row({ id: 2, no: '26345', name: 'Sunny Day 40', stage: 'raw', maj: 17, min: 1, loc: 'jk' }),
  row({ id: 3, no: '26100', name: 'Mooie Nel', stage: 'closed', maj: 12 }),
  row({ id: 4, no: '25390', name: 'Koyt', stage: 'closed', loc: 'jk' }),
  row({ id: 5, no: '26351', name: 'Zwarte Ziel', stage: 'raw', loc: null }),
];

// All batches: filters
assert.strictEqual(s.filterBatches(rows).length, 5);
assert.deepStrictEqual(s.filterBatches(rows, { q: 'nel' }).map((r) => r.id), [3]);
assert.deepStrictEqual(s.filterBatches(rows, { q: '2634' }).map((r) => r.id), [1, 2]);
assert.deepStrictEqual(s.filterBatches(rows, { stage: 'closed' }).map((r) => r.id), [3, 4]);
assert.deepStrictEqual(s.filterBatches(rows, { year: 2025 }).map((r) => r.id), [4]);
assert.deepStrictEqual(s.filterBatches(rows, { location: 'jk' }).map((r) => r.id), [2, 4]);
assert.deepStrictEqual(s.filterBatches(rows, { location: 'wp', stage: 'raw' }).map((r) => r.id), [1]);

// All batches: sorting (default newest first)
assert.deepStrictEqual(s.sortBatches(rows).map((r) => r.batchNumber), ['26351', '26346', '26345', '26100', '25390']);
assert.deepStrictEqual(s.sortBatches(rows, 'batchNumber', 1).map((r) => r.batchNumber), ['25390', '26100', '26345', '26346', '26351']);
assert.deepStrictEqual(s.sortBatches(rows, 'name', 1).map((r) => r.id), [1, 4, 3, 2, 5]);
assert.deepStrictEqual(s.sortBatches(rows, 'version', -1).map((r) => r.id), [2, 3, 1, 5, 4]);
// stage ascending: raw before closed; ties newest batch first
assert.deepStrictEqual(s.sortBatches(rows, 'stage', 1).map((r) => r.id), [5, 1, 2, 3, 4]);

// Active batches: tank order, batches without a tank last, then batch number
const t = (no, tankCode) => ({ batchNumber: no, tankCode });
assert.deepStrictEqual([t('3', null), t('2', 'GLT41'), t('1', 'GLT21'), t('0', null)].sort(s.compareByTank).map((x) => x.batchNumber),
  ['1', '2', '0', '3']);

// Active batches: grouping
const g = s.groupActiveBatches(rows);
assert.strictEqual(g.total, 3);                        // closed left out
const raw = g.sections.find((x) => x.key === 'raw');
assert.deepStrictEqual(raw.groups[0].items.map((r) => r.batchNumber), ['26345', '26346', '26351']);
assert.strictEqual(raw.count, 3);
const cellar = g.sections.find((x) => x.key === 'cellar');
assert.deepStrictEqual(cellar.groups.map((x) => x.label), ['Fermentation', 'Lagering']);
assert.strictEqual(cellar.count, 0);
assert.strictEqual(g.summary.find((x) => x.stage === 'raw').count, 3);
assert.strictEqual(g.attentionTotal, 0);
// location filter also narrows the summary; search does not
const gj = s.groupActiveBatches(rows, { location: 'jk', q: 'nothing matches' });
assert.strictEqual(gj.total, 1);
assert.strictEqual(gj.summary.find((x) => x.stage === 'raw').count, 1);
assert.strictEqual(gj.sections[0].count, 0);
// attention only
const withIssue = rows.map((r) => (r.id === 1 ? { ...r, attention: ['Brew tomorrow · not picked'] } : r));
const ga = s.groupActiveBatches(withIssue, { attentionOnly: true });
assert.deepStrictEqual(ga.sections[0].groups[0].items.map((r) => r.id), [1]);
assert.strictEqual(ga.sections[0].attentionCount, 1);
assert.strictEqual(ga.attentionTotal, 1);

// Tile lines (raw)
assert.deepStrictEqual(s.tileLines(row({ id: 9, no: '26400', stage: 'raw', pick: '2026-10-14' })),
  { line1: 'Order picking 14-10', line2: 'Not picked yet', isOk: false, progress: null });
assert.strictEqual(s.tileLines(row({ id: 9, no: '26400', stage: 'raw' })).line1, 'No order picking date');
assert.deepStrictEqual(s.tileLines(row({ id: 9, no: '26400', stage: 'raw', picked: true })),
  { line1: 'No order picking date', line2: '✓ Picked', isOk: true, progress: null });

// Brewing and fermentation tiles (stage row from batch_stages, tank from batches.glt_tank_id)
const brewRow = (stage, extra) => s.toBatchRow(
  { id: 20, batch_number: '26420', name: 'Bokbier', brew_count: 3, glt_tank: { code: 'GLT41' }, recipes: { location: 'wp' } },
  Object.assign({ stage, brews_planned: 3, brews_started: 0, brews_ended: 0, last_brew_ended_at: null }, extra));
assert.strictEqual(brewRow('brewing').tankCode, 'GLT41');
assert.deepStrictEqual(s.tileLines(brewRow('brewing', { brews_started: 2, brews_ended: 1 })),
  { line1: 'Brew 1 / 3', line2: 'Brewing: brew 2', isOk: false, progress: 1 / 3 });
assert.strictEqual(s.tileLines(brewRow('brewing', { brews_started: 2, brews_ended: 2 })).line2, 'Next: brew 3');
// Cellar tiles: day since Time 0, plan tasks, next step
const cellarRow = (extra) => brewRow('fermentation', Object.assign({ brews_started: 3, brews_ended: 3, time_zero: '2026-10-21T12:00:00Z',
  cellar_steps_total: 5, cellar_steps_done: 1, next_cellar_step: 'Cooling to 16 °C' }, extra));
assert.deepStrictEqual(s.tileLines(cellarRow(), new Date('2026-10-25T16:48:00Z')),
  { line1: 'Day 4.2 · tasks 1/5', line2: 'Next: Cooling to 16 °C', isOk: false, progress: 0.2 });
assert.deepStrictEqual(s.tileLines(cellarRow({ stage: 'lagering', cellar_steps_done: 5, next_cellar_step: null }), new Date('2026-10-30T12:00:00Z')),
  { line1: 'Day 9.0 · tasks 5/5', line2: '✓ All tasks done', isOk: true, progress: 1 });
assert.strictEqual(s.tileLines(cellarRow({ time_zero: null, cellar_steps_total: 0, cellar_steps_done: 0, next_cellar_step: null })).line1, 'no cellar plan');
// the lager tank wins once set
assert.strictEqual(s.toBatchRow({ id: 1, batch_number: '1', glt_tank: { code: 'GLT7' }, lt_tank: { code: 'LT3' }, recipes: {} }, null).tankCode, 'LT3');
assert.strictEqual(s.toBatchRow({ id: 1, batch_number: '1', recipes: {} }, null).tankCode, null);

// Progress strip
const states = (stage) => s.progressSteps(stage).map((x) => x.state).join(' ');
assert.strictEqual(states('raw'), 'todo todo todo todo todo');
assert.strictEqual(states('brewing'), 'now todo todo todo todo');
assert.strictEqual(states('lagering'), 'done now todo todo todo');
assert.strictEqual(states('hbt'), 'done done now todo todo');
assert.strictEqual(states('filled'), 'done done done done now');
assert.strictEqual(states('closed'), 'done done done done done');

// A list opens a batch on the tab of its stage
assert.strictEqual(s.batchHref('fermentation', 7), 'batch-fermentation.html?id=7');
assert.strictEqual(s.batchHref('lagering', 7), 'batch-fermentation.html?id=7');
assert.strictEqual(s.batchHref('brewing', 7), 'batch-brewing.html?id=7');
assert.strictEqual(s.batchHref('raw', 7), 'batch-overview.html?id=7');
assert.strictEqual(s.batchHref('hbt', 7), 'batch-processing.html?id=7');
assert.strictEqual(s.batchHref('filling', 7), 'batch-filling.html?id=7');
assert.strictEqual(s.batchHref('filled', 7), 'batch-filling-report.html?id=7');
assert.strictEqual(s.batchHref('closed', 7), 'batch-overview.html?id=7');

// HBT name: the tank code, "(fill n)" when the batch uses the tank again
const fills = [{ id: 3, tank_id: 16, sort_order: 3 }, { id: 1, tank_id: 16, sort_order: 1 }, { id: 2, tank_id: 17, sort_order: 2 }];
const code = (id) => 'HBT' + id;
assert.deepStrictEqual(fills.map((h) => s.hbtLabel(h, fills, code)), ['HBT16 (fill 2)', 'HBT16 (fill 1)', 'HBT17']);
const day = { 1: '2026-10-01', 2: '2026-10-01', 3: '2026-10-14' };
assert.deepStrictEqual(fills.map((h) => s.hbtLabel(h, fills, code, (x) => day[x.id])), ['HBT16 · 14-10', 'HBT16 · 01-10', 'HBT17']);
const twice = [{ id: 1, tank_id: 16, sort_order: 1 }, { id: 2, tank_id: 16, sort_order: 2 }];
assert.deepStrictEqual(twice.map((h) => s.hbtLabel(h, twice, code, () => '2026-10-01')), ['HBT16 · 01-10 (1)', 'HBT16 · 01-10 (2)']);

// HBT tiles: formats, release, HBT as tank chip
assert.strictEqual(s.formatsText(['keg', 'bottle']), 'Bottle + Keg');
assert.strictEqual(s.formatsText([]), '—');
const hbtRow = (extra) => s.toBatchRow({ id: 30, batch_number: '26430', glt_tank: { code: 'GLT7' }, recipes: { location: 'wp' } },
  Object.assign({ stage: 'hbt', hbts_total: 2, hbts_released: 1, hbt_codes: 'HBT12 · HBT14', hbt_formats: ['bottle', 'can', 'keg'] }, extra));
assert.strictEqual(hbtRow().tankCode, 'HBT12 · HBT14');
assert.deepStrictEqual(s.tileLines(hbtRow()), { line1: 'Bottle + Can + Keg', line2: '1/2 released', isOk: false, progress: null });
assert.deepStrictEqual(s.tileLines(hbtRow({ hbts_released: 2 })), { line1: 'Bottle + Can + Keg', line2: '✓ Released', isOk: true, progress: null });
assert.strictEqual(s.tileLines(hbtRow({ hbts_total: 0, hbts_released: 0, hbt_codes: null })).line1, 'No HBT yet');
assert.strictEqual(hbtRow({ hbt_codes: null }).tankCode, 'GLT7');
// Filling and Filled tiles
assert.deepStrictEqual(s.tileLines(hbtRow({ stage: 'filling', hbts_finished: 1 })), { line1: 'Bottle + Can + Keg', line2: '1/2 HBT finished', isOk: false, progress: 0.5, line3: 'Documents 0/3', line3Ok: false });
assert.strictEqual(hbtRow({ stage: 'filling' }).tankCode, 'HBT12 · HBT14');
assert.deepStrictEqual(s.tileLines(hbtRow({ stage: 'filled', hbts_finished: 2, filled_volume_hl: 76.8, documents_uploaded: 2 })), { line1: '76.8 hl packaged', line2: 'Filling report open', isOk: false, progress: null, line3: 'Documents 2/3', line3Ok: false });
assert.deepStrictEqual(s.tileLines(hbtRow({ stage: 'filled', documents_uploaded: 3 })).line3, '✓ Documents 3/3');
assert.strictEqual(s.tileLines(hbtRow({ stage: 'hbt' })).line3, undefined, 'documents only on Filling / Filled tiles');

console.log('batch-stages: all tests passed');
