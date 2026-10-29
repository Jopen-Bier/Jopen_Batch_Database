// ============================================================================
// pallet-labels.js — printable pallet labels from the Filling page
// (wishlist #2), after the Excel sheets "1. Palletbrief - vaten" (keg) and
// "1. Palletbrief - fles en blik" (bottle / can).
//
// One label = one A4 sheet. A keg sheet has the label once; a bottle / can
// sheet has it twice side by side, so it can be folded round the corner of
// the pallet. Labels per pallet × pallets sheets, numbered 1..pallets.
// Batch code on the label: L<batch number>/<HBT tank number>.
//
// Browser: <script src="pallet-labels.js">. Node: require('../pallet-labels.js').
// Test: tests/pallet-labels.test.js.
// ============================================================================

const PALLET_LABEL_NOTE = 'Deze palletlabel op de rechterhoek van de smalle kant opplakken svp.';
const MONTHS = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'];

/** Pallet number of every sheet: 2 per pallet × 3 pallets → [1, 1, 2, 2, 3, 3]. [] on bad input. */
function palletLabelSequence(labelsPerPallet, pallets) {
  const per = Number(labelsPerPallet), n = Number(pallets);
  if (!Number.isInteger(per) || !Number.isInteger(n) || per < 1 || n < 1 || per * n > 500) return [];
  const seq = [];
  for (let p = 1; p <= n; p++) for (let i = 0; i < per; i++) seq.push(p);
  return seq;
}

/** 'L26295/18'; the HBT part is left out when the tank number is unknown. */
function palletBatchCode(batchNumber, hbtNumber) {
  const hbt = hbtNumber === null || hbtNumber === undefined || hbtNumber === '' ? '' : `/${hbtNumber}`;
  return `L${batchNumber}${hbt}`;
}

/** Best before as on the keg label: filling date ('YYYY-MM-DD') + months → 'OCT 2028'. */
function bestBeforeText(date, months) {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(date || ''));
  const add = Number(months);
  if (!m || !Number.isFinite(add) || add <= 0) return '';
  const total = Number(m[1]) * 12 + Number(m[2]) - 1 + Math.round(add);
  return `${MONTHS[total % 12]} ${Math.floor(total / 12)}`;
}

/** 'YYYY-MM-DD' → 'DD-MM-YYYY'. */
function labelDate(date) {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(date || ''));
  return m ? `${m[3]}-${m[2]}-${m[1]}` : '';
}

function labelEscape(s) {
  return String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

/**
 * Full print document. opts = { kind: 'keg' | 'pack', beerName, code,
 * date ('YYYY-MM-DD'), bestBefore (keg), orderNumber (pack, optional),
 * sequence (palletLabelSequence) }.
 */
function palletLabelsHtml(opts) {
  const e = labelEscape;
  const keg = opts.kind === 'keg';
  // Each label is laid out landscape (as read on the pallet) and turned a
  // quarter on the portrait A4, like the rotated text in the Excel sheets.
  const kegLabel = (n) => `<div class="lbl keg">
      <div class="row top"><div class="box"><span>palletnr.</span><b>${n}</b></div></div>
      <div class="fit code">${e(opts.code)}</div>
      <div class="fit beer">${e(opts.beerName)}</div>
      <div class="row bottom"><div class="bb"><span>Best Before</span><b>${e(opts.bestBefore || '')}</b></div>
        <div class="box amount"><span>Aantal / Amount</span></div></div>
    </div>`;
  const packLabel = (n) => `<div class="lbl pack">
      <div class="fit beer">${e(opts.beerName)}</div>
      <div class="fit code">${e(opts.code)}</div>
      ${opts.orderNumber ? `<div class="order">${e(opts.orderNumber)}</div>` : ''}
      <div class="row bottom"><div class="box"><span>Palletnr:</span><b>${n}</b></div>
        <div class="date">${e(labelDate(opts.date))}</div>
        <div class="box amount"><span>Aantal:</span></div></div>
    </div>`;
  const sheets = (opts.sequence || []).map((n) => `<section class="sheet ${keg ? 'one' : 'two'}">
      ${keg ? `<div class="half">${kegLabel(n)}</div>` : `<div class="half">${packLabel(n)}</div><div class="half">${packLabel(n)}</div>`}
      <div class="note">${e(PALLET_LABEL_NOTE)}</div>
    </section>`).join('\n');
  return `<!doctype html><html><head><meta charset="utf-8"><title>Pallet labels ${e(opts.code)}</title>
<style>
  @page { size: A4 portrait; margin: 0; }
  * { box-sizing: border-box; }
  body { margin: 0; font-family: Calibri, Carlito, Arial, sans-serif; color: #000; }
  .sheet { width: 210mm; height: 297mm; position: relative; display: flex; page-break-after: always; break-after: page; overflow: hidden; }
  .sheet:last-child { page-break-after: auto; break-after: auto; }
  .half { flex: 1; position: relative; overflow: hidden; }
  .sheet.two .half + .half { border-left: 1px dashed #bbb; }
  /* the label: landscape box (sheet height × half width), turned 90° */
  .lbl { position: absolute; top: 100%; left: 0; transform-origin: top left; transform: rotate(-90deg);
    display: flex; flex-direction: column; justify-content: space-between; padding: 8mm 10mm 14mm; }
  .one .lbl { width: 297mm; height: 210mm; }
  .two .lbl { width: 297mm; height: 105mm; padding: 5mm 8mm 12mm; }
  .fit { font-weight: 700; white-space: nowrap; line-height: 1; overflow: hidden; }
  .keg .code { font-size: 120pt; }
  .keg .beer { font-size: 72pt; }
  .pack .beer { font-size: 80pt; }
  .pack .code { font-size: 72pt; }
  .order { font-size: 30pt; }
  .row { display: flex; align-items: flex-end; gap: 8mm; }
  .bottom { justify-content: space-between; }
  .box { border: 2px solid #000; min-width: 40mm; min-height: 22mm; padding: 2mm 3mm; display: flex; flex-direction: column; }
  .box span { font-size: 12pt; font-weight: 700; }
  .box b { font-size: 34pt; line-height: 1; text-align: center; }
  .keg .box { min-width: 50mm; min-height: 34mm; }
  .keg .box span { font-size: 20pt; }
  .keg .box b { font-size: 48pt; }
  .box.amount { min-width: 80mm; }
  .bb span { display: block; font-size: 28pt; font-weight: 700; }
  .bb b { font-size: 48pt; }
  .date { font-size: 14pt; }
  .note { position: absolute; bottom: 4mm; left: 0; right: 0; text-align: center; font-size: 8pt; font-weight: 700; }
  @media screen { body { background: #888; } .sheet { background: #fff; margin: 10px auto; } }
</style></head><body>
${sheets}
<script>
  // shrink a line until it fits its label, like "shrink to fit" in Excel
  document.querySelectorAll('.fit').forEach(function (el) {
    var size = parseFloat(getComputedStyle(el).fontSize);
    while (el.scrollWidth > el.clientWidth && size > 12) { size -= 2; el.style.fontSize = size + 'px'; }
  });
  window.addEventListener('load', function () { setTimeout(function () { window.print(); }, 200); });
</script>
</body></html>`;
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = { PALLET_LABEL_NOTE, palletLabelSequence, palletBatchCode, bestBeforeText, labelDate, palletLabelsHtml };
}
