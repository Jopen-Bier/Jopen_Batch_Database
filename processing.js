// ============================================================================
// processing.js — calculations of the Processing tab: session duration, HBT
// end value, CO2 / O2 / turbidity / PU status, minimum maturation and the
// cellar loss. Rules: docs/batch-report/business-rules.md ("Processing /
// HBT"); test: tests/processing.test.js.
//
// Browser: <script src="processing.js">. Node: require('../processing.js').
// Package formats (PACKAGE_FORMATS, formatsText) live in batch-stages.js.
// ============================================================================

const O2_HBT_MAX_PPB = 50;            // O2 in HBT: red from 50 ppb (business-rules.md)

function procNumber(value) {
  if (value === null || value === undefined || value === '') return null;
  const n = Number(String(value).replace(',', '.'));
  return Number.isFinite(n) ? n : null;
}

function minutesOfDay(time) {
  const m = /^(\d{1,2}):(\d{2})/.exec(String(time || ''));
  return m ? Number(m[1]) * 60 + Number(m[2]) : null;
}

/** Minutes from start to end time; an end before the start runs past midnight. */
function durationMinutes(start, end) {
  const a = minutesOfDay(start), b = minutesOfDay(end);
  if (a === null || b === null) return null;
  return b >= a ? b - a : b + 1440 - a;
}

/** 140 -> '2h 20m'. */
function durationText(minutes) {
  if (minutes === null || minutes === undefined) return '—';
  return `${Math.floor(minutes / 60)}h ${String(minutes % 60).padStart(2, '0')}m`;
}

/**
 * End value of an HBT = its last reading (by sort_order) that has a level; a
 * row that is still being filled in does not count yet.
 */
function hbtEnd(readings) {
  const sorted = readings.filter((r) => procNumber(r.level_hl) !== null)
    .sort((a, b) => a.sort_order - b.sort_order || a.id - b.id);
  return sorted[sorted.length - 1] || null;
}

/** CO2 spec of a target from recipe_packaging: { spec, tol } or null. */
function co2Spec(packaging, target) {
  const p = packaging || {};
  const kegLike = target === 'keg' || target === 'tank';   // tank beer has the keg spec
  const spec = kegLike ? procNumber(p.co2_keg_spec) : target === 'bottle' || target === 'can' ? procNumber(p.co2_bottle_can_spec) : null;
  if (spec === null) return null;
  const tol = procNumber(kegLike ? p.co2_keg_tolerance : p.co2_bottle_can_tolerance) || 0;
  return { spec, tol };
}

/** 'OK' | 'High' | 'Low' | null (no value or no spec). */
function co2Status(value, spec) {
  const v = procNumber(value);
  if (v === null || !spec) return null;
  if (Math.abs(v - spec.spec) <= spec.tol + 1e-9) return 'OK';
  return v > spec.spec ? 'High' : 'Low';
}

const o2High = (value) => procNumber(value) !== null && procNumber(value) >= O2_HBT_MAX_PPB;
/** Turbidity above the recipe's turbidity after separation. */
const turbidityHigh = (value, max) => procNumber(value) !== null && procNumber(max) !== null && procNumber(value) > procNumber(max);
/** PU outside pasteurisation ± tol. */
function puOutOfSpec(value, spec, tol) {
  const v = procNumber(value), s = procNumber(spec);
  if (v === null || s === null) return false;
  return Math.abs(v - s) > (procNumber(tol) || 0) + 1e-9;
}

/**
 * Minimum maturation: days since lagering started vs the recipe lagering
 * time. { days, required, ok } — ok null when either is unknown.
 */
function maturation(lageringStartedAt, lageringTimeDays, now = new Date()) {
  const required = procNumber(lageringTimeDays);
  const days = lageringStartedAt ? (new Date(now) - new Date(lageringStartedAt)) / 86400000 : null;
  return { days, required, ok: days === null || required === null ? null : days >= required };
}

/**
 * Cellar loss = volume into GLT + beer in from splits − splits from GLT / LT
 * − total HBT end volume. transfers: batch_transfers rows going out;
 * hbtTankIds: tank ids of the batch's HBTs (a transfer from one of those is
 * after processing, not a cellar split); incomingHl: batch_stages.incoming_volume_hl.
 */
function cellarLoss({ gltVolumeHl, transfers = [], hbtTankIds = [], hbtEndTotalHl, incomingHl = 0 }) {
  const hbt = new Set(hbtTankIds);
  const splitsHl = transfers.filter((t) => !hbt.has(t.from_tank_id)).reduce((s, t) => s + (procNumber(t.volume_hl) || 0), 0);
  const incoming = procNumber(incomingHl) || 0;
  const glt = procNumber(gltVolumeHl) === null && incoming ? 0 : procNumber(gltVolumeHl);
  if (glt === null) return { lossHl: null, splitsHl, negative: false };
  const lossHl = glt + incoming - splitsHl - (procNumber(hbtEndTotalHl) || 0);
  return { lossHl, splitsHl, negative: lossHl < -1e-9 };
}

/**
 * Day an HBT was filled ('YYYY-MM-DD'): the first processing date of the
 * sessions its readings belong to, else the day the HBT row was made.
 */
function hbtFilledOn(hbt, readings, sessions) {
  const ids = new Set(readings.filter((r) => r.batch_hbt_id === hbt.id).map((r) => r.processing_session_id).filter(Boolean));
  const dates = sessions.filter((s) => ids.has(s.id) && s.processing_date).map((s) => String(s.processing_date).slice(0, 10)).sort();
  return dates[0] || (hbt.created_at ? String(hbt.created_at).slice(0, 10) : null);
}

