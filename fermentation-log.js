// ============================================================================
// fermentation-log.js — calculations of the Fermentation log tab: days since
// Time 0, log lines with gap days, cellar plan progress (ticked off by action
// tags), ADF / theoretical ABV, the "When" text of a plan step and the cellar
// calculators. Rules: docs/batch-report/business-rules.md ("Time 0 and days",
// "Cellar plan progress", "Calculators"); test: tests/fermentation-log.test.js.
//
// Browser: <script src="fermentation-log.js">. Node: require('../fermentation-log.js').
// ============================================================================

const DAY_MS = 86400000;

function logNumber(value) {
  if (value === null || value === undefined || value === '') return null;
  const n = Number(String(value).replace(',', '.'));
  return Number.isFinite(n) ? n : null;
}

/** Time 0 in use: the one set on the batch, else the end of the last brew. */
function effectiveTimeZero(batch, stageRow) {
  return (batch && batch.time_zero) || (stageRow && stageRow.last_brew_ended_at) || null;
}

/** Days since Time 0 as a number with 1 decimal, or null. */
function daysSince(at, timeZero) {
  if (!at || !timeZero) return null;
  const d = (new Date(at).getTime() - new Date(timeZero).getTime()) / DAY_MS;
  return Number.isFinite(d) ? Math.round(d * 10) / 10 : null;
}

