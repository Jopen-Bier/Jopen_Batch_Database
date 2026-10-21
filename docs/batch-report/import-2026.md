# Import of the 2026 batch reports (Excel → app)

Brief for a new Claude Code session. Goal: fill the app with the data of all
2026 batches (300+) from their Excel batch reports, **for history**, so the
batch tabs (Brewing, Fermentation log, Processing, Filling, Filling report)
show what happened and the data can be analysed.

Read first: `CLAUDE.md`, `ARCHITECTURE.md`, `docs/batch-report/README.md`,
`data-model.md` (what goes where), `business-rules.md` (stages, Time 0,
dosing). The app's tables are built (phases 0–8 merged, 20-10-2026).

## Decisions so far (Jaap, 21-10-2026)
- **Recipe version: keep what is in the database.** A workbook can name
  another version (26260: workbook Esma Stout v4.0, batch in the app v4.1);
  do not change the batch, mention it in the review.
- **Initials are written down as text**, not matched to users (EVL, BS, BS1,
  NS, HL, MP are not users; the users table has `initials`). Not important
  for historical items; linking to users comes later. Where the text goes
  (a comment field, or a new text column) is a schema question: propose it
  to Jaap before changing anything.
- **History only:** import into batches that exist in the app and whose
  tabs are still empty (no brews, log, processing, filling). Never
  overwrite data entered in the app; report such batches instead.
- Formula cells and error cells (`#VALUE!`, `#N/A`, `#DIV/0!`) are not
  imported: the app calculates its own values (GLT totals, ADF, durations,
  litres, losses). Read values as last calculated by Excel (`data_only`).

## Working rules for this import
- Same safety rules as the phases: check the **live** database first;
  confirm with Jaap before any schema change, data write or push that
  changes production behaviour; no `CASCADE`.
- Writes go as SQL files Jaap runs in the SQL Editor: first a **dry run**
  (ends with `raise exception 'DRY RUN - rolled back. Results: %'`), then
  the RUN. Keep the SQL **plain ASCII** (the editor changed a `×` once and
  the UTF-8 check stopped the script): write special characters as
  `chr(…)`. Send SQL files with `SendUserFile` and `display: 'render'`, so
  they open in the session window (Jaap prefers that to a download).
- 300+ batches will not fit one SQL file: work in chunks (e.g. per month)
  with a summary of rows per table per chunk.
- Work flow with Jaap: actions first, as a numbered list.
- Workbooks are untrusted input: own folder, Python with `-I`, paths as
  arguments. Do not commit workbooks to this repo.

## Where the workbooks are
Ask Jaap how to get all 2026 workbooks into the session (e.g. a zip upload
in parts, or a separate private repository — not this one). Two samples were
looked at: `26260_Esma_Stout_v4.0_WP.xlsx` (one processing session) and
`26292_Mooie_Nel_v11.1_WP.xlsx` (three processing sessions, still filling).
Ask for more samples early: a finished batch, a JK batch, one from early in
2026, one with a split / blend.

## The workbooks (first look, 21-10-2026)
Old Dutch layout (the template in `batchrapport-generator/` now has English
sheet names). Sheets: Recept-voorblad, Brouwen, Gistkaart Invoer,
Verwerking, Afvullen, Afvulverslag. Tools: `tools/batch-import/` (cell dump,
grid view, label diff between two workbooks).

| Sheet | Layout | Same in both samples | Into |
|---|---|---|---|
| Recept-voorblad | recipe data; rows shift with the ingredients | no (rows shift) | not imported (recipe is in the app) |
| Brouwen | labels in column P (rows 3–44); one column pair per brew: S, U, W, Y, AA, AC, AE, AG, AI (value, unit); header K3 batch number, I5 GLT, N5 date 1st brew; yeast block K44–N52; rows 53–65 are a calculated summary (ignore) | yes, same cells | `batch_brews` (fields: `BREW_LOG_ROWS` in `batch-brews.js`), batch yeast columns on `batches` |
| Gistkaart Invoer | header row 12; one row per day from row 13: A days, B plato, C temp high, D temp low, E pH, J date, K hour, L action (text), O comment, U operator; D4 GLT, E4 LT; the block X38–AB60 is the plan / calculators (ignore) | yes | `fermentation_log_entries` (+ tags), `batches.glt_tank_id` / `lt_tank_id` |
| Verwerking | spec block rows 5–12 (lagering start N11); then 1–3 processing blocks, each starting at "Name operator start" (operators D, date D, start / end time P, from (G)LT D, values before start, centrifuge rows J flow / M hl / P turbidity / R bypass, pasteurised with D, avg temp J, avg turbidity P, comments C, tasting comment / go R); then "Bright beer tanks (HBT):" with rows "HBT": B tank, C hl, E O2, G CO2, J package; then "End value HBT:" rows; "GLT empty?" R | **no**: 26260 has 1 block, 26292 has 3 (HBT section at row 32 vs 70) — find sections by label | `processing_sessions`, `processing_comments`, `batch_hbts`, `hbt_readings`, `batches.tasting_*`, `glt_empty` |
| Afvullen | sessions in columns M–R (max 6): row 6 date, 8 HBT, 10 start, 12 end, 13 filled by, 16 sampled by, 17 first package check; measurement blocks of 10 rows from row 24 (time, TPO, HSO, DO, HS vol, pressure, temp, CO2 bottle / can, CO2 keg, O2 keg), repeated | yes | `filling_sessions`, `filling_measurements` |
| Afvulverslag | sessions in columns D–I (same order as Afvullen M–R): row 7 date, 9 HBT, 11 volume; articles (book in) and materials (book out) per row by Dutch name | rows shift by one from the can boxes (26292 has an extra article row) — find rows by name | `filling_session_articles`, `filling_session_materials` |

