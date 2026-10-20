# Architecture — Jopen Batch Database

The map of this system. Read it before adding a page, a table or a new app on
the same database. The hard rules are summarised in `CLAUDE.md`.

> **State (18 Oct 2026).** The database is fully English: every table,
> column, view, function and value code (renamed in four steps — core,
> inventory, recipe, production — per `supabase/rename-map.json`). Older
> page code is still partly Dutch and reaches the database through the
> translation layer (§6a); pages are translated one by one when they are
> substantially reworked (§7). Everything **new** follows the conventions
> below; the Guard workflow (§6) checks the naming of new migrations.

---

## 1. What it is

A brewery management web app for Jopen (≈15 users), replacing the Excel/VBA
workflow around `Moederdata.xlsm`: recipes, ingredients, product sheets,
brew planning, consumption forecast, inventory (lots + ledger), batch
creation with Excel batch-report generation, users and roles.

| Layer | Technology |
|---|---|
| Frontend | Plain HTML + vanilla JS, one file per page, no build step. Hosted on GitHub Pages from this repo. |
| Backend | Supabase (Postgres 17, eu-central-1): Auth, RLS, Edge Functions, Storage. |
| Excel output | `xlsx-direct.js` (JSZip + raw XML patching). ExcelJS only for simple new exports, never to load/save existing templates. |
| Automation | GitHub Actions: guard on every push, nightly backup + restore check, weekly restore test, nightly schema snapshot. |

UI language: **English**. Database names and new code: **English**
(older code is still partly Dutch — see §7).

---

## 2. Repository layout

```
*.html                     one page per screen (see §4)
config.js                  Supabase client + auth helpers — loaded on EVERY page
nav.js                     navigation, login guard, permission helpers — EVERY page
jopen-shared.css           shared styles
jopen-utils.js             shared generic helpers (escapeHtml, fetchAllRows, …)
db-legacy-names.js         translation layer for not-yet-translated pages (generated; §6a)
waterzouten.js             water-salts calculation (shared module, has a test)
brew-calculations.js       hop utilization, EBU, malt color (shared module, has a test)
recipe-values.js           recipe value lists (codes -> labels, colours, report text; has a test)
batch-stages.js            batch stages + list logic of the batch-report pages (has a test)
batch-ingredients.js       ingredient snapshot per batch: batch amounts, deviations (has a test)
batch-brews.js             brew log rows and calculations (evaporation, GLT volume/extract; has a test)
fermentation-log.js        fermentation log: days, gap days, cellar plan progress, ADF/ABV, calculators (has a test)
recipe-cellar-plan.js      cellar plan block of the recipe editor (recipe_cellar_steps)
batch-report-shell.js      shared frame of the batch tabs: header, tabs, autosave, confirm dialog, undo toast
batch-report.css           shared styles of the batch-report screens (load after jopen-shared.css)
voorraad-forecast.js       consumption calculation (shared module)
productsheet-*.js          product-sheet generation (browser)
batchrapport-vullen.js     batch report generation (browser)
batchrapport-generator/    Node version of the batch report generator + template
productsheet-generator/    Node test harness for product sheets
batchrapport_cel_mapping.csv  Excel cell ↔ database field mapping for the batch report
supabase/
  migrations/              every schema change, in order (see §5.4)
  schema.sql               full structure dump, refreshed nightly = the baseline
  rename-map.json          agreed Dutch → English names (transition source of truth)
  functions/               Edge Functions (generate-invite-link, delete-user)
docs/batch-report/         brief for the digital batch report (decisions, data model, rules, screens, phases, mockup)
tests/                     Node tests for shared modules (run by the Guard workflow)
tools/                     translation-layer scripts + ci_guard.py (see tools/README.md)
.github/workflows/         guard, backup, restore test, schema snapshot
.github/backup/            backup/restore scripts + RESTORE.md
```

### Script order on every page
```html
<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
<script src="config.js"></script>
<script src="jopen-utils.js"></script>
<script src="nav.js"></script>
<!-- then page-specific shared modules, then the page's own <script> -->
```

---

## 3. Database

### 3.1 Schemas

| Schema | Contains |
|---|---|
| `public` | **The brewery app** and the shared master data: users, roles, permissions, units, document types, ingredients, inventory, recipes, product sheets, planning, batches. |
| `qa`, `sensory`, `kpi`, … | **Separate apps** on the same database (future). One schema per app. |

Why the brewery app stays in one schema: its domains are tightly linked
(batch → recipe → ingredients → lots → users) and the Supabase Data API
(PostgREST) only embeds related tables **within the schema of the query**.
Splitting the brewery app over schemas would break those joins. The real
gain of schemas is separating *apps*, so that is where they are used.

Domains inside `public` are recognisable by table name (`recipe_*`,
`ingredient_*`, `brew_planning_*`, …) and by the grouping in §4 and
`supabase/rename-map.json`.

