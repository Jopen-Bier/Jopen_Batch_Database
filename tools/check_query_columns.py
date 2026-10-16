"""Static check: every column referenced in queries on the given tables exists in the schema."""
import re, sys, glob, json
COLS = {}
for line in open(sys.argv[1]):
    t, c = line.strip().split('.', 1); COLS.setdefault(t, set()).add(c)
TABLES = sys.argv[2].split(',')
files = sys.argv[3:]

import subprocess
legacy = json.loads(subprocess.run(['node', '-e', "process.stdout.write(JSON.stringify(require('./db-legacy-names.js').DB_LEGACY_COLUMNS))"], capture_output=True, text=True).stdout)
# FK -> target table for embeds (relation name = table name or alias:table!fk)
problems = []
def split_top(s):
    parts, d, cur = [], 0, ''
    for ch in s:
        if ch == '(': d += 1
        elif ch == ')': d -= 1
        if ch == ',' and d == 0: parts.append(cur); cur = ''
        else: cur += ch
    if cur.strip(): parts.append(cur)
    return parts
def check_select(sel, table, where):
    for tok in split_top(sel):
        tok = tok.strip()
        if not tok or tok == '*': continue
        m = re.match(r'^(?:(\w+):)?(\w+)(!\w+)?\((.*)\)$', tok, re.S)
        if m:
            rel = m.group(2)
            if rel in COLS: check_select(m.group(4), rel, where)
            else: problems.append(f"{where}: unknown embedded table {rel}")
            continue
        m = re.match(r'^(?:(\w+):)?(\w+)(::\w+)?$', tok)
        if not m: problems.append(f"{where}: unparsable '{tok}'"); continue
        col = m.group(2)
        if col not in COLS.get(table, ()): problems.append(f"{where}: {table}.{col} does not exist")
for f in files:
    s = open(f, encoding='utf-8').read()
    for m in re.finditer(r"\.from\(\s*'(" + '|'.join(TABLES) + r")'\s*\)", s):
        i = m.end(); table = m.group(1); d = 0; j = i
        while j < len(s):
            c = s[j]
            if c in '([{': d += 1
            elif c in ')]}':
                d -= 1
                if d < 0: break
            elif c in ';,' and d == 0: break
            j += 1
        seg = s[i:j]; where = f"{f}:{s.count(chr(10),0,m.start())+1}"
        for sm in re.finditer(r"\.select\(\s*(['`])(.*?)\1", seg, re.S):
            check_select(sm.group(2), table, where)
        for fm in re.finditer(r"\.(eq|neq|gt|gte|lt|lte|like|ilike|is|in|not|order)\(\s*'(\w+)'", seg):
            if fm.group(2) not in COLS[table]: problems.append(f"{where}: filter {table}.{fm.group(2)} does not exist")
        # payload keys of toDb(...) object literals
        for pm in re.finditer(r"toDb\('(\w+)',\s*\{", seg):
            k = pm.end(); d = 1; e = k
            while e < len(seg) and d:
                if seg[e] == '{': d += 1
                elif seg[e] == '}': d -= 1
                e += 1
            body = seg[k:e-1]
            keys = re.findall(r"(?:^|,|\{)\s*(\w+)\s*(?::|,|$)", body)
            for key in keys:
                newk = legacy.get(pm.group(1), {}).get(key, key)
                if newk not in COLS[pm.group(1)] and key not in ('basis',):
                    problems.append(f"{where}: payload key {key} -> {pm.group(1)}.{newk} does not exist")
# also embeds of these tables inside other tables' selects
for f in files:
    s = open(f, encoding='utf-8').read()
    for sm in re.finditer(r"\.select\(\s*(['`])(.*?)\1", s, re.S):
        body = sm.group(2)
        for em in re.finditer(r"(?:(\w+):)?(" + '|'.join(TABLES) + r")(!\w+)?\(([^()]*)\)", body):
            check_select(em.group(4), em.group(2), f"{f}:{s.count(chr(10),0,sm.start())+1} (embed)")
print('\n'.join(sorted(set(problems))) or 'ALL COLUMNS OK')
