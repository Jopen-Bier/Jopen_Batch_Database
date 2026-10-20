// ============================================================================
// filling-report.js — calculations of the Filling report tab: litres per
// booked article, expected material use from the bill of materials (and the
// loss), per session and over the batch, the volume balance from GLT to
// package and the pie chart of where the GLT volume went. Rules:
// docs/batch-report/business-rules.md ("Volume balance", "Filling report");
// formula as mockup FillingReport.dc.html. Test: tests/filling-report.test.js.
//
// Browser: <script src="filling-report.js">. Node: require('../filling-report.js').
// ============================================================================

// Remainder / loss within this share counts as normal (green).
const FILLING_LOSS_OK_SHARE = 0.03;

const PIE_PARTS = [
  { key: 'bottle', label: 'Bottle', color: '#1c2b26' },
  { key: 'can', label: 'Can', color: '#4c6b4f' },
  { key: 'keg', label: 'Keg', color: '#b5c7a8' },
  { key: 'splits', label: 'Splits', color: '#b4772c' },
  { key: 'cellarLoss', label: 'Cellar loss', color: '#d9a07a' },
  { key: 'remainder', label: 'Filling remainder / loss', color: '#ece8dc' },
];

function reportNumber(value) {
  if (value === null || value === undefined || value === '') return null;
  const n = Number(String(value).replace(',', '.'));
  return Number.isFinite(n) ? n : null;
}

/** BOM rows -> Map(article_id -> [{ material_id, quantity }]). */
function bomByArticle(bomRows) {
  const map = new Map();
  (bomRows || []).forEach((r) => {
    if (!map.has(r.article_id)) map.set(r.article_id, []);
    map.get(r.article_id).push({ material_id: r.material_id, quantity: reportNumber(r.quantity) || 0 });
  });
  return map;
}

/**
 * Book in / book out of one filling session (or of all sessions together).
 * articleRows / materialRows: filling_session_articles / _materials rows;
 * articles: Map(id -> packaging_articles row); bom: bomByArticle().
 * Returns { articles: [{ row, article, count, litres }], litres,
 * litresByFormat: { bottle, can, keg }, materials: [{ material_id, row,
 * used, expected, loss }] }. Materials: the expected ones (from the BOM of
 * the booked articles) first, in booking order, then the other booked ones;
 * loss = used − expected (null while "used" is empty).
 */
function sessionBook(articleRows, materialRows, articles, bom) {
  const litresByFormat = { bottle: 0, can: 0, keg: 0 };
  const expected = new Map();
  let litres = 0;
  const booked = (articleRows || []).map((row) => {
    const article = articles.get(row.article_id) || null;
    const count = reportNumber(row.quantity) || 0;
    const l = article ? count * (reportNumber(article.liters_per_unit) || 0) : 0;
    litres += l;
    if (article && litresByFormat[article.package_format] !== undefined) litresByFormat[article.package_format] += l;
    (bom.get(row.article_id) || []).forEach((b) => expected.set(b.material_id, (expected.get(b.material_id) || 0) + count * b.quantity));
    return { row, article, count, litres: l };
  });
  const rowsOf = new Map();   // material_id -> booked rows (one per session)
  (materialRows || []).forEach((r) => rowsOf.set(r.material_id, (rowsOf.get(r.material_id) || []).concat([r])));
  const ids = [...expected.keys()].concat([...rowsOf.keys()].filter((id) => !expected.has(id)));
  const materials = ids.map((id) => {
    const rows = rowsOf.get(id) || [];
    const values = rows.map((r) => reportNumber(r.quantity)).filter((q) => q !== null);
    const used = values.length ? values.reduce((s, q) => s + q, 0) : null;
    const ex = expected.get(id) || 0;
    return { material_id: id, row: rows[0] || null, used, expected: ex, loss: used === null ? null : used - ex };
  });
  return { articles: booked, litres, litresByFormat, materials };
}

/** 'ok' (0) | 'lost' (> 0, material lost) | 'short' (< 0, check the count) | '' (no value). */
function materialLossClass(loss) {
  if (loss === null || loss === undefined) return '';
  if (Math.abs(loss) < 1e-9) return 'ok';
  return loss > 0 ? 'lost' : 'short';
}

/** Filled litres against the session volume (hl): { diffL, ok } or null without a volume. */
function sessionDifference(filledL, sessionVolumeHl) {
  const vol = reportNumber(sessionVolumeHl);
  if (vol === null || vol <= 0) return null;
  const diffL = filledL - vol * 100;
  return { diffL, ok: Math.abs(diffL) / (vol * 100) <= FILLING_LOSS_OK_SHARE };
}

