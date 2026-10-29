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

/**
 * CO2 spec of a target from recipe_specs (Recipe › Specifications): bottle,
 * can or keg, with its tolerance ('-' or text = 0). { spec, tol } or null.
 */
function co2Spec(specs, target) {
  const p = specs || {};
  const field = target === 'keg' || target === 'tank' ? 'co2_keg' : target === 'bottle' ? 'co2_bottle' : target === 'can' ? 'co2_can' : null;   // tank beer has the keg spec
  const spec = field ? procNumber(p[field]) : null;
  if (spec === null) return null;
  return { spec, tol: procNumber(p[field + '_tol']) || 0 };
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
 * E-mail of the Processing tab (wishlist #30): the content of the Excel
 * sheet "Verwerking" that used to be copied into the mail, in the app's look. Input is already
 * resolved to display values (null = empty):
 * { batchNumber, beerName, risk,
 *   specs: { turbidity, pu, puTol, o2Max, co2Bottle, co2BottleTol, co2Can, co2CanTol, co2Keg, co2KegTol },
 *   lagering: { startDate, days },
 *   sessions: [{ number, date, start, end, duration, operatorStart, operatorEnd, tank,
 *     outlet, discharges, interval, centrifugeIn: { time, o2, co2 }, centrifugeOut,
 *     startFlow, startTurbidity }],
 *   comments: [{ time, text, by }], tasting: { result, comment },
 *   hbts: [{ name, formats, readings: [{ hl, o2, co2, target, flow, turbidity, comment }],
 *     end: { hl, o2, co2 }, avgO2, avgPu, avgTurbidity, avgFlow }],
 *   totalEndHl, cellarLossHl, gltEmpty }.
 * Returns { subject, text, html }: text for the mailto body, html (in the
 * look of the batch report pages) to paste into the message.
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
    `  CO2 bottle ${v(sp.co2Bottle, 'g/l')} ${tol(sp.co2BottleTol)} · CO2 can ${v(sp.co2Can, 'g/l')} ${tol(sp.co2CanTol)} · CO2 keg ${v(sp.co2Keg, 'g/l')} ${tol(sp.co2KegTol)}`, '',
    'LAGERING', `  Start ${v(lg.startDate)} · ${v(lg.days, 'days')}`];
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

  // ---- html: the look of the batch report pages (batch-report.css colours).
  // Outlook renders mail with Word: only tables, fixed widths, bgcolor and
  // td styles survive, so the cards are tables, not styled divs.
  const C = { ink: '#1c2b26', paper: '#f6f4ee', line: '#e2ddd0', muted: '#6b6355', hop: '#33473a', alert: '#a3492f' };
  const W = 700;                                    // card width in px
  const FONT = `font-family:Arial,Helvetica,sans-serif;font-size:13px;color:${C.ink};`;
  const cell = (x, style = '') => `<td style="${FONT}${style}">${x}</td>`;
  const table = (width, rows, extra = '') => `<table role="presentation" width="${width}" cellpadding="0" cellspacing="0" border="0" style="width:${width}px;border-collapse:collapse;${extra}">${rows}</table>`;
  const card = (title, inner) => table(W, `<tr><td bgcolor="#ffffff" style="${FONT}background:#ffffff;border:1px solid ${C.line};padding:12px 14px;">
      <p style="margin:0 0 8px;${FONT}font-size:11px;font-weight:bold;letter-spacing:1px;text-transform:uppercase;color:${C.muted};">${esc(title)}</p>${inner}</td></tr>`)
    + table(W, `<tr><td height="12" style="font-size:1px;line-height:12px;">&nbsp;</td></tr>`);
  const kv = (pairs, width) => table(width, pairs.map(([k, x]) => `<tr>${cell(esc(k), `color:${C.muted};padding:3px 12px 3px 0;width:${Math.round(width * 0.55)}px;`)}${cell(esc(v(x)), 'font-weight:bold;padding:3px 0;')}</tr>`).join(''));
  const twoCols = (left, right) => table(W - 30, `<tr><td valign="top" width="${(W - 30) / 2}" style="width:${(W - 30) / 2}px;">${left}</td><td valign="top" width="${(W - 30) / 2}" style="width:${(W - 30) / 2}px;">${right}</td></tr>`);
  const grid = (head, rows) => table(W - 30, `<tr>${head.map(([h, r]) => cell(esc(h), `font-size:11px;font-weight:bold;color:${C.muted};text-align:${r ? 'right' : 'left'};padding:4px 8px;border-bottom:1px solid ${C.line};`)).join('')}</tr>
${rows.join('\n')}`, 'margin-top:6px;');
  const td = (x, r) => cell(esc(v(x)), `text-align:${r ? 'right' : 'left'};padding:4px 8px;border-bottom:1px solid ${C.line};`);
  const half = (W - 30) / 2;
  const co2 = (spec, t) => (spec === null || spec === undefined || spec === '' ? null : `${spec} g/l ${tol(t)}`.trim());
  const goColor = tasting.result === 'go' ? C.hop : tasting.result === 'no_go' ? C.alert : C.muted;
  const body = [
    table(W, `<tr>${cell(`<span style="font-size:20px;font-weight:bold;">Processing · ${esc(d.batchNumber)} · ${esc(d.beerName || '')}</span><br>
      <span style="color:${C.muted};">Beer risk category: <b style="color:${C.ink};">${esc(v(d.risk))}</b></span>`, 'padding:0 0 12px;')}</tr>`),
    card('Specifications', twoCols(
      kv([['Turbidity after centrifuge', sp.turbidity == null ? null : `≤ ${sp.turbidity} EBC`], ['Pasteurisation', sp.pu == null ? null : `${sp.pu} PU ${tol(sp.puTol)}`.trim()], ['O2 in HBT', `< ${sp.o2Max} ppb`]], half),
      kv([['CO2 bottle', co2(sp.co2Bottle, sp.co2BottleTol)], ['CO2 can', co2(sp.co2Can, sp.co2CanTol)], ['CO2 keg', co2(sp.co2Keg, sp.co2KegTol)]], half))),
    card('Lagering', kv([['Start date lagering', lg.startDate], ['Days on lagering', lg.days]], half)),
    ...sessions.map((s) => card(`Processing session ${s.number}`, twoCols(
      kv([['Date', s.date], ['Start – end', `${v(s.start)} – ${v(s.end)}`], ['Duration', s.duration], ['Operators', `${v(s.operatorStart)} / ${v(s.operatorEnd)}`]], half),
      kv([['Processed from (G)LT', s.tank], ['Outlet', s.outlet], ['Discharges', s.discharges == null ? null : `${s.discharges} · every ${v(s.interval, 'min')}`]], half))
      + grid([['Measurement'], ['Time'], ['O2 (ppb)', 1], ['CO2 (g/l)', 1], ['Flow (hl/h)', 1], ['Turbidity (EBC)', 1]], [
        `<tr>${td('Centrifuge in')}${td(s.centrifugeIn.time)}${td(s.centrifugeIn.o2, 1)}${td(s.centrifugeIn.co2, 1)}${td(null, 1)}${td(null, 1)}</tr>`,
        `<tr>${td('Centrifuge out')}${td(s.centrifugeOut.time)}${td(s.centrifugeOut.o2, 1)}${td(s.centrifugeOut.co2, 1)}${td(s.startFlow, 1)}${td(s.startTurbidity, 1)}</tr>`]))),
    card('Comments & tasting', (comments.length ? grid([['Time'], ['Comment'], ['By']], comments.map((c) => `<tr>${td(c.time)}${td(c.text)}${td(c.by)}</tr>`))
      : `<p style="margin:0;${FONT}color:${C.muted};">No processing comments.</p>`)
      + `<p style="margin:8px 0 0;${FONT}">Tasting: <b style="color:${goColor};">${esc(result)}</b>${tasting.comment ? ` · ${esc(tasting.comment)}` : ''}</p>`),
    card('Bright beer tanks (HBT)', hbts.length ? hbts.map((h) => `<p style="margin:8px 0 2px;${FONT}font-weight:bold;">${esc(h.name)}${h.formats ? ` <span style="font-weight:normal;color:${C.muted};">· ${esc(h.formats)}</span>` : ''}</p>`
      + grid([['HL', 1], ['O2 (ppb)', 1], ['CO2 (g/l)', 1], ['Target'], ['Flow (hl/h)', 1], ['Turbidity (EBC)', 1], ['Comments']],
        (h.readings || []).map((r) => `<tr>${td(r.hl, 1)}${td(r.o2, 1)}${td(r.co2, 1)}${td(r.target)}${td(r.flow, 1)}${td(r.turbidity, 1)}${td(r.comment)}</tr>`))).join('')
      : `<p style="margin:0;${FONT}color:${C.muted};">No HBT readings yet.</p>`),
    card('Total measured volumes', (hbts.length ? grid([['HBT'], ['HL', 1], ['O2 (ppb)', 1], ['CO2 (g/l)', 1], ['Avg. in-line O2', 1], ['Avg. PU', 1], ['Avg. turbidity', 1], ['Avg. flow', 1]],
        hbts.map((h) => `<tr>${td(h.name)}${td(h.end.hl, 1)}${td(h.end.o2, 1)}${td(h.end.co2, 1)}${td(h.avgO2, 1)}${td(h.avgPu, 1)}${td(h.avgTurbidity, 1)}${td(h.avgFlow, 1)}</tr>`)) : '')
      + `<p style="margin:10px 0 0;font-size:1px;">&nbsp;</p>`
      + kv([['Total end volume', d.totalEndHl == null ? null : `${d.totalEndHl} hl`], ['Cellar loss', d.cellarLossHl == null ? null : `${d.cellarLossHl} hl`], ['GLT empty?', yn(d.gltEmpty)]], half)),
  ].join('\n');
  const html = table(W + 28, `<tr><td bgcolor="${C.paper}" style="background:${C.paper};padding:14px;">${body}</td></tr>`);
  return { subject, text: t.join('\n'), html };
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    processingSummary,
    O2_HBT_MAX_PPB, durationMinutes, durationText, hbtEnd, hbtFilledOn,
    co2Spec, co2Status, o2High, turbidityHigh, puOutOfSpec, maturation, cellarLoss,
  };
}
