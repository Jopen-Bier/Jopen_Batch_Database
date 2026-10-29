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
 * E-mail of the Processing tab (wishlist #30): the same blocks as the Excel
 * sheet "Verwerking" that used to be copied into the mail. Input is already
 * resolved to display values (null = empty):
 * { batchNumber, beerName, risk,
 *   specs: { turbidity, pu, puTol, o2Max, co2Bottle, co2BottleTol, co2Keg, co2KegTol },
 *   lagering: { ogGlt, startDate, days },
 *   sessions: [{ number, date, start, end, duration, operatorStart, operatorEnd, tank,
 *     outlet, discharges, interval, centrifugeIn: { time, o2, co2 }, centrifugeOut,
 *     startFlow, startTurbidity }],
 *   comments: [{ time, text, by }], tasting: { result, comment },
 *   hbts: [{ name, formats, readings: [{ hl, o2, co2, target, flow, turbidity, comment }],
 *     end: { hl, o2, co2 }, avgO2, avgPu, avgTurbidity, avgFlow }],
 *   totalEndHl, cellarLossHl, gltEmpty }.
 * Returns { subject, text, html }: text for the mailto body, html (tables,
 * Excel look) to paste into the message.
 */
function processingSummary(d) {
  const v = (x, unit) => (x === null || x === undefined || x === '' ? '—' : `${x}${unit ? ' ' + unit : ''}`);
  const esc = (x) => String(x ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  const yn = (x) => (x === true ? 'Yes' : x === false ? 'No' : '—');
  const tol = (x) => (x === null || x === undefined || x === '' ? '' : `±${x}`);
  const subject = `Processing ${d.batchNumber} ${d.beerName || ''}`.trim();
  const sp = d.specs || {}, lg = d.lagering || {}, tasting = d.tasting || {};
  const result = tasting.result === 'go' ? 'Go' : tasting.result === 'no_go' ? 'Not go' : '—';
  const sessions = d.sessions || [], hbts = d.hbts || [], comments = d.comments || [];

  // ---- plain text (mailto body)
  const t = [subject, `Beer: ${v(d.beerName)} · Batch: ${v(d.batchNumber)} · Risk: ${v(d.risk)}`, '',
    'SPECIFICATIONS',
    `  Turbidity after centrifuge ≤ ${v(sp.turbidity, 'EBC')} · Pasteurisation ${v(sp.pu, 'PU')} ${tol(sp.puTol)} · O2 in HBT < ${v(sp.o2Max, 'ppb')}`,
    `  CO2 bottle/can ${v(sp.co2Bottle, 'g/l')} ${tol(sp.co2BottleTol)} · CO2 keg ${v(sp.co2Keg, 'g/l')} ${tol(sp.co2KegTol)}`, '',
    'LAGERING', `  O.G. GLT ${v(lg.ogGlt, '°P')} · Start ${v(lg.startDate)} · ${v(lg.days, 'days')}`];
  sessions.forEach((s) => {
    t.push('', `PROCESSING · SESSION ${s.number}`,
      `  ${v(s.date)} · ${v(s.start)}–${v(s.end)} (${v(s.duration)}) · operator start ${v(s.operatorStart)}, end ${v(s.operatorEnd)}`,
      `  From ${v(s.tank)} (${v(s.outlet)}) · discharges ${v(s.discharges)} every ${v(s.interval, 'min')}`,
      `  Centrifuge in ${v(s.centrifugeIn.time)}: O2 ${v(s.centrifugeIn.o2, 'ppb')}, CO2 ${v(s.centrifugeIn.co2, 'g/l')}`,
      `  Centrifuge out ${v(s.centrifugeOut.time)}: O2 ${v(s.centrifugeOut.o2, 'ppb')}, CO2 ${v(s.centrifugeOut.co2, 'g/l')} · flow ${v(s.startFlow, 'hl/h')} · turbidity ${v(s.startTurbidity, 'EBC')}`);
  });
  if (comments.length) { t.push('', 'COMMENTS PROCESSING'); comments.forEach((c) => t.push(`  ${c.time ? c.time + ' ' : ''}${c.text}${c.by ? ' (' + c.by + ')' : ''}`)); }
  t.push('', `TASTING: ${result}${tasting.comment ? ' · ' + tasting.comment : ''}`);
  if (hbts.length) t.push('', 'BRIGHT BEER TANKS (HBT)');
  hbts.forEach((h) => (h.readings || []).forEach((r) => t.push(`  ${h.name}: ${v(r.hl, 'hl')} · ${v(r.o2, 'ppb')} · ${v(r.co2, 'g/l')} · ${v(r.target)}${r.flow != null || r.turbidity != null ? ` · ${v(r.flow, 'hl/h')} · ${v(r.turbidity, 'EBC')}` : ''}${r.comment ? ' · ' + r.comment : ''}`)));
  if (hbts.length) {
    t.push('', 'TOTAL MEASURED VOLUMES');
    hbts.forEach((h) => t.push(`  End value ${h.name}: ${v(h.end.hl, 'hl')} · O2 ${v(h.end.o2, 'ppb')} · CO2 ${v(h.end.co2, 'g/l')}`));
  }
  t.push(`  Total end volume ${v(d.totalEndHl, 'hl')} · cellar loss ${v(d.cellarLossHl, 'hl')} · GLT empty? ${yn(d.gltEmpty)}`);

  // ---- html: Excel look (red title, grey section bars, yellow value cells)
  const F = 'font-family:Calibri,Arial,sans-serif;font-size:13px;';
  const B = 'border:1px solid #9a9a9a;padding:3px 6px;';
  const lab = (x, extra = '') => `<td style="${B}${extra}">${esc(x)}</td>`;
  const val = (x, extra = '') => `<td style="${B}background:#fff59d;text-align:center;${extra}">${esc(x === null || x === undefined || x === '' ? '' : x)}</td>`;
  const bar = (x, cols) => `<tr><td colspan="${cols}" style="${B}background:#d0d0d0;font-weight:bold;text-align:center;font-size:14px;">${esc(x)}</td></tr>`;
  const table = (rows) => `<table style="border-collapse:collapse;${F}width:680px;margin:0;">${rows}</table>`;
  const html = [`<div style="${F}">`,
    table(`<tr><td colspan="6" style="${B}background:#c00000;color:#fff;font-size:22px;text-align:center;">Processing</td></tr>
      <tr>${lab('Beer name')}${val(d.beerName, 'font-weight:bold;font-size:16px;')}${lab('Batch number')}${val(d.batchNumber)}${lab('Beer risk category')}${val(d.risk, 'font-weight:bold;')}</tr>`),
    table(`${bar('Specifications', 8)}
      <tr>${lab('Parameter', 'font-weight:bold;')}${lab('unit')}${lab('spec')}${lab('+/-')}${lab('Parameter', 'font-weight:bold;')}${lab('unit')}${lab('spec')}${lab('+/-')}</tr>
      <tr>${lab('Turbidity after centrifuge')}${lab('EBC')}${val(sp.turbidity)}${lab('≤')}${lab('CO2 spec HBT bottle / can')}${lab('g/l')}${val(sp.co2Bottle)}${lab(v(sp.co2BottleTol))}</tr>
      <tr>${lab('Pasteurisation')}${lab('PU')}${val(sp.pu)}${lab(v(sp.puTol))}${lab('CO2 spec HBT keg')}${lab('g/l')}${val(sp.co2Keg)}${lab(v(sp.co2KegTol))}</tr>
      <tr>${lab('O2 in HBT')}${lab('ppb')}${val(sp.o2Max)}${lab('<')}<td colspan="4" style="${B}"></td></tr>`),
    table(`${bar('Lagering', 6)}
      <tr>${lab('O.G. GLT')}${val(lg.ogGlt)}${lab('Start date lagering')}${val(lg.startDate)}${lab('Days on lagering')}${val(lg.days)}</tr>`),
    ...sessions.map((s) => table(`${bar(`Processing${sessions.length > 1 ? ' · session ' + s.number : ''}`, 6)}
      <tr>${lab('Name operator start')}${val(s.operatorStart)}${lab('Start of processing')}${val(s.start)}${lab('Date of processing')}${val(s.date)}</tr>
      <tr>${lab('Name operator end')}${val(s.operatorEnd)}${lab('End of processing')}${val(s.end)}${lab('Duration')}${val(s.duration)}</tr>
      <tr>${lab('Processed from (G)LT')}${val(s.tank)}${lab('Outlet')}${val(s.outlet)}${lab('Discharges · every (min)')}${val(`${v(s.discharges)} · ${v(s.interval)}`)}</tr>
      <tr>${lab('')}${lab('Time', 'font-weight:bold;')}${lab('O2 (ppb)', 'font-weight:bold;')}${lab('CO2 (g/l)', 'font-weight:bold;')}${lab('Flow (hl/h)', 'font-weight:bold;')}${lab('Turbidity (EBC)', 'font-weight:bold;')}</tr>
      <tr>${lab('Centrifuge in')}${val(s.centrifugeIn.time)}${val(s.centrifugeIn.o2)}${val(s.centrifugeIn.co2)}${lab('')}${lab('')}</tr>
      <tr>${lab('Centrifuge start out')}${val(s.centrifugeOut.time)}${val(s.centrifugeOut.o2)}${val(s.centrifugeOut.co2)}${val(s.startFlow)}${val(s.startTurbidity)}</tr>`)),
    table(`<tr>${lab('Time', 'font-weight:bold;width:70px;')}<td colspan="3" style="${B}font-weight:bold;text-align:center;">Comments processing</td></tr>
      ${(comments.length ? comments : [{}]).map((c) => `<tr>${val(c.time)}<td colspan="3" style="${B}background:#fff59d;">${c.text ? esc(c.text + (c.by ? ' (' + c.by + ')' : '')) : '&nbsp;'}</td></tr>`).join('')}
      <tr>${lab('Comments tasting')}<td style="${B}">${esc(tasting.comment || '')}</td>${lab('Go or Not go?', 'width:90px;')}${val(result, 'font-weight:bold;width:70px;')}</tr>`),
    table(`${bar('Bright beer tanks (HBT)', 9)}
      <tr>${['HBT', 'HL', 'O2 (ppb)', 'CO2 (g/l)', 'Target', 'Flow (hl/h)', 'Turbidity (EBC)', 'Comments'].map((x, i) => lab(x, `font-weight:bold;${i === 7 ? '' : ''}`)).join('')}</tr>
      ${hbts.flatMap((h) => (h.readings || []).map((r) => `<tr>${lab(h.name)}${val(r.hl)}${val(r.o2)}${val(r.co2)}${val(r.target)}${val(r.flow)}${val(r.turbidity)}${lab(r.comment || '')}</tr>`)).join('')
        || `<tr><td colspan="8" style="${B}">No HBT readings yet.</td></tr>`}`),
    table(`${bar('Total measured volumes', 9)}
      <tr>${['', 'HL', 'O2 (ppb)', 'CO2 (g/l)', 'Avg. in-line O2', 'Avg. PU', 'Avg. turbidity', 'Avg. flow'].map((x) => lab(x, 'font-weight:bold;')).join('')}</tr>
      ${hbts.map((h) => `<tr>${lab(`End value ${h.name}`)}${val(h.end.hl)}${val(h.end.o2)}${val(h.end.co2)}${val(h.avgO2)}${val(h.avgPu)}${val(h.avgTurbidity)}${val(h.avgFlow)}</tr>`).join('')}
      <tr>${lab('Total end volume (hl)', 'font-weight:bold;font-size:15px;')}${val(d.totalEndHl, 'font-weight:bold;font-size:15px;')}${lab('Cellar loss (hl)')}${val(d.cellarLossHl)}<td colspan="2" style="${B}"></td>${lab('GLT empty?')}${val(yn(d.gltEmpty))}</tr>`),
    '</div>'].join('\n');
  return { subject, text: t.join('\n'), html };
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    processingSummary,
    O2_HBT_MAX_PPB, durationMinutes, durationText, hbtEnd, hbtFilledOn,
    co2Spec, co2Status, o2High, turbidityHigh, puOutOfSpec, maturation, cellarLoss,
  };
}