### Mapping notes
- **Brew columns**: brew n = column S + 2(n−1). Values can be `-` or text
  (e.g. "FH" and "SB" on one brew): keep text, flag in the review.
- **Fermentation actions** are free text; map to `cellar_action_tags`:
  24h purge → 24h_purge, purge → purge, dry warm → dry_warm, dryhopping →
  dryhopping, koelen → cooling, toevoeging → addition, sample naar lab →
  sample_lab, samenvoegen → blending, others → other (keep the text in the
  comment). Check the live tag codes first. Rows with only a comment are
  log entries without measurements.
- **Time 0 / first log row** (row 13, "laatste brouwsel"): the app makes the
  Time 0 entry itself from the end of the last brew; do not import it twice.
- **Package per filling session** is not in Afvullen: take it from the
  articles booked in Afvulverslag (cans / kegs / bottles) and from which
  measurement rows are filled (keg CO2 / O2 = keg).
- **Article and material names** match the seeded packaging data
  (`packaging_articles` / `packaging_materials`, migration
  `20261020150212`): e.g. "Doos 24x33cl Blik" → box_24x33_can, "20L
  Jopen/KU Fust" → jopen_keg_20, "Blik 33cl" → can_33, "Blik Deksel" →
  can_lid, "Omdozen 24x33cl blik - Blanco" → box_24x33_can (material),
  "Jopen Fust 20L" → jopen_keg_20, "Fustdop" → keg_cap. Neck labels and the
  Global Keg were removed (migration `20261020143543`): report if booked.
- **Same HBT twice** (26292: HBT 16 filled, emptied and filled again over
  the processing days; end values 120 and 108.8 hl): this is normal (Jaap,
  21-10) and the app allows it: one `batch_hbts` row per fill, in order
  (`sort_order`), each with its own readings and end value. The
  uniqueness per (batch, tank) is removed in the phase 8 follow-up
  (check that it is gone in the live database before importing).
- **Values to flag** (suspicious): outliers such as TPO 563 / HSO 505 in
  26292 session 2, text in number cells, dates outside the batch period,
  totals in the workbook that differ from what the app calculates
  (e.g. GLT volume, filled litres).

### Stages after import
`batch_stages` follows the data: brews ended → fermentation, lagering step
done → lagering, processing date → hbt, filling date → filling, all HBTs
finished → filled; `batches.status = 'completed'` → closed (258 of the 348
batches of 2026 are completed in the app, 90 planned, 21-10-2026). Check
with Jaap whether imported finished batches should become `completed`.
The cellar plan steps are ticked off by the tags of the log entries.

## Plan
1. Get access to the workbooks; ask the open points above (where the
   initials go, completed status).
2. Reader (Python, `tools/batch-import/`): workbook → JSON per batch in the
   app's table / column names, label-anchored where layouts differ. A Node
   or Python test with the two samples.
3. Review workbook per batch for Jaap (sheet per tab: source cell, label,
   value, target column, status read / missing / suspicious) and one
   summary sheet over all batches (found, imported rows per table,
   warnings). Jaap reviews the two samples first.
4. More samples (finished, JK, early 2026, split) → adjust the reader.
5. SQL generation per chunk: dry run (counts per table, stage before /
   after, no existing data touched), Jaap runs it, then the RUN; verify on
   production after each chunk.
6. Afterwards: link the initials to users (later), update `phases.md`.
