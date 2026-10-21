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
- ~~Initials are written down as text~~ **Changed 21-10: initials are
  linked to users.** Jaap named every initial in the samples
  (`tools/batch-import/initials.py` lists them); the people who are not
  users yet get an account ahead of the invite (Users page, "New invite
  link" when the invite is sent later). Workbook initials = `users.initials`:
  EVL = Eric van der Lugt (app initials changed from EL), EL = Eric Loman,
  BS = Bart Stelleman, BS1 = Bohdan Saveliev, MP = Michel Papavoine,
  NS = Nick Sweeren, MVG = Matthijs van der Geest. An initial without a user
  is reported in the review, not guessed. Historical rows get the person as
  the user column (`brewer_id`, `started_by`, …) and, where the app uses
  `created_by` as the operator (fermentation log, filling "Filled by"), as
  `created_by`.
- **Stages follow the data**; `batches.status` is not changed by the import
  (Jaap, 21-10).
- **Brewer start / end** (Jaap, 21-10): the brew sheet's second name next to
  the brewer (the unit column of the brew pair, row "Naam brouwer") is the
  brewer who finished the brew → `batch_brews.brewer_end_id`.
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

### Reader findings (samples 26260, 26292, 26293; 21-10)
`tools/batch-import/reader.py` + `review.py`. Choices made, to confirm:
- **Yeast block** (Brouwen K44-N52) is mostly formulas referencing the
  Overview values; imported (Jaap, 21-10: the app's batch report does the
  same), marked `formula` in the review.
- **GLT** comes from Brouwen I5 (typed); Gistkaart D4 is a formula copy.
- **Brew labels depend on the brewery** (formulas on `LEFT(A1,2)="WP"`):
  P19 WP "Cumm, Sparging vol," / JK "spoelwater" (-> `sparge_water_hl`),
  P20 WP "Last run pH" / JK "Spoelafloop" (-> `sparge_runnings_hl`). The
  reader maps the label as calculated, per section. Fixed rows: P18
  "Eerste afloop" -> `first_wort_volume_hl` (the Brewing tab shows it for
  JK only; WP values are kept), P14 "Spoelwater" in Mashing (0.6-0.9 hl at
  WP) -> `mash_rinse_water_hl` "Rinse water" (column added 21-10; the
  samples' comments were moved into it by the migration).
- **Section rows** of the brew sheet (Maischen, Koken: "salts", "520g
  Flex"), text in number cells and text in unit cells become brew comments.
- **Log entries without an hour** get 12:00 (review: `missing`). Row 13
  (Time 0) is skipped. Several operators: the first is `created_by`, the
  others go into the comment ("Op. TM/JB").
- **Processing**: a block counts only with a date or operator (template
  defaults "Standpijp", losses 1 / 10, "Can" fill the empty ones). Only the
  first centrifuge row has columns (start flow / turbidity); the other rows
  are not imported. "Pasteurised with" (PU) and "Avg. turbidity" go onto
  every HBT of the batch, the mean over the sessions (Jaap, 21-10); avg
  temp out has no column. With one session the HBT readings are linked to
  it; with more, the workbook does not say which fill came from which
  session (left empty; Jaap: not important for now).
- **HBT fills**: readings grouped per fill (an empty row closes a fill);
  "End value HBT" rows match the fills in order and add a last reading.
  Filling sessions of a tank go to its fills in date order; a fill is
  finished once the filled volume reaches its end value (3 %).
- **Package per filling session** from the articles booked (Afvulverslag),
  else keg when keg CO2 / O2 is measured.
- **Transfers (splits)**: the old way was writing the split on the
  Processing form ("End value HBT" without tank, comment "to 26321") so the
  volume reaches the filling report, and booking it off there ("TBV BATCH
  26321", liters). The reader reads both and checks the volumes; the date
  comes from the log entry that names the volume (that entry gets the
  Transfer tag). Jaap (21-10): record these with the new method
  (`batch_transfers`). The receiving batch: when the transfer volume =
  its brews x brew volume and its own brew sheet is empty, its whole volume
  came from the split and nothing was brewed (brew count -> 0, as a split
  batch in the app). Otherwise: review with Jaap. Transfers are written in
  a separate chunk once the receiving batches' workbooks are read.
- Not imported (no column): later centrifuge rows, measurement after
  pushing over, start date lagering, lot numbers on Afvulverslag, liters
  "TBV batch / barrel aging" (record as a split).

### Old reports (not generated; batches 26001 to about 26259)
Same sheets and labels as the generated report (plus "EBU Berekening"),
but 4.3 MB each: "Gistkaart Invoer" is 16,142 columns wide. The reader
streams every sheet once, columns A-AN only (about 15 s per workbook).
Seen in 26001-26005 (21-10): a filling session written only on the
filling report (26003: made from the report: date, HBT, volume, articles),
template HBT numbers in empty reading rows (dropped), yeast strain typed
with a trailing dash ("US-05-", trimmed), file names without a minor
version ("v4") or without a version. **Brew count follows the workbook**
(Jaap, 21-10: the app does not know how many brews these batches had):
the SQL sets `batches.brew_count` to the number of brews read, when they
differ; the result line shows "brew_count 1->2". "GdV 20L" (kegs used)
is the material `gbr_door_vrouwen_keg_20` (migration `20261021140000`).
Initials of former employees (MM, FI, ...) become inactive users without a
login (one SQL file once the full scan lists them all), so the history
keeps the person.

**Coverage check** (21-10, all 8 workbooks): every typed cell of the five
operator sheets that the reader does not take was listed. Added after it:
the brewers' remarks ("Opmerkingen :", column A below the recipe block) as
batch-wide brew comments. Not taken, by design: the recipe / spec blocks
(typed in the old reports), calculators, pre-filled dates and tank
numbers without values, EAN codes and lot numbers, material remarks
("Printed", "GdV"), "Ingevuld door" of the filling report (parked column),
the Time 0 row of the fermentation sheet (the app makes it), later
centrifuge rows, avg temp out, start date lagering, measurement after
pushing over.

### Workbook types and hold (21-10)
The reader first decides the type: `generated` / `old` (batch report) or
`barrel_aging` ("Hout Rijping" sheet); anything else is unknown. Only batch
reports are read; the rest is **held**: listed in the review with the
reason, left out of the SQL, never guessed. A workbook that fails to read
is written as `FAILED_<file>.txt` and the run goes on. Per chunk (a month)
the review is gone through before any SQL; after a reader change the
tests run and the imported batches are re-read and compared (a difference
gets a correction SQL, never a silent change). A major deviation goes to
Jaap: extend the reader for a recurring type, a one-off SQL after his OK,
or left for entering by hand.

**Barrel aging** (26058-26064, 26089, 26090; 21-10): sheets Hout Rijping,
Gistkaart Invoer, " Verwerking", Afvullen, Afvulverslag, Lab uitslag, Ruwe
data, Etiketsheet. All nine still aging (no emptying date); only Hout
Rijping is filled: source batch, barreled volume, barrels, fill date,
treatment, original beer values, additions. The source batches book most
of them off as "TBV BARREL AGING BATCH" (26042 does not). Proposal to
Jaap: a split from the source batch at the barrel fill date (brew count
0), barrel information as a log entry, additions as Addition entries;
per-barrel data waits for barrel-aging support in the app.

### SQL per chunk (step 5)
`tools/batch-import/generate_sql.py <reader_out> <app.json> <out_dir> <chunk> [batch ...]`
writes `import_<chunk>_dry_run.sql` and `import_<chunk>_run.sql`: one DO
block; per batch it checks the batch exists and its tabs are empty (else
skipped and listed), fills batch columns only where empty, inserts the
rows (people via `users.initials`, tanks / tags / packaging via codes;
the operator is `created_by`) and reports rows per table and the stage
before -> after. Tested on a local Postgres with `supabase/schema.sql`
(dry run rolls back; a second run skips every batch).

### Documents (Filling report)
The PDFs are in the batch-reports repo, the batch number in the file name
(Jaap, 21-10): `...ProductieBon...` = production order, `...AfvulOrderBon...`
= filling order, `av_<batch>...` = filling report, anything else = other.
`tools/batch-import/upload_documents.py` uploads them to the private bucket
`batch-documents` (`<batch_id>/<type>/<ms>_<file>`) with a `batch_documents`
row, as the Filling report tab does (no file without a row). Run by the
workflow "Upload documents" in batch-reports-2026 (Actions tab; dry run
first, then with "Upload" ticked); needs the repo secret
`SUPABASE_SERVICE_ROLE_KEY`. Held, not uploaded: no batch number, a batch
not in the app, larger than 20 MB, two files of one fixed type for a
batch. Skipped: a fixed type the batch already has, an "other" file with
the same name. Tested against a local stand-in of the API (upload, row,
removal of the file when the row fails).

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
