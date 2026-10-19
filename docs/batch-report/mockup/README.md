# Mockup

Exported from the design canvas "Batch report mockup" (claude.ai, private
Design artifact) on 19-10-2026. The canvas stays the place where the design is
changed; this folder is a snapshot for building.

- `Jopen_batch_report_mockup.html` — all boards in one clickable page. Open it
  in a browser; the bar on top switches between boards; example data only,
  nothing is saved.
- `*.dc.html` — source per board (markup + a small component class with the
  example data and interaction logic). Most precise reference for labels,
  layout, validation colours and calculations.
- `canvas.json` — board list and order.
- `build_share.py` — rebuilds the HTML: `python3 build_share.py . out.html`.

| Board | Screen |
|---|---|
| Home | home group "Batch reports" |
| ActiveBatches / AllBatches | navigation |
| Overview, Brewing, Main (= Fermentation log), Processing, Filling, FillingReport | batch tabs |
| Calculators, NanoFlavor, SplitBatch | popups |
| Settings | action tags |
| BatchCreation | lot selection sketch (later, not in phases 0–8) |

Note: batch numbers in the mockup look like `26-0412`; the app uses the
existing format (`26346`). Beer names, lots and numbers are example data.
