// ============================================================================
// pallet-labels.js — printable pallet labels from the Filling page
// (wishlist #2), after the Excel sheets "1. Palletbrief - vaten" (keg) and
// "1. Palletbrief - fles en blik" (bottle / can).
//
// One layout for every package (Jaap, 29-10): beer name, batch code, Best
// Before + date (kegs month and year only). One label = one A4 sheet; a keg sheet has the label once, a
// bottle / can sheet twice side by side, folded round the pallet corner. Labels per pallet × pallets sheets, numbered 1..pallets.
// Batch code on the label: L<batch number>/<HBT tank number>.
//
// Browser: <script src="pallet-labels.js">. Node: require('../pallet-labels.js').
// Test: tests/pallet-labels.test.js.
// ============================================================================

const PALLET_LABEL_NOTE = 'Deze palletlabel op de rechterhoek van de smalle kant opplakken svp.';

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

/**
 * THT (best before) date: filling date ('YYYY-MM-DD') + months → 'YYYY-MM-DD';
 * the day is clamped to the month (31 Jan + 1 month → 28/29 Feb). '' on bad input.
 */
function thtDate(date, months) {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(date || ''));
  const add = Number(months);
  if (!m || !Number.isFinite(add) || add <= 0) return '';
  const total = Number(m[1]) * 12 + Number(m[2]) - 1 + Math.round(add);
  const year = Math.floor(total / 12), month = total % 12;
  const day = Math.min(Number(m[3]), new Date(Date.UTC(year, month + 1, 0)).getUTCDate());
  return `${year}-${String(month + 1).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
}

const MONTHS = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'];

/** Best before as printed: kegs month and year only ('OCT 2028'), bottle / can the full date. */
function bestBeforeLabel(date, format) {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(date || ''));
  if (!m) return '';
  return format === 'keg' ? `${MONTHS[Number(m[2]) - 1]} ${m[1]}` : `${m[3]}-${m[2]}-${m[1]}`;
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
 * Full print document. opts = { format: 'keg' | 'bottle' | 'can', beerName,
 * code, tht ('YYYY-MM-DD', best before; differs per package type),
 * sequence (palletLabelSequence) }. One layout for every package: beer name
 * big, batch code under it, "Best Before" + date; a keg sheet has the label
 * once, a bottle / can sheet twice (folded round the pallet corner).
 */
function palletLabelsHtml(opts) {
  const e = labelEscape;
  const one = opts.format === 'keg';
  // Each label is laid out landscape (as read on the pallet) and turned a
  // quarter on the portrait A4, like the rotated text in the Excel sheets.
  const label = (n) => `<div class="lbl">
      <div class="row"><div class="box"><span>Pallet no.</span><b>${n}</b></div><div class="box amount"><span>Aantal / Amount</span></div></div>
      <div class="fit beer">${e(opts.beerName)}</div>
      <div class="fit code">${e(opts.code)}</div>
      <div class="fit bb">Best Before <b>${e(bestBeforeLabel(opts.tht, opts.format))}</b></div>
    </div>`;
  const sheets = (opts.sequence || []).map((n) => `<section class="sheet ${one ? 'one' : 'two'}">
      ${one ? `<div class="half">${label(n)}</div>` : `<div class="half">${label(n)}</div><div class="half">${label(n)}</div>`}
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
  .fit { font-weight: 700; white-space: nowrap; line-height: 1.05; overflow: hidden; }
  .row { display: flex; justify-content: space-between; gap: 8mm; }
  .box { border: 2px solid #000; padding: 2mm 3mm; display: flex; flex-direction: column; }
  .box span { font-weight: 700; }
  .box b { line-height: 1; text-align: center; }
  .one .beer { font-size: 110pt; }   .two .beer { font-size: 80pt; }
  .one .code { font-size: 80pt; }    .two .code { font-size: 58pt; }
  .one .bb { font-size: 48pt; }      .two .bb { font-size: 34pt; }
  .one .box { min-width: 50mm; min-height: 34mm; } .one .box span { font-size: 18pt; } .one .box b { font-size: 48pt; }
  .two .box { min-width: 36mm; min-height: 20mm; } .two .box span { font-size: 11pt; } .two .box b { font-size: 30pt; }
  .one .box.amount { min-width: 100mm; } .two .box.amount { min-width: 80mm; }
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
  module.exports = { PALLET_LABEL_NOTE, palletLabelSequence, palletBatchCode, thtDate, bestBeforeLabel, labelDate, palletLabelsHtml };
}
