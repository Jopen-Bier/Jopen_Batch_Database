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
 * Cellar plan progress. The n-th log entry (by measured_at) with tag T ticks
 * off the n-th plan step (by sort_order) with tag T. Returns the steps with
 * { step, doneBy: entry | null, isNext } and the done / total counts.
 * entryTags: [{ entry_id, tag_id }].
 */
function planProgress(steps, entries, entryTags) {
  const byId = new Map(entries.map((e) => [e.id, e]));
  const occurrences = new Map();   // tag_id -> entries, oldest first
  entryTags.forEach((t) => {
    const e = byId.get(t.entry_id);
    if (!e) return;
    if (!occurrences.has(t.tag_id)) occurrences.set(t.tag_id, []);
    occurrences.get(t.tag_id).push(e);
  });
  occurrences.forEach((list, k) => occurrences.set(k, sortLogEntries(list)));
  const used = new Map();
  let nextMarked = false, done = 0;
  const rows = steps.slice().sort((a, b) => a.sort_order - b.sort_order || a.id - b.id).map((step) => {
    const n = used.get(step.tag_id) || 0;
    used.set(step.tag_id, n + 1);
    const doneBy = (occurrences.get(step.tag_id) || [])[n] || null;
    if (doneBy) { done += 1; return { step, doneBy, isNext: false }; }
    const isNext = !nextMarked;
    nextMarked = true;
    return { step, doneBy: null, isNext };
  });
  return { rows, done, total: steps.length };
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
    effectiveTimeZero, daysSince, localDate, logLines, planProgress, attenuation, stepWhen,
    nagardoDose, alginateDose,
  };
}
