"""Query translation layer: rewrite Supabase query chains for renamed tables.

For every .from('<old table>') chain in the given files:
  - table name -> new name
  - .select('...') columns -> aliased  `old:new`  (JS keeps the old property names)
  - embedded relations -> renamed + aliased to the old key, recursively
  - filter/order column arguments -> new column name
Embedded relations of renamed tables inside other chains are rewritten too.
Insert/update payloads and value literals are NOT touched (done by hand).
Prints a report of everything that needs a manual look.
"""
import json, re, sys

MAP = json.load(open('supabase/rename-map.json'))['tables']
DOMAIN_TABLES = sys.argv[1].split(',')
FILES = sys.argv[2:]

def colmap(t):
    return {k: v for k, v in MAP[t]['columns'].items()}

# old/new table names known to the layer (only for this domain)
REN = {t: MAP[t]['name'] for t in DOMAIN_TABLES}
NEW2OLD = {v: k for k, v in REN.items()}
report = []
# FK constraint names used as embed hints (!fk) that were renamed
HINTS = {
  'voorraad_mutaties_aangemaakt_door_fkey': 'stock_movements_created_by_fkey',
  'voorraad_mutaties_geboekt_door_fkey': 'stock_movements_booked_by_fkey',
}

def split_top(s):
    parts, d, cur = [], 0, ''
    for ch in s:
        if ch == '(':
            d += 1
        elif ch == ')':
            d -= 1
        if ch == ',' and d == 0:
            parts.append(cur); cur = ''
        else:
            cur += ch
    if cur.strip():
        parts.append(cur)
    return parts

def transform_select(sel, table, where):
    """table = old table name of the level (None = not in this domain: leave columns)."""
    out = []
    for raw in split_top(sel):
        lead = raw[:len(raw) - len(raw.lstrip())]
        tok = raw.strip()
        m = re.match(r'^(?:(\w+):)?(\w+)(!\w+)?\((.*)\)$', tok, re.S)
        if m:  # embedded relation
            alias, rel, hint, inner = m.group(1), m.group(2), m.group(3) or '', m.group(4)
            if hint and hint[1:] in HINTS: hint = '!' + HINTS[hint[1:]]
            rel_old = NEW2OLD.get(rel, rel)
            inner_t = rel_old if rel_old in DOMAIN_TABLES else None
            new_inner = transform_select(inner, inner_t, where) if inner_t else inner
            if rel_old in REN and REN[rel_old] != rel_old:
                key = alias or rel_old
                tok = f"{key}:{REN[rel_old]}{hint}({new_inner})"
            else:
                tok = (f"{alias}:" if alias else '') + f"{rel}{hint}({new_inner})"
            out.append(lead + tok)
            continue
        if table is None:
            out.append(raw); continue
        cm = colmap(table)
        m = re.match(r'^(?:(\w+):)?(\w+)$', tok)
        if not m:
            if tok == '*':
                report.append(f"{where}: select('*') on {table} -> must be expanded by hand")
            out.append(raw); continue
        alias, col = m.group(1), m.group(2)
        new = cm.get(col, col)
        if new == 'drop':
            report.append(f"{where}: column {table}.{col} is dropped -> removed from select")
            continue
        if new == col:
            out.append(raw)
        else:
            out.append(lead + f"{alias or col}:{new}")
    return ','.join(out)

FILTERS = r"(eq|neq|gt|gte|lt|lte|like|ilike|is|in|not|order|contains|containedBy|match)"

def process_chain(chain, table, where):
    cm = colmap(table)
    # table name
    chain = re.sub(r"\.from\(\s*'" + table + r"'\s*\)", f".from('{REN[table]}')", chain, count=1)
    # selects (string or template literal)
    def sel_sub(m):
        q, body = m.group(1), m.group(2)
        return f".select({q}{transform_select(body, table, where)}{q}"
    chain = re.sub(r"\.select\(\s*(['`])(.*?)\1", sel_sub, chain, flags=re.S)
    # filters / order on root columns
    def f_sub(m):
        fn, col = m.group(1), m.group(2)
        new = cm.get(col, col)
        if new == 'drop':
            report.append(f"{where}: filter on dropped column {table}.{col}")
            return m.group(0)
        return f".{fn}('{new}'"
    chain = re.sub(r"\." + FILTERS + r"\(\s*'(\w+)'", f_sub, chain)
    # payloads to check by hand
    if re.search(r"\.(insert|update|upsert)\(", chain):
        report.append(f"{where}: insert/update on {table} -> check payload keys and values by hand")
    return chain

for f in FILES:
    s = open(f, encoding='utf-8').read()
    orig = s
    # 1. chains rooted at a domain table
    pos = 0
    while True:
        m = re.search(r"\.from\(\s*'(" + '|'.join(DOMAIN_TABLES) + r")'\s*\)", s[pos:])
        if not m:
            break
        i = pos + m.start(); table = m.group(1)
        d, j = 0, i
        while j < len(s):
            c = s[j]
            if c in '([{': d += 1
            elif c in ')]}':
                d -= 1
                if d < 0: break
            elif c in ';,' and d == 0: break
            j += 1
        line = s.count('\n', 0, i) + 1
        new = process_chain(s[i:j], table, f"{f}:{line}")
        s = s[:i] + new + s[j:]
        pos = i + len(new)
    # 2. embedded domain relations inside other chains' selects
    def other_sel(m):
        q, body = m.group(1), m.group(2)
        if not re.search(r"\b(" + '|'.join(DOMAIN_TABLES) + r")(!\w+)?\(", body):
            return m.group(0)
        line = s.count('\n', 0, m.start()) + 1
        return f".select({q}{transform_select(body, None, f'{f}:{line}')}{q}"
    s = re.sub(r"\.select\(\s*(['`])(.*?)\1", other_sel, s, flags=re.S)
    if s != orig:
        open(f, 'w', encoding='utf-8').write(s)
        print('rewrote', f)

print('\n'.join(sorted(set(report))))
