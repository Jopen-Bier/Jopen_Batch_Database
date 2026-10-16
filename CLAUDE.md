# CLAUDE.md — working rules for this repo

Read `ARCHITECTURE.md` before adding a page, table or app. These are the
rules that must not be skipped.

## Before changing anything
- Check the **live** database (`information_schema.columns`, `pg_policies`,
  `pg_constraint` incl. column defaults) before any schema or data change.
  Do not rely on docs, old session summaries or local files.
- Confirm with Jaap before any schema change, destructive data change or push
  that changes production behaviour.

## Database
- English names, `snake_case`, US spelling, in the right domain schema
  (`core`, `inventory`, `recipe`, `production`, or a new app schema).
  Use the glossary in `ARCHITECTURE.md` §3.3 and `supabase/rename-map.json`.
- No duplicate fields: one fact, one column, one table.
- RLS on every table, via the permission helpers; DELETE consistent with EDIT
  per role.
- `supabase/migrations/` is auto-executed on production by the GitHub
  integration. A migration run by hand (SQL Editor) must be registered in
  `supabase_migrations.schema_migrations` **before** its file is pushed.
- No `CASCADE` on drops unless explicitly agreed — let unexpected
  dependencies fail loudly.
- Never a full dump/baseline in `migrations/`; the baseline is
  `supabase/schema.sql` (refreshed nightly).
- `execute_sql` returns only the first result set: one query per call.
  Large VALUES lists: split. Enum values from VALUES need explicit casts.

## Code
- **New code in English** (identifiers, comments, commits).
- **Translation prompt:** when a change touches a large part of an existing
  Dutch page or block, first ask Jaap: *"Dit raakt een groot deel van
  <bestand/blok>. Zal ik dat hele blok meteen naar het Engels vertalen?"*
  Only translate the whole block if he agrees.
- UI labels in English; any doubtful translation goes to Jaap first.
- Generic helpers come from `jopen-utils.js` — never copy them into a page.
  A helper needed on a second page moves to `jopen-utils.js`.
- A calculation needed in more than one place becomes its own module with a
  Node test in `tests/` (pattern: `waterzouten.js`). Browser + Node export:
  `if (typeof module !== 'undefined' && module.exports) module.exports = {…}`.
- Excel batch report: patch XML via `xlsx-direct.js`; never load/save the
  template with ExcelJS. `batchrapport-vullen.js` has its own browser copy of
  the writer — change both.

## Before every push
- `node --check` on every changed `.js` file and on the extracted inline
  scripts of changed `.html` pages.
- Run `node tests/*.test.js`.
- For behaviour changes: jsdom test, with data injection and the call in one
  `window.eval(script + testCode)` (separate evals do not share `let`/`const`).
- Commit as `git -c user.name="Claude" -c user.email="claude@anthropic.com" commit`;
  rebase on `origin/main` if someone pushed in between.

## Secrets
- Session PATs are revoked by Jaap after each session. Automation secrets
  (`BACKUP_REPO_PAT`, `SUPABASE_DB_URL`, …) live in GitHub Actions — never
  in the repo, never revoked as part of a session.
