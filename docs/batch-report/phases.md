# Phases — backlog

One phase per branch (`batch-report-phase-<n>`) and PR. Each phase: check the
live schema first, write the migration, hand it to Jaap for a dry run and
execution in the SQL Editor, register the version, build, test, PR with a
rooktest checklist. Phases 0–2 are worked out in detail; later phases get
their detail when they start (design questions may change them).

Every PR also: `node --check`, `node tests/*.test.js`,
`python3 tools/ci_guard.py`, jsdom smoke test of every changed page; update
`ARCHITECTURE.md` (§4 pages, tables) and tick off items in `open-questions.md`
that were answered.

---

## Phase 0 — Foundation
**Goal:** reference data, initials, audit trail, permission module name,
stage view skeleton. Nothing visible to operators except initials on the
users page.

Tasks
1. Migration `…_batch_report_foundation.sql`:
   - `tanks` + seed (52 rows, data-model.md) + RLS (read all, write
     `settings`) + `set_updated_at` trigger.
   - `users.initials` + `set_user_initials()` trigger + backfill.
   - `permission_modules`: rename `batches` → "Batches & batch reports".
   - `batch_audit_log` + `log_batch_change()` (security definer,
     `search_path` set, EXECUTE revoked from `anon`/`authenticated`).
   - View `batch_stages` (security_invoker), phase-0 logic.
2. `gebruikers.html`: show and edit initials (admin).
3. Glossary in `ARCHITECTURE.md` §3.3: GLT/LT/CKT/HBT (tanks), Time 0,
   cellar plan (kelderplan), action tag (actietag), deviation (afwijking).
4. Answer/ask open questions 15 and 16 in the PR description.

Acceptance
- 52 tanks, codes unique; `select` works for a Viewer, insert only with
  settings edit rights.
- Every active user has initials; a new user gets them automatically; an
  admin can change them.
- `batch_stages` returns one row per batch (raw/closed).
- Guard green; advisors show no new security warnings.

Rooktest for Jaap: users page shows initials; edit one; check `tanks` in the
table editor.

Start prompt
> Read CLAUDE.md, ARCHITECTURE.md and docs/batch-report/README.md, then
> decisions.md, data-model.md (Phase 0) and phases.md. Check the live schema.
> Implement phase 0 on branch batch-report-phase-0: write the migration and
> give me the SQL for a dry run before anything is executed.

---

## Phase 1 — Navigation
**Goal:** the "Batch reports" home group, All batches and Active batches,
working on the existing batches.

Tasks
1. `index.html`: group "Batch reports" with tiles Batch creation, Active
   batches, All batches (existing tile style). Remove the old placeholder
   tile.
2. `all-batches.html` (new, English): table per screens.md from `batches` +
   `recipes` (version) + `batch_stages`; sort, filters, paging, export
   (.xlsx via the existing ExcelJS export pattern of `verbruiksprognose.html`).