/** 'YYYY-MM-DD' of a moment in local time. */
function localDate(at) {
  const d = new Date(at);
  const pad = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

function sortLogEntries(entries) {
  return entries.slice().sort((a, b) => new Date(a.measured_at) - new Date(b.measured_at) || a.id - b.id);
}

/**
 * Lines of the Measurements & actions table, oldest first:
 * { kind: 'entry', entry, days, decrease, hours } or, for every calendar day
 * without an entry between two entries, { kind: 'gap', date, days } (days at
 * 08:00 of that day, where a new measurement is put).
 */
function logLines(entries, timeZero) {
  const sorted = sortLogEntries(entries);
  const lines = [];
  let prev = null;
  sorted.forEach((e) => {
    if (prev) {
      const day = new Date(prev.measured_at);
      day.setHours(12, 0, 0, 0);
      const end = localDate(e.measured_at);
      for (day.setDate(day.getDate() + 1); localDate(day) < end; day.setDate(day.getDate() + 1)) {
        const at = new Date(day); at.setHours(8, 0, 0, 0);
        lines.push({ kind: 'gap', date: localDate(day), days: daysSince(at, timeZero) });
      }
    }
    const p = logNumber(e.extract), pp = prev ? logNumber(prev.extract) : null;
    lines.push({
      kind: 'entry',
      entry: e,
      days: daysSince(e.measured_at, timeZero),
      decrease: p !== null && pp !== null ? Math.round((pp - p) * 10) / 10 : null,
      hours: prev ? Math.round((new Date(e.measured_at) - new Date(prev.measured_at)) / 3600000) : null,
    });
    prev = e;
  });
  return lines;
}

/**
 * Cellar plan progress. A tag that names a step (batch_cellar_step_id) ticks
 * off that step; the n-th other tag with tag T (by measured_at) ticks off the
 * n-th step with tag T that no tag names. Returns the steps with
 * { step, doneBy: entry | null, isNext }, the done / total counts and
 * stepOfTag: Map(tag row id -> the step it ticks off).
 * entryTags: [{ id, entry_id, tag_id, batch_cellar_step_id }].
 */
function planProgress(steps, entries, entryTags) {
  const byId = new Map(entries.map((e) => [e.id, e]));
  const at = (t) => new Date(byId.get(t.entry_id).measured_at).getTime();
  const tags = entryTags.filter((t) => byId.has(t.entry_id))
    .sort((a, b) => at(a) - at(b) || a.entry_id - b.entry_id || (a.id || 0) - (b.id || 0));
  const ordered = steps.slice().sort((a, b) => a.sort_order - b.sort_order || a.id - b.id);
  const stepIds = new Set(ordered.map((s) => s.id));
  const doneBy = new Map(), stepOfTag = new Map();
  tags.filter((t) => t.batch_cellar_step_id && stepIds.has(t.batch_cellar_step_id)).forEach((t) => {
    if (!doneBy.has(t.batch_cellar_step_id)) doneBy.set(t.batch_cellar_step_id, byId.get(t.entry_id));
    stepOfTag.set(t.id, ordered.find((s) => s.id === t.batch_cellar_step_id));
  });
  const named = new Set(doneBy.keys());
  const free = new Map();   // tag_id -> tag rows without a (known) step, oldest first
  tags.filter((t) => !(t.batch_cellar_step_id && stepIds.has(t.batch_cellar_step_id))).forEach((t) => {
    if (!free.has(t.tag_id)) free.set(t.tag_id, []);
    free.get(t.tag_id).push(t);
  });
  const used = new Map();
  ordered.filter((s) => !named.has(s.id)).forEach((s) => {
    const n = used.get(s.tag_id) || 0;
    used.set(s.tag_id, n + 1);
    const t = (free.get(s.tag_id) || [])[n];
    if (t) { doneBy.set(s.id, byId.get(t.entry_id)); stepOfTag.set(t.id, s); }
  });
  let nextMarked = false, done = 0;
  const rows = ordered.map((step) => {
    const by = doneBy.get(step.id) || null;
    if (by) { done += 1; return { step, doneBy: by, isNext: false }; }
    const isNext = !nextMarked;
    nextMarked = true;
    return { step, doneBy: null, isNext };
  });
  return { rows, done, total: steps.length, stepOfTag };
}

/** Steps with this tag that no tag ticks off yet (to choose from when tagging). */
function openStepsForTag(steps, entries, entryTags, tagId) {
  const { rows } = planProgress(steps, entries, entryTags);
  return rows.filter((r) => !r.doneBy && r.step.tag_id === tagId).map((r) => r.step);
}

/** ADF % and theoretical ABV from the first and last extract in the log. */
function attenuation(entries) {
  const withExtract = sortLogEntries(entries).filter((e) => logNumber(e.extract) !== null);
  if (withExtract.length < 2) return { adf: null, abv: null };
  const og = logNumber(withExtract[0].extract);
  const last = logNumber(withExtract[withExtract.length - 1].extract);
  if (!og) return { adf: null, abv: null };
  return { adf: (og - last) / og * 100, abv: (og - last) * 0.533 };
}

const fmtNum = (v, digits = 1) => Number(v).toLocaleString('en-GB', { maximumFractionDigits: digits });
const dayMonthOf = (at) => { const d = localDate(at); return `${d.slice(8, 10)}-${d.slice(5, 7)}`; };

/** "When" text of a plan step: trigger plus the indicative day (and its date from Time 0). */
function stepWhen(step, previous, timeZero) {
  const day = logNumber(step.planned_day);
  const dateText = day !== null && timeZero ? ` (${dayMonthOf(new Date(new Date(timeZero).getTime() + day * DAY_MS))})` : '';
  const dayText = day === null ? '' : `day ${fmtNum(day)}${dateText}`;
  const value = logNumber(step.trigger_value), tol = logNumber(step.trigger_tol);
  const tolText = tol ? ` (±${fmtNum(tol, 2)})` : '';
  if (step.trigger_type === 'extract' && value !== null) return `at ${fmtNum(value, 2)} °P${tolText}${dayText ? ' · ~' + dayText : ''}`;
  if (step.trigger_type === 'temperature' && value !== null) return `at ${fmtNum(value, 2)} °C${tolText}${dayText ? ' · ~' + dayText : ''}`;
  if (step.trigger_type === 'day' && dayText) return `day ${fmtNum(day)} from Time 0${dateText}`;
  if (dayText) return `~${dayText}`;
  return previous ? `after ${previous.title.charAt(0).toLowerCase()}${previous.title.slice(1)}` : 'during fermentation';
}

/** Nagardo: weight g = volume l × ppm / 1000; water l = weight / 10 (1 % solution). */
function nagardoDose(volumeL, ppm) {
  const v = logNumber(volumeL), p = logNumber(ppm);
  if (v === null || p === null) return null;
  const weightG = v * p / 1000;
  return { weightG, waterL: weightG / 10 };
}

/** PGA / alginate: pre-solution l = rate l/hl × volume l / 100; alginate g = pre × 0.02 × 1000; hot water l = pre. */
function alginateDose(volumeL, rateLPerHl) {
  const v = logNumber(volumeL), r = logNumber(rateLPerHl);
  if (v === null || r === null) return null;
  const preL = r * v / 100;
  return { preL, alginateG: preL * 0.02 * 1000, waterL: preL };
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    effectiveTimeZero, daysSince, localDate, logLines, planProgress, openStepsForTag, attenuation, stepWhen,
    nagardoDose, alginateDose,
  };
}