Rules for a new app schema:
- It owns its own tables; it never puts tables in `public` or in another
  app's schema.
- It references shared data in `public` by foreign key (users, ingredients,
  recipes, batches, …) — never copies it.
- When it needs shared data in a single query (embedding), it defines
  **explicit read views in its own schema** (e.g. `qa.users` as
  `select id, name from public.users`). That list of views is the app's
  documented dependency on the brewery app.
- Add the schema under Supabase → Project Settings → Data API →
  *Exposed schemas* and grant it (`grant usage on schema x to authenticated`
  + table grants), otherwise the frontend cannot reach it.
- Frontend access: `supabaseClient.schema('qa').from('actions')`.
- The backup picks up new schemas automatically
  (`.github/backup/eigen_schemas.sql` uses an exclusion list).

### 3.2 Naming conventions

| What | Convention | Example |
|---|---|---|
| Language | English, `snake_case`, US spelling | `color`, `utilization` |
| Main table | plural noun | `recipes`, `lots` |
| Child table | parent singular as prefix | `recipe_water`, `ingredient_documents` |
| Primary key | `id` | |
| Foreign key | `<entity>_id` | `recipe_id`, `lot_id` |
| Timestamps | `created_at`, `updated_at` (`timestamptz`) | |
| Who | `created_by`, `updated_by` → `public.users(id)` | |
| Booleans | `is_` / `has_` where it reads naturally | `is_active`, `is_spoilage` |
| Units in name | suffix | `_pct`, `_hl`, `_kg`, `_min`, `_g` |
| Tolerances | `_tol` suffix next to the value column | `ph`, `ph_tol` |
| Version snapshots | table suffix `_revisions` | `recipe_revisions` |
| Change logs | table suffix `_history` | `brew_planning_history` |
| Status / type values | lowercase English codes, label in the UI | `planned`, `consumption`, `wp` |
| Abbreviations | keep plant abbreviations, lowercase | `hbt`, `glt`, `ckt`, `wp`, `jk` |

Never two columns that mean the same thing (e.g. `created_at` next to
`aangemaakt_op`, or the same field in two tables). One field, one home.

### 3.3 Glossary (Dutch → English)

Use these terms in table names, column names, code and UI labels.

| Domain | Dutch | English |
|---|---|---|
| Brewing | brouwsel | brew (`brew_count` = aantal brouwsels) |
| Brewing | brouwhuis | brewhouse |
| Brewing | maischen / beslag | mash |
| Brewing | inmaischen / uitmaischen | mash in / mash out |
| Brewing | maischrust (verhogen 1–4) | mash step 1–4 |
| Brewing | spoelen / spoelwater | sparge / sparge water |
| Brewing | eerste afloop | first wort |
| Brewing | filtreren (maischfilter) | lauter (mash filter) |
| Brewing | koken / verdamping | boil / evaporation |
| Brewing | stamwort | original gravity (°P) |
| Brewing | origineel extract / restextract | original extract / final extract |
| Brewing | wortvoorkoeler | wort pre-cooler |
| Brewing | walsenmolen | roller mill |
| Brewing | beluchting | aeration |
| Ingredients | grondstof / ingrediënt | ingredient |
| Ingredients | hoofdmout | malt |
| Ingredients | hopgift (kook) | boil hop |
| Ingredients | toegift brouwerij / kelder | brewhouse / cellar addition |
| Ingredients | gist / giststam / enten | yeast / yeast strain / pitch |
| Ingredients | HDT | hop dosing tank |
| Ingredients | houdbaarheid / THT | shelf life / best before |
| Inventory | voorraad / voorraadmutatie | stock / stock movement |
| Inventory | ontvangst / uitboeking | receipt / consumption |
| Inventory | ontvangstcontrole / ingangscontrole | receiving check / incoming inspection |
| Inventory | lot / lotcode / leverancier | lot / lot code / supplier |
| Cellar | vergisting / gistkaart | fermentation / fermentation log |
| Cellar | lageren | lagering |
| Cellar | kelder | cellar |
| Cellar | splitsing / overdracht / mengen | split / transfer / blend |
| Cellar | troebeling | turbidity |
| Cellar | GLT / LT / CKT / HBT (tanks) | `glt` / `lt` / `ckt` / `hbt` (plant abbreviations; HBT = helderbiertank, bright beer tank) |
| Cellar | Time 0 (laatste brouwsel in tank) | time zero (`time_zero`) |
| Cellar | kelderplan / actietag | cellar plan / action tag |
| Batch report | afwijking (van recept) | deviation |
| Processing | verwerking | processing |
| Filling | afvullen / afvulverslag | filling / filling report |
| Filling | fles / blik / fust | bottle / can / keg |
| Filling | vat (hout) | barrel (not VAT) |
| General | paraaf | initials |
| General | revisie / historie | revision / history |
| General | tolerantie | tolerance (`_tol`) |

