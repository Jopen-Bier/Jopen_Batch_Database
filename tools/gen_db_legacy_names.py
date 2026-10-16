import json,sys
m=json.load(open('supabase/rename-map.json'))['tables']
domains=sys.argv[1].split(',')
tabs={}
for old,v in m.items():
    if v['domain'] not in domains or v['kind']!='tabel': continue
    cols={k:x for k,x in v['columns'].items() if x not in ('drop',k) and '+' not in x}
    if cols: tabs[v['name']]=cols
body=json.dumps(tabs,indent=2,ensure_ascii=False,sort_keys=True)
print(f"""// ============================================================================
// db-legacy-names.js — translation layer between old (Dutch) JS property
// names and the English database columns, for code that has not been
// translated yet. GENERATED from supabase/rename-map.json — do not edit by hand.
//
// Reading: queries alias columns in the select string (`naam:name`), so the
// page keeps receiving the old property names.
// Writing: wrap a payload with toDb('<table>', row) to rename its keys.
//
//   supabaseClient.from('ingredients').update(toDb('ingredients', basis))
//
// When a page is translated to English, its toDb()/alias use goes away.
// Domains covered: {', '.join(domains)}.
// ============================================================================

const DB_LEGACY_COLUMNS = {body};

/** Copy of `row` with old (Dutch) keys renamed to the English columns of `table`. */
function toDb(table, row) {{
  const map = DB_LEGACY_COLUMNS[table];
  if (!map) throw new Error('toDb: unknown table ' + table);
  const out = {{}};
  for (const [k, v] of Object.entries(row)) out[map[k] || k] = v;
  return out;
}}

if (typeof module !== 'undefined' && module.exports) {{
  module.exports = {{ toDb, DB_LEGACY_COLUMNS }};
}}""")