/**
 * E-mail summary of the Processing tab (wishlist #30), the replacement for
 * the copied Excel sheet. Input is already resolved to display values:
 * { batchNumber, beerName, sessions: [{ number, date, start, end, tank,
 *   operators, centrifugeIn: { time, o2, co2 }, centrifugeOut, startFlow,
 *   startTurbidity }], hbts: [{ name, formats, end: { hl, o2, co2 },
 *   readings: [{ hl, o2, co2, flow, turbidity }] }], tasting: { result,
 *   comment }, comments: [{ time, text, by }] }.
 * Returns { subject, text, html }; text is plain (mailto body), html is for
 * pasting into the message.
 */
function processingSummary(d) {
  const v = (x, unit) => (x === null || x === undefined || x === '' ? '—' : `${x}${unit ? ' ' + unit : ''}`);
  const esc = (s) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  const subject = `Processing ${d.batchNumber} ${d.beerName || ''}`.trim();
  const tasting = d.tasting || {};
  const result = tasting.result === 'go' ? 'Go' : tasting.result === 'no_go' ? 'Not go' : '—';
  const lines = [subject, ''];
  (d.sessions || []).forEach((s) => {
    lines.push(`Session ${s.number} · ${v(s.date)} · ${v(s.start)}–${v(s.end)} · from ${v(s.tank)} · ${v(s.operators)}`);
    lines.push(`  Centrifuge in ${v(s.centrifugeIn.time)}: O2 ${v(s.centrifugeIn.o2, 'ppb')}, CO2 ${v(s.centrifugeIn.co2, 'g/l')}`);
    lines.push(`  Centrifuge out ${v(s.centrifugeOut.time)}: O2 ${v(s.centrifugeOut.o2, 'ppb')}, CO2 ${v(s.centrifugeOut.co2, 'g/l')}`);
    lines.push(`  Start flow ${v(s.startFlow, 'hl/h')}, turbidity ${v(s.startTurbidity, 'EBC')}`);
  });
  if ((d.hbts || []).length) lines.push('', 'HBTs');
  (d.hbts || []).forEach((h) => {
    lines.push(`  ${h.name}${h.formats ? ' (' + h.formats + ')' : ''}: ${v(h.end.hl, 'hl')} · O2 ${v(h.end.o2, 'ppb')} · CO2 ${v(h.end.co2, 'g/l')}`);
  });
  lines.push('', `Tasting: ${result}${tasting.comment ? ' · ' + tasting.comment : ''}`);
  if ((d.comments || []).length) lines.push('', 'Comments');
  (d.comments || []).forEach((c) => lines.push(`  ${c.time ? c.time + ' ' : ''}${c.text}${c.by ? ' (' + c.by + ')' : ''}`));

  const th = 'style="text-align:left;padding:4px 8px;border-bottom:1px solid #999;background:#f1efe8;"';
  const td = 'style="padding:4px 8px;border-bottom:1px solid #ddd;"';
  const table = (head, rows) => `<table style="border-collapse:collapse;font-family:Arial,sans-serif;font-size:13px;margin:6px 0 14px;">
<tr>${head.map((h) => `<th ${th}>${esc(h)}</th>`).join('')}</tr>
${rows.map((r) => `<tr>${r.map((c) => `<td ${td}>${esc(c)}</td>`).join('')}</tr>`).join('\n')}</table>`;
  const html = [`<div style="font-family:Arial,sans-serif;font-size:13px;"><p style="font-size:15px;"><b>${esc(subject)}</b></p>`,
    (d.sessions || []).length ? table(['Session', 'Date', 'Start', 'End', 'From', 'Operators', 'Centr. in O2 / CO2', 'Centr. out O2 / CO2', 'Start flow', 'Start turbidity'],
      d.sessions.map((s) => [s.number, v(s.date), v(s.start), v(s.end), v(s.tank), v(s.operators),
        `${v(s.centrifugeIn.o2)} / ${v(s.centrifugeIn.co2)}`, `${v(s.centrifugeOut.o2)} / ${v(s.centrifugeOut.co2)}`, v(s.startFlow, 'hl/h'), v(s.startTurbidity, 'EBC')])) : '',
    ...(d.hbts || []).map((h) => `<p style="margin:10px 0 0;"><b>${esc(h.name)}</b>${h.formats ? ' · ' + esc(h.formats) : ''} · end ${esc(v(h.end.hl, 'hl'))}</p>`
      + table(['HL', 'O2 ppb', 'CO2 g/l', 'Flow hl/h', 'Turbidity EBC'], (h.readings || []).map((r) => [v(r.hl), v(r.o2), v(r.co2), v(r.flow), v(r.turbidity)]))),
    `<p><b>Tasting:</b> ${esc(result)}${tasting.comment ? ' · ' + esc(tasting.comment) : ''}</p>`,
    (d.comments || []).length ? `<p style="margin-bottom:2px;"><b>Comments</b></p><ul style="margin-top:0;">${d.comments.map((c) =>
      `<li>${c.time ? esc(c.time) + ' ' : ''}${esc(c.text)}${c.by ? ' (' + esc(c.by) + ')' : ''}</li>`).join('')}</ul>` : '',
    '</div>'].join('\n');
  return { subject, text: lines.join('\n'), html };
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    processingSummary,
    O2_HBT_MAX_PPB, durationMinutes, durationText, hbtEnd, hbtFilledOn,
    co2Spec, co2Status, o2High, turbidityHigh, puOutOfSpec, maturation, cellarLoss,
  };
}