Agreed table and column names per table: `supabase/rename-map.json`.

### 3.4 Permissions (RLS)

- Every table has RLS on. Policies call the helper functions
  `can_view(module)`, `can_edit(module)`, `can_delete(module)`, which read
  `role_permissions` for the role of the current user (`current_role_id()`).
  `is_admin()` = active user whose role is named `admin`; admins may do
  everything.
- A **permission module** (`permission_modules.module_key`) groups tables that
  belong to one screen/function, e.g. `recipes`, `ingredients`, `inventory`.
  Roles get view/edit/delete per module in the role matrix (`rollen.html`).
- **DELETE must be allowed wherever EDIT is**, per role. A mismatch makes
  deletes silently do nothing (Supabase reports success, 0 rows).
- Reference tables that feed dropdowns everywhere (units, categories, …):
  read open to all logged-in users, write via the matrix.
- Frontend: `getCurrentUser()` (in `config.js`) returns
  `{ id, name, roleId, roleName, isActive, isAdmin }`;
  `magBekijkenModule / magBewerkenModule / magVerwijderenModule` (in `nav.js`)
  hide or disable controls. The UI is a convenience; RLS is the real guard.
- Users, user roles and the status page are admin-only (`isAdmin`).

---

## 4. Pages

| Page | Permission module | Main tables / views |
|---|---|---|
| `index.html` | — (tiles per module) | |
| `login.html`, `accept-invite.html` | — | auth only |
| `recept-invoer.html` | recipes | recipes, recipe_* (brewing_specs, fermentation, water, ingredients, costs, process_steps, specs, packaging, comments, revisions), ingredients, units, water_settings. Ingredient lines are saved with `save_recipe_ingredients()` (one transaction; existing lines keep their id); the cellar plan (`recipe_cellar_steps`, via `recipe-cellar-plan.js`) with `save_recipe_cellar_steps()`, which regenerates it |
| `receptoverzicht.html` | recipes | recipes, recipe_*, product_sheet_status (view), batches |
| `ingredienten.html` | ingredients | ingredients, ingredient_categories, ingredient_documents, ingredient_revisions, ingredient_declarations, ingredient_usage_counts (view), document_types, recipe_ingredients, units |
| `productsheet.html`, `productsheet-invoer.html` | product_sheets | product_sheets, product_sheet_revisions, product_sheet_status (view), recipes |
| `brouwplanning.html` | brewing_planning | brew_planning, brew_planning_splits, brew_capacity, brew_planning_history_detailed (view), recipes, users |
| `verbruiksprognose.html` | brewing_planning (via menu) | ingredients, brew_planning, recipe_ingredients (via `voorraad-forecast.js`) |
| `batchcreation.html` | batches | batches, recipes, recipe_fermentation (+ batch report via `batchrapport-vullen.js`) |
| `all-batches.html` | batches | batches, recipes, batch_stages (view) |
| `active-batches.html` | batches | batches, recipes, tanks, batch_stages (view) |
| `batch-fermentation.html` | batches | batches, batch_cellar_steps (`snapshot_batch_cellar_steps()`), fermentation_log_entries, fermentation_log_entry_tags, cellar_action_tags, batch_transfers, batch_brews, batch_ingredients, tanks, users, recipe_specs/_fermentation |
| `batch-brewing.html` | batches | batches, batch_brews, batch_brew_comments, batch_ingredients, tanks, users, recipe_brewing_specs/_specs/_fermentation/_comments |
| `batch-overview.html` | batches | batches, batch_ingredients, `snapshot_batch_ingredients()`, recipes + recipe_specs/_fermentation/_brewing_specs/_packaging/_water/_revisions, ingredients, stock_movements, lots |
| `voorraad-overzicht/inboeken/uitboeken.html` | inventory | lots, stock_movements, ingredients, batches, users |
| `statistics.html` | statistics | ingredients, ingredient_documents, document_types |
| `settings.html` | settings | units, ingredient_categories, document_types, ingredient_declarations, water_settings (+ _history), cellar_action_tags, cellar_plan_parts (`apply_cellar_plan_order()`), recipe_ingredients (count) |
| `gebruikers.html` | admin only (`user_management`) | users, roles, `admin_get_last_logins()` |
| `rollen.html` | admin only (`role_management`) | roles, role_permissions, permission_modules |
| `status.html` | admin only | counts on batches, recipes, ingredients, users |

---

## 5. How to change things

### 5.1 New page
1. Standard script order (§2). Call `initJopenNav()`.
2. Pick an existing permission module or add one (§5.3).
3. Use helpers from `jopen-utils.js`; do not copy them into the page.
4. Calculations that another page or app may need → a separate module with
   a test (see `waterzouten.js` + `tests/waterzouten.test.js`).