/**
 * Volume balance in hl (business-rules.md "Volume balance"):
 * GLT + in from splits − splits from GLT / LT − cellar loss = in HBT; in HBT − splits from HBT
 * − packaged = filling remainder / loss. transfers: batch_transfers rows;
 * hbtTankIds: tanks of the batch's HBTs (a transfer from one of those is
 * after processing). packagedHl: { bottle, can, keg } in hl.
 */
function volumeBalance({ gltHl, transfers = [], hbtTankIds = [], hbtEndTotalHl, packagedHl = {}, incomingHl = 0 }) {
  const hbt = new Set(hbtTankIds);
  const vol = (t) => reportNumber(t.volume_hl) || 0;
  const preTransfers = transfers.filter((t) => !hbt.has(t.from_tank_id));
  const postTransfers = transfers.filter((t) => hbt.has(t.from_tank_id));
  const splitsPreHl = preTransfers.reduce((s, t) => s + vol(t), 0);
  const splitsPostHl = postTransfers.reduce((s, t) => s + vol(t), 0);
  const incoming = reportNumber(incomingHl) || 0;
  const glt = reportNumber(gltHl) === null && incoming ? 0 : reportNumber(gltHl);
  const inHbtHl = reportNumber(hbtEndTotalHl) || 0;
  const startHl = glt === null ? null : glt + incoming;   // all beer the batch got
  const cellarLossHl = startHl === null ? null : startHl - splitsPreHl - inHbtHl;
  const pk = { bottle: packagedHl.bottle || 0, can: packagedHl.can || 0, keg: packagedHl.keg || 0 };
  const packaged = pk.bottle + pk.can + pk.keg;
  const availableHl = inHbtHl - splitsPostHl;
  const remainderHl = availableHl - packaged;
  const remainderShare = availableHl > 0 ? remainderHl / availableHl : null;
  return {
    gltHl: glt, incomingHl: incoming, startHl, splitsPreHl, splitsPostHl, preTransfers, postTransfers, cellarLossHl, inHbtHl,
    availableHl, packagedHl: pk, packagedTotalHl: packaged, remainderHl, remainderShare,
    cellarLossNegative: cellarLossHl !== null && cellarLossHl < -1e-9,
    remainderOk: remainderShare !== null && remainderShare <= FILLING_LOSS_OK_SHARE,
  };
}

/** Pie parts of a balance: [{ key, label, color, hl, share (of GLT + incoming, or null) }]. Negative parts count 0. */
function pieParts(balance) {
  const value = {
    bottle: balance.packagedHl.bottle, can: balance.packagedHl.can, keg: balance.packagedHl.keg,
    splits: balance.splitsPreHl + balance.splitsPostHl,
    cellarLoss: Math.max(0, balance.cellarLossHl || 0), remainder: Math.max(0, balance.remainderHl),
  };
  return PIE_PARTS.map((p) => ({ ...p, hl: value[p.key], share: balance.startHl ? value[p.key] / balance.startHl : null }));
}

/** SVG path per part with a value above 0 (circle with radius r around (c, c)), starting at 12 o'clock. */
function pieSlices(parts, r = 92, c = 100) {
  const total = parts.reduce((s, p) => s + Math.max(0, p.hl), 0);
  if (!total) return [];
  let a0 = -Math.PI / 2;
  const pt = (a) => `${(c + r * Math.cos(a)).toFixed(2)},${(c + r * Math.sin(a)).toFixed(2)}`;
  return parts.filter((p) => p.hl > 0).map((p) => {
    const a1 = a0 + p.hl / total * 2 * Math.PI;
    const d = a1 - a0 >= 2 * Math.PI - 1e-6
      ? `M${c - r},${c} a${r},${r} 0 1,0 ${2 * r},0 a${r},${r} 0 1,0 ${-2 * r},0`
      : `M${c},${c} L${pt(a0)} A${r},${r} 0 ${a1 - a0 > Math.PI ? 1 : 0} 1 ${pt(a1)} Z`;
    a0 = a1;
    return { key: p.key, color: p.color, d };
  });
}

/** Produced per article over all sessions: [{ article, count, litres }] in article order. */
function articleTotals(articleRows, articles) {
  const map = new Map();
  (articleRows || []).forEach((r) => {
    const a = articles.get(r.article_id);
    if (!a) return;
    const x = map.get(a.id) || { article: a, count: 0, litres: 0 };
    const n = reportNumber(r.quantity) || 0;
    x.count += n;
    x.litres += n * (reportNumber(a.liters_per_unit) || 0);
    map.set(a.id, x);
  });
  return [...map.values()].sort((x, y) => (x.article.sort_order || 0) - (y.article.sort_order || 0) || x.article.id - y.article.id);
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    FILLING_LOSS_OK_SHARE, PIE_PARTS, bomByArticle, sessionBook, materialLossClass, sessionDifference,
    volumeBalance, pieParts, pieSlices, articleTotals,
  };
}
