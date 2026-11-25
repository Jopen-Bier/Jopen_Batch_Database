# CLAUDE.md — working rules for this repo

Read `ARCHITECTURE.md` before adding a page, table or app. These are the
rules that must not be skipped.

Working on the digital batch report? Start at `docs/batch-report/README.md`.

## Before changing anything
- Check the **live** database (`information_schema.columns`, `pg_policies`,
  `pg_constraint` incl. column defaults) before any schema or data change.
  Do not rely on docs, old session summaries or local files.
- Confirm with Jaap before any schema change, destructive data change or push
  that changes production behaviour.

## Database
- English names, `snake_case`, US spelling. The brewery app lives in
  `public`; a separate app gets its own schema and reads shared data through
  explicit views in that schema (PostgREST only embeds within one schema).
  Use the glossary in `ARCHITECTURE.md` §3.3 and `supabase/rename-map.json`.
- No duplicate fields: one fact, one column, one table.
- RLS on every table, via the permission helpers; DELETE consistent with EDIT
  per role.
- `anon` (not logged in) has no rights in `public` (security phase 1,
  19-11-2026). New policies are `to authenticated`. New tables get no anon
  grant by default, but new functions are executable by PUBLIC by default:
  every new function gets `revoke execute … from public, anon` plus an
  explicit `grant execute … to authenticated` (and `claude_reader` if a view
  it reads calls the function).
- The company-Claude connector (`supabase/functions/claude-reader-mcp`) logs
  in as `claude_reader_login` and queries as `claude_reader`, which reads all of
  `public` except people data (`users`, `batch_audit_log`,
  `brew_planning_history_detailed`; security phase 4). New tables get
  `claude_reader` SELECT by default: revoke it for any new table or view with
  people data. Tokens come from `claude_connector.issue_token()` and expire.
  Deploy the function from the repo file with verify_jwt = false.
- Two-factor authentication (security phase 5, `docs/security/mfa.md`):
  `current_role_id()` and `is_admin()` include `mfa_satisfied()`; required
  per role via `roles.mfa_required` (always on for admin). New permission
  helpers must go through these two, and Edge Functions check admin rights
  with `callerClient.rpc("is_admin")` (the caller's session), never with a
  service-role lookup of the role.
- Audit (security phase 6): batch tables log to `batch_audit_log` via
  `log_batch_change()`, inventory tables (`lots`, `stock_movements`) to
  `inventory_audit_log` via `log_inventory_change()`. A new table holding
  batch or stock data gets the matching `after insert or update or delete`
  trigger. Both logs stay append-only: never add insert/update/delete
  policies or grants for app roles.
- New SECURITY DEFINER functions: `set search_path = public, pg_temp` (or
  `''` with schema-qualified names), never plain `public` (security phase 7).
- A new database role that a policy, view or function names must also be
  created in `.github/backup/supabase_stub.sql`, or the nightly trial restore
  fails on "role … does not exist" (happened with `claude_reader_login`).
- `supabase/migrations/` is auto-executed on production by the GitHub
  integration. A migration run by hand (SQL Editor) must be registered in
  `supabase_migrations.schema_migrations` **before** its file is pushed.
- No `CASCADE` on drops unless explicitly agreed — let unexpected
  dependencies fail loudly.
- Never a full dump/baseline in `migrations/`; the baseline is
  `supabase/schema.sql` on branch `schema-snapshot` (refreshed nightly):
  `git fetch origin schema-snapshot && git show origin/schema-snapshot:supabase/schema.sql`.
- `execute_sql` returns only the first result set: one query per call.
  Large VALUES lists: split. Enum values from VALUES need explicit casts.

## Code
- **New code in English** (identifiers, comments, commits).
- **Translation prompt:** when a change touches a large part of an existing
  Dutch page or block, first ask Jaap: *"Dit raakt een groot deel van
  <bestand/blok>. Zal ik dat hele blok meteen naar het Engels vertalen?"*
  Only translate the whole block if he agrees.
- UI labels in English; any doubtful translation goes to Jaap first.
- Untranslated (Dutch) page code talks to the English database through the
  translation layer (`ARCHITECTURE.md` §6a): aliases in selects, English
  filters and values, `toDb()` for payloads. New code uses English names
  directly. Regenerate `db-legacy-names.js` from `rename-map.json`, never
  edit it by hand.
- Embedding `users` (or any table a row points at more than once): always name
  the foreign key, `users!batches_created_by_fkey(name)`. A second user column
  on the table otherwise breaks the query ("more than one relationship").
- Generic helpers come from `jopen-utils.js` — never copy them into a page.
  A helper needed on a second page moves to `jopen-utils.js`.
- A calculation needed in more than one place becomes its own module with a
  Node test in `tests/` (pattern: `waterzouten.js`, `brew-calculations.js`). Browser + Node export:
  `if (typeof module !== 'undefined' && module.exports) module.exports = {…}`.
- Excel batch report: patch XML via `xlsx-direct.js`; never load/save the
  template with ExcelJS. `batchrapport-vullen.js` has its own browser copy of
  the writer — change both.

## Branches and pull requests
- `main` is protected (security phase 2, 20-11-2026): never push to `main`.
  Every change goes on its own branch with a pull request; Jaap merges after
  the Guard check is green. A merge to `main` deploys (GitHub Pages and the
  Supabase migrations), so the pull request is the review moment.

## Before every push
- `node --check` on every changed `.js` file and on the extracted inline
  scripts of changed `.html` pages.
- Run `node tests/*.test.js` and `python3 tools/ci_guard.py` (the Guard
  workflow runs both on every push; a red Guard means fix before merging).
- For behaviour changes: jsdom test, with data injection and the call in one
  `window.eval(script + testCode)` (separate evals do not share `let`/`const`).
- Commit as `git -c user.name="Claude" -c user.email="noreply@anthropic.com" commit`;
  rebase on `origin/main` if someone pushed in between.

## GitHub Actions
- Every `uses:` is pinned to a full commit SHA with the version as a comment
  (`actions/checkout@<sha> # v5.1.0`); Guard fails otherwise. Dependabot
  opens pull requests for new releases (security phase 7).
- A job that holds a secret gets `contents: read`; a job that writes to the
  repo gets no secrets (see `schema-snapshot.yml`).

## Secrets
- Session PATs are revoked by Jaap after each session. Automation secrets
  (`BACKUP_REPO_PAT`, `SUPABASE_DB_URL`, …) live in the GitHub Actions
  environment `production`, which only `main` may use (security phase 3) —
  never in the repo, never as repository-level secrets, never revoked as part
  of a session. A job that needs one declares `environment: production`.
