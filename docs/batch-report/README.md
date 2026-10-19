# Digital batch report — start here

The batch report moves from the Excel workbook (`Moederdata.xlsm`, one
workbook per batch) into the app: brewing, fermentation log, processing,
filling and filling report become screens backed by tables, so production
data becomes analysable. This folder is the brief for building it.

Status (19-10-2026): design agreed (mockup), data model agreed. Phase 0
(foundation) merged; phase 1 (navigation) on branch `batch-report-phase-1`. Built phase by phase, each on its own branch with a pull request.

## Read in this order
1. **`decisions.md`** — what has been decided and why. Do not reopen these
   without asking Jaap.
2. **`data-model.md`** — tables, columns, constraints, RLS, triggers, views,
   and which phase creates what.
3. **`business-rules.md`** — every calculation and derived value (stages,
   cellar plan, Time 0, cellar loss, deviations, …).
4. **`screens.md`** — per screen: blocks, fields, labels, behaviour,
   validation. Each screen points to its mockup board.
5. **`phases.md`** — the backlog: tasks, acceptance criteria, test checklist
   and a start prompt per phase. **Work one phase at a time.**
6. **`open-questions.md`** — not decided yet. Never pick an answer yourself;
   ask Jaap, or build the phase without that part.
7. **`mockup/`** — the design: `.dc.html` source per board (precise: layout,
   labels, example data, interaction logic) and
   `Jopen_batch_report_mockup.html` (all boards in one clickable file —
   open in a browser).
8. **`test-scenarios.md`** — worked examples with expected results.

Repo-wide rules still apply first: `CLAUDE.md`, `ARCHITECTURE.md`.

## Scope
In scope:
- Navigation: home group "Batch reports" (Batch creation, Active batches,
  All batches).
- Batch screens: Overview, Brewing, Fermentation log, Processing, Filling,
  Filling report; popups for calculators, split/transfer.
- Settings: action tags. Recipe editor: cellar plan.
- Ingredient snapshot per batch with "changes vs recipe".

Out of scope for now (later, separately agreed):
- Booking stock automatically from the batch report (stock stays in
  `voorraad-uitboeken.html`; the report *reads* consumption — see decisions).
- Mdrank integration; packaging bills of materials in Mdrank's structure.
- Replacing the Excel flow. **Batch creation keeps generating the Excel**
  until the digital report has been tested in production, also
  administratively. Both run side by side; every batch gets the digital tabs.
- Historical batches before 2026 (no migration of old Excel data). The 2026
  batches **are** imported from their Excel reports, after phase 8 (see
  `phases.md`, "Import 2026 batches").

## Working agreement (per phase)
1. Branch `batch-report-phase-<n>`.
2. Migration SQL: write it, then **Jaap runs it in the SQL Editor** after a
   dry run (the Supabase connector cannot run destructive DDL). Register the
   version in `supabase_migrations.schema_migrations` **before** the file is
   pushed (`supabase/migrations/README.md`).
3. Code + Node/jsdom tests + `python3 tools/ci_guard.py`.
4. Pull request with a short rooktest checklist for Jaap. Jaap merges.
5. Design questions go back to the chat (where the mockup lives); the docs
   here are then updated.
