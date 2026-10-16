# Architecture — Jopen Batch Database

The map of this system. Read it before adding a page, a table or a new app on
the same database. The hard rules are summarised in `CLAUDE.md`.

> **Transition in progress (Oct 2026).** The database is being moved from one
> Dutch-named `public` schema to English names in domain schemas
> (see *Database* below and `supabase/rename-map.json`). Until a domain has
> been migrated, its tables still live in `public` under their old Dutch
> names. Everything **new** follows the target conventions below.

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
| Automation | GitHub Actions: nightly backup + restore check, weekly restore test, nightly schema snapshot. |

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
waterzouten.js             water-salts calculation (shared module, has a test)
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
tests/                     Node tests for shared modules
.github/workflows/         backup, restore test, schema snapshot
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

### 3.1 Schemas (target)

| Schema | Owns | Shared? |
|---|---|---|
| `core` | users, roles, role_permissions, permission_modules, units, document_types, permission functions | Used by every app |
| `inventory` | ingredients (master data), ingredient_categories/revisions/documents/declarations, lots, stock_movements | Used by recipe, production, future QA |
| `recipe` | recipes + `recipe_*`, product_sheets, product_sheet_revisions, hop_utilization_curve, water_settings | |
| `production` | batches, brew_planning (+ splits, history), brew_capacity; later the digital batch report tables | |
| `qa`, `sensory`, `kpi` | future apps | |

Rules:
- **A new app gets its own schema.** It may reference `core` and `inventory`
  with foreign keys; it does not put tables in another app's schema.
- Cross-domain read models (dashboards) are views in the schema of the app
  that uses them.
- `public` ends up empty except for temporary pass-through views during the
  transition.
- New schemas are picked up by the backup automatically
  (`.github/backup/eigen_schemas.sql` uses an exclusion list).
- A new schema must be added under Supabase → Project Settings → Data API →
  *Exposed schemas*, and granted (`grant usage on schema x to authenticated`
  plus table grants), otherwise the frontend cannot see it.
- Frontend access: `supabaseClient.schema('recipe').from('recipes')`.

### 3.2 Naming conventions

| What | Convention | Example |
|---|---|---|
| Language | English, `snake_case`, US spelling | `color`, `utilization` |
| Main table | plural noun | `recipes`, `lots` |
| Child table | parent singular as prefix | `recipe_water`, `ingredient_documents` |
| Primary key | `id` | |
| Foreign key | `<entity>_id` | `recipe_id`, `lot_id` |
| Timestamps | `created_at`, `updated_at` (`timestamptz`) | |
| Who | `created_by`, `updated_by` → `core.users(id)` | |
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
| Processing | verwerking | processing |
| Filling | afvullen / afvulverslag | filling / filling report |
| Filling | fles / blik / fust | bottle / can / keg |
| Filling | vat (hout) | barrel (not VAT) |
| General | paraaf | initials |
| General | revisie / historie | revision / history |
| General | tolerantie | tolerance (`_tol`) |

Agreed table and column names per table: `supabase/rename-map.json`.

### 3.4 Permissions (RLS)

- Every table has RLS on. Policies call the generic helper functions
  `mag_bekijken(module)`, `mag_bewerken(module)`, `mag_verwijderen(module)`
  (to be renamed/moved to `core` in the transition), which read
  `role_permissions` for the user's role.
- A **permission module** (`permission_modules.module_key`) groups tables that
  belong to one screen/function, e.g. `recipes`, `ingredients`, `inventory`.
  Roles get view/edit/delete per module in the role matrix (`rollen.html`).
- **DELETE must be allowed wherever EDIT is**, per role. A mismatch makes
  deletes silently do nothing (Supabase reports success, 0 rows).
- Reference tables that feed dropdowns everywhere (units, categories, …):
  read open to all logged-in users, write via the matrix.
- Frontend: `magBekijkenModule / magBewerkenModule / magVerwijderenModule`
  (in `nav.js`) hide or disable controls. The UI is a convenience; RLS is the
  real guard.

---

## 4. Pages

| Page | Permission module | Main tables (current names) |
|---|---|---|
| `index.html` | — (tiles per module) | |
| `login.html`, `accept-invite.html` | — | auth |
| `recept-invoer.html` | recipes | recipes, recipe_*, water_instellingen, eenheden |
| `receptoverzicht.html` | recipes | recipes, recipe_*, product_sheet_status, batches |
| `ingredienten.html` | ingredients | ingredients + ingredient_*, document_typen |
| `productsheet.html`, `productsheet-invoer.html` | product_sheets | product_sheets, product_sheet_revisies |
| `brouwplanning.html` | brewing_planning | brew_planning (+ splits, history), brew_capacity |
| `verbruiksprognose.html` | brewing_planning (via menu) | ingredients (+ voorraad-forecast.js) |
| `batchcreation.html` | batches | batches, recipes |
| `voorraad-overzicht/inboeken/uitboeken.html` | inventory | grondstof_lots, voorraad_mutaties |
| `statistics.html` | statistics | ingredients, ingredient_documenten |
| `settings.html` | settings | reference tables, water_instellingen |
| `gebruikers.html` | admin only (hardcoded check on `gebruikers.rol`) | gebruikers, roles |
| `rollen.html` | admin only | roles, role_permissions, permission_modules |
| `status.html` | admin only (hardcoded check on `gebruikers.rol`) | counts |

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
1. Right schema (§3.1), names per §3.2 and the glossary.
2. Migration file in `supabase/migrations/` (§5.4), idempotent where possible.
3. RLS on, policies via the permission helpers, DELETE consistent with EDIT.
4. Check it does not duplicate an existing field.

### 5.3 New app on the same database
1. New schema (§3.1), exposed in the Data API and granted.
2. Users and roles come from `core`; add permission modules for the new app.
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
| Drift detection | `.github/workflows/schema-snapshot.yml` → `supabase/schema.sql`; a commit "Schema gewijzigd" without a matching migration = drift |
| Restore manual | `.github/backup/RESTORE.md` |

---

## 7. Language of code

- **New code is English**: identifiers, comments, commit messages.
- Existing Dutch code stays until it is substantially reworked. When a large
  part of a page or block is being changed, ask Jaap whether to translate
  that whole block in the same go.
- UI labels are English. A doubtful translation is always checked with Jaap.
