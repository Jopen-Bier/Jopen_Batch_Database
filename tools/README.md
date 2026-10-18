# tools/

Helpers for the Dutch → English database transition (see `ARCHITECTURE.md` §6a).
Run from the repo root.

| Script | What it does |
|---|---|
| `gen_db_legacy_names.py <domains>` | Generates `db-legacy-names.js` (`toDb`, `fromDb`, `fromDbResult`) from `supabase/rename-map.json` for the given domains (comma-separated, e.g. `inventory,recipe`). `python3 tools/gen_db_legacy_names.py inventory,recipe > db-legacy-names.js` |
| `query_translation_layer.py <old tables> <files…>` | Rewrites query chains on renamed tables: table names, aliased selects (`naam:name`), filter columns. Prints what needs a manual look (payloads, `select('*')`, dropped columns). Values are not touched. |
| `wrap_payloads_todb.py <new tables> <files…>` | Wraps insert/update/upsert payloads on those tables with `toDb('<table>', …)`. |
| `check_query_columns.py <columns.txt> <tables> <files…>` | Static check that every selected, filtered and written column exists. `columns.txt` = `table.column` per line, e.g. from `select table_name\|\|'.'\|\|column_name from information_schema.columns where table_schema='public'` on a migrated copy. |
| `ci_guard.py` | Run by `.github/workflows/guard.yml` on every push. Fails on own copies of functions from `jopen-utils.js` or `brew-calculations.js` in pages/scripts, and on Dutch or non-`snake_case` names created or renamed in migrations newer than step 9 (`NAMING_BASELINE`). Exemption: `-- naming-ok: <name>` in the migration. `python3 tools/ci_guard.py` |