5. Styles: reuse `jopen-shared.css`; page-specific CSS only for what is
   really unique.
6. Add the page to the table in §4.

### 5.2 New table or column
1. Brewery app: `public`; separate app: its own schema (§3.1). Names per §3.2 and the glossary.
2. Migration file in `supabase/migrations/` (§5.4), idempotent where possible.
3. RLS on, policies via the permission helpers, DELETE consistent with EDIT.
4. Check it does not duplicate an existing field.

### 5.3 New app on the same database
1. New schema (§3.1), exposed in the Data API and granted.
2. Users and roles come from `public`; add permission modules for the new app.
   Read views on shared data live in the app's own schema (§3.1).
3. Shared master data (ingredients, …) by foreign key — never copied.
4. Own HTML pages (or repo) but the same `config.js` pattern and helpers.
5. Add a section to this file.

### 5.4 Database changes (migrations)
- `supabase/migrations/` is **followed by Supabase's GitHub integration: a
  new file there is executed on production when pushed to `main`.**
- Additive changes may go that way. Destructive changes (DROP, data
  rewrites) are reviewed with Jaap first.
- When a change is run by hand in the SQL Editor (needed while the MCP
  connector cannot run destructive DDL): register the version in
  `supabase_migrations.schema_migrations` **before** pushing the file, so the
  integration skips it. Details: `supabase/migrations/README.md`.
- Never put a baseline/full dump in `migrations/`. The baseline is
  `supabase/schema.sql`.
- Bulk or risky data changes: dry run with `BEGIN … ROLLBACK` first; Jaap
  reviews proposed changes in a spreadsheet.
- Always check the live schema (`information_schema`, `pg_policies`) before
  changing anything; do not trust docs or old summaries.

---

## 6. Safety nets

| What | Where |
|---|---|
| Nightly database backup + trial restore | `.github/workflows/daily-backup.yml` → private `Jopen_Database_Backup` |
| Nightly storage mirror | same workflow → private `Jopen_Storage_Backup` |
| Weekly restore test | `.github/workflows/restore-test.yml` |
| Guard on every push / PR | `.github/workflows/guard.yml` → `tools/ci_guard.py` (no copies of `jopen-utils.js` / `brew-calculations.js` functions; snake_case English names in new migrations, with `-- naming-ok: <name>` for a deliberate exception), `node --check`, `tests/*.test.js` |
| Drift detection | `.github/workflows/schema-snapshot.yml` → `supabase/schema.sql`; a commit "Schema gewijzigd" without a matching migration = drift |
| Restore manual | `.github/backup/RESTORE.md` |

---

## 6a. Translation layer (until every page is translated)

The database is English; a lot of page code is still Dutch. Instead of
rewriting every page at once, the boundary between the two is the query:

- **Reading:** select strings alias English columns to the old property
  name, so the page logic is untouched:
  `.from('lots').select('id, lotcode:lot_code, eenheid:unit')`.
  Renamed embedded tables are aliased the same way:
  `grondstof_lots:lots(lotcode:lot_code)`.
- **Whole rows** (`select('*')`, or the row returned by `.insert().select()`):
  rename the result back with `fromDb('<table>', row)` or, inside a
  `Promise.all`, `.then(r => fromDbResult('<table>', r))`. Columns that
  never had a Dutch name (e.g. `brewhouse_recipe_name_wp`) keep their
  English key.
- **Filters / order:** always the English column and English values:
  `.eq('version_status', 'current')`.
- **Writing:** payloads built with Dutch keys go through
  `toDb('<table>', row)` from `db-legacy-names.js` (generated from
  `supabase/rename-map.json`; load it on pages that write).
- **Status values** are English codes everywhere (data, filters,
  comparisons). Batch status: planned/brewing/fermenting/processing/filling/
  completed. Users see labels; the recipe value lists and their labels
  live in `recipe-values.js` (location, status, addition type, beer
  risk/status). The Excel batch report still gets the Dutch beer risk/status
  text, because the template's conditional formatting matches on it.
- **JSON snapshots** (`brew_planning_history.before/after`,
  `product_sheets.sync_snapshot`, `water_settings_history.data`) use the
  English column names as keys; read them with those keys, not via aliases.
- When a page is translated to English, its aliases and `toDb()`/`fromDb()`
  calls go away. Search for `toDb(`, `fromDb` and `:` aliases to find what is
  left.
- New code never uses the layer: English names end to end.

## 7. Language of code

- **New code is English**: identifiers, comments, commit messages.
- Existing Dutch code stays until it is substantially reworked. When a large
  part of a page or block is being changed, ask Jaap whether to translate
  that whole block in the same go.
- UI labels are English. A doubtful translation is always checked with Jaap.
