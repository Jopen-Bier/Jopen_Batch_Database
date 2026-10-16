import json,sys
m=json.load(open('supabase/rename-map.json'))['tables']
domains=sys.argv[1].split(',')
tabs={}
for old,v in m.items():
    if v['domain'] not in domains or v['kind']!='tabel': continue
    cols={k:x for k,x in v['columns'].items() if x not in ('drop',k) and '+' not in x}
    tabs[v['name']]=cols  # also tables without renames, so toDb/fromDb accept them
body=json.dumps(tabs,indent=2,ensure_ascii=False,sort_keys=True)
print(f"""// ============================================================================
// db-legacy-names.js — translation layer between old (Dutch) JS property
// names and the English database columns, for code that has not been
// translated yet. GENERATED from supabase/rename-map.json — do not edit by hand.
//
// Reading: queries alias columns in the select string (`naam:name`), so the
// page keeps receiving the old property names.
// Writing: wrap a payload with toDb('<table>', row) to rename its keys.
// Reading whole rows (select('*')): fromDb('<table>', row) renames the
// English keys back to the old ones (columns without an old name keep
// their English key).
//
//   supabaseClient.from('ingredients').update(toDb('ingredients', basis))
//   const legacyRow = fromDb('recipes', data)
//   supabaseClient.from('recipes').select('*').then(r => fromDbResult('recipes', r))
//
// When a page is translated to English, its toDb()/alias use goes away.
// Domains covered: {', '.join(domains)}.
// ============================================================================

const DB_LEGACY_COLUMNS = {body};

/** Copy of `row` (or of each row in an array) with old (Dutch) keys renamed to the English columns of `table`. */
function toDb(table, row) {{
  const map = DB_LEGACY_COLUMNS[table];
  if (!map) throw new Error('toDb: unknown table ' + table);
  if (Array.isArray(row)) return row.map(r => toDb(table, r));
  const out = {{}};
  for (const [k, v] of Object.entries(row)) out[map[k] || k] = v;
  return out;
}}

/** Copy of `row` with English column keys of `table` renamed to the old (Dutch) keys. null stays null. */
function fromDb(table, row) {{
  const map = DB_LEGACY_COLUMNS[table];
  if (!map) throw new Error('fromDb: unknown table ' + table);
  if (row === null || row === undefined) return row;
  const inverse = {{}};
  for (const [oldKey, newKey] of Object.entries(map)) inverse[newKey] = oldKey;
  const out = {{}};
  for (const [k, v] of Object.entries(row)) out[inverse[k] || k] = v;
  return out;
}}

/**
 * Applies fromDb() to a Supabase result ({{ data, error }}) — data may be one
 * row, an array of rows or null. For use as `.then(r => fromDbResult('recipes', r))`.
 */
function fromDbResult(table, result) {{
  if (!DB_LEGACY_COLUMNS[table]) throw new Error('fromDbResult: unknown table ' + table);
  if (result && result.data) {{
    result.data = Array.isArray(result.data) ? result.data.map(r => fromDb(table, r)) : fromDb(table, result.data);
  }}
  return result;
}}

if (typeof module !== 'undefined' && module.exports) {{
  module.exports = {{ toDb, fromDb, fromDbResult, DB_LEGACY_COLUMNS }};
}}""")