3. `active-batches.html` (new): blocks per stage from `batch_stages`; until
   later phases exist, raw shows planned batches with order picking info,
   other blocks are empty. Tiles sorted by tank number; search, WP/JK filter;
   the "!" mechanism is built but has no rules yet (open-questions #1).
4. `nav.js`: links for the new pages (module `batches`).
5. Batch number links go to `batch-overview.html?id=…` (page arrives in
   phase 2; until then link to nothing or hide).

Acceptance
- All 349+ batches listed; filters/sort/paging work; JK batches labelled.
- Active batches shows the planned batches under Raw material preparation,
  sorted, filterable.
- Users without `can_view('batches')` do not see the tiles/pages.

Rooktest: open home → three tiles; All batches filters; Active batches.

---

## Phase 2 — Batch screen shell + Overview
**Goal:** open any batch in the app; Overview with editable ingredient
snapshot and deviations.

Tasks
1. Migration: `batches.order_picking_completed_at/_by`; `batch_ingredients`
   + RLS + audit trigger; `snapshot_batch_ingredients()`; AFTER INSERT
   trigger on `batches`; backfill for `planned` batches (dry run, counts per
   batch for Jaap).
2. Shared shell module: load batch + recipe, header, tab bar (other tabs
   disabled until their phase), autosave helper, delete-confirm + undo toast
   helper, initials lookup. Shared helpers go to `jopen-utils.js` if generic.
3. `batch-overview.html` per screens.md: cards, EBU/colour via
   `brew-calculations.js`, deviations list, order picking checkbox, lots from
   `stock_movements`.
4. Calculations for Δ batch / inventory effect in a module with a Node test.
5. `batchcreation.html`: nothing to change (trigger) — verify a new batch gets
   its snapshot; Excel generation unchanged.

Acceptance
- New batch → snapshot rows equal to the recipe; existing planned batches
  backfilled; opening an older batch creates its snapshot once.
- Editing amount/alpha/EBC, adding and removing rows works, amber + reason
  required, audit log rows written.
- EBU/colour identical to `recept-invoer.html` for an unchanged batch.
- Excel export still identical for a new batch.

---

## Phase 3 — Brewing
Migration: `batches.brewhouse_recipe_number`, `yeast_pitched_by` → uuid;
`batch_brews`, `batch_brew_comments` (+ RLS, audit). Page
`batch-brewing.html`: brew day card, read-only specs, yeast pitching (writes
`batches.yeast_*`), brewer's comments, brew log matrix with WP/JK variant,
calculated rows and results per brew + GLT total (module + test).
`batch_stages`: brewing / fermentation rules. Active batches: Brewing tiles.

## Phase 4 — Fermentation log
Migration: `batches.time_zero/glt_tank_id/lt_tank_id`; `cellar_action_tags`
(+ seed); `recipe_cellar_steps` + `generate_recipe_cellar_steps()` + backfill
for active recipes (dry run, review sheet for Jaap); `batch_cellar_steps` +
snapshot extension (`snapshot_batch`); `fermentation_log_entries`,
`fermentation_log_entry_tags`, `batch_transfers`. Recipe editor: cellar plan
block (view/edit/reorder, copied with a new version). Settings: action tags.
Page `batch-fermentation.html`: batch card, specs, cellar plan progress,
measurements & actions with tags, calculators, transfers (simple form),
curve. `batch_stages`: fermentation/lagering. Active batches: Cellar tiles.
Needs answers: open-questions 3, 4, 5, 12 (answered 19-10).
Also in phase 4 (Jaap, 20-10): Settings › Cellar plan (order by drag and
drop, timing values), the Timing dropdown of cellar additions, and the recipe
data fixes from the review sheets.

## Phase 5 — Processing
Migration: `batches.cellar_additions_done/tasting_comment/tasting_result`;
`processing_sessions`, `processing_comments`, `batch_hbts`, `hbt_readings`.
Page `batch-processing.html` per screens.md, incl. release, totals and cellar
loss (module + test). `batch_stages`: hbt. Active batches: HBT tiles.
Built 20-10: `processing.js` (+ test); the transfers card and the calculators
moved to `batch-report-cards.js` (shared by Fermentation log and Processing).

## Phase 6 — Filling
Migration: `filling_sessions`, `filling_measurements`. Page
`batch-filling.html`: sessions, checks, HBT finished, measurements, Cpk
(module + test). `batch_stages`: filling/filled.
Built 20-10: `filling.js` (+ test); Filling / Filled tiles.

## Phase 7 — Filling report
Migration: `packaging_articles`, `packaging_materials`,
`packaging_article_materials` (+ settings UI or seed from Jaap's list),
`filling_session_articles`, `filling_session_materials`. Page
`batch-filling-report.html`: volume balance + pie, sessions, materials,
summary. Closing/Mdrank stays parked (open-questions 8).
Built 20-10: `filling-report.js` (+ test); seed from the mockup list;
Settings › Packaging articles / materials; the Filling report tab is active
and Filled batches open on it.

## Phase 8 — Splits
Split / transfer popup on all three tabs, new batch from split (next number,
0 brews), base beer lines, dosing on total volume. Needs open-questions 9.
Batch volume = brews × brew volume + volume added from splits (Jaap,
20-10); a batch made only from a split has 0 brews and only the added
volume. The recipe additions are dosed per hl on that volume, which
replaces the fractional `brew_count` workaround (3.33 = 130 hl ÷ 40 hl).
Base beer lines reference the source beer by recipe group (open-questions
9). Still open: do existing batches with a fractional brew count keep
dosing on it? Jaap is still working out the best splitting flow before
phase 8 starts.
Built 20-10: `split_batch()`, base beer lines, `splits.js` (+ test), the
popup and incoming beer on the three tabs, the base beer block in the recipe
editor, dosing on brews + incoming. Fractional batches keep their brew
count (answer to the open point: no change needed, they have no incoming
transfers).

## Import 2026 batches (after phase 8)
Agreed 19-10: once all phases are built, the 2026 batches are filled from
their Excel batch reports, so their stage and data are right in the app.
- Reader script: maps the cells of the template (`Batchrapport_sjabloon.xlsx`,
  `batchrapport_cel_mapping.csv`) to the batch tables; sheets Brew Sheet,
  Fermentation Chart, Processing, Filling, Filling Report.
- Start with 3–4 sample workbooks from Jaap (finished, in cellar, JK, early
  in the year); ask where the workbooks are kept, whether the template
  changed during 2026, `.xlsm` or `.xlsx`.
- Review spreadsheet per batch (read / missing / suspicious) for Jaap before
  anything is written; dry run, then import.

## After phase 8 (separately agreed)
Excel fallback export filled from report data; stock booking from the report
(corrections, lots at batch creation); batch creation without Excel.
