#!/usr/bin/env python3
"""Repo guard, run by .github/workflows/guard.yml on every push and PR.

Checks
1. Helper copies: no page or script defines its own copy of a helper that
   lives in jopen-utils.js (also catches renamed copies such as
   escapeHtmlLokaal / escapeHtmlLocal).
2. Naming in new migrations: every table, column, view, function, type,
   index and trigger created or renamed in a migration newer than
   NAMING_BASELINE must be snake_case and must not contain Dutch words
   (word list derived from the old names in supabase/rename-map.json).

Exemption for a deliberate exception: put `-- naming-ok: <identifier>` in
the migration file. Run from the repo root: python3 tools/ci_guard.py
Exit code 1 when anything is found; findings are printed as GitHub
annotations (::error file=…).
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Migrations up to and including this version predate the English rename
# (step 9 of the architecture cleanup) and are not checked.
NAMING_BASELINE = '20261017090000'

# Tokens that occur in old Dutch names but are also normal English or
# abbreviations, so they must not be flagged.
NOT_DUTCH = {
    'alc', 'begin', 'bh', 'clr', 'cumm', 'door', 'lager', 'mashfilter',
    'obv', 'op', 'pad', 'rust', 'sep', 'sparging', 't', 'vat', 'vet', 'vol',
}

# Directories whose files are not app code.
SKIP_DIRS = {'.git', 'node_modules', 'tests', 'tools', '.github', 'supabase'}

SNAKE = re.compile(r'^_?[a-z][a-z0-9_]*$')  # leading _ = temporary helper table
IDENT = r'(?:"[^"]+"|[A-Za-z_][A-Za-z0-9_$]*)'
QUALIFIED = rf'(?:{IDENT}\s*\.\s*)?({IDENT})'

findings = []


def report(path, line, msg):
    rel = path.relative_to(ROOT)
    findings.append(f'::error file={rel},line={line}::{msg}')


# ---------------------------------------------------------------- helpers
def helper_names():
    src = (ROOT / 'jopen-utils.js').read_text(encoding='utf-8')
    m = re.search(r'module\.exports\s*=\s*\{([^}]*)\}', src)
    if not m:
        sys.exit('ci_guard: could not find module.exports in jopen-utils.js')
    return [n.strip().split(':')[0].strip() for n in m.group(1).split(',') if n.strip()]


def check_helper_copies():
    names = helper_names()
    alt = '|'.join(map(re.escape, names))
    # function escapeHtml(…) / const escapeHtml = (…) => / let fetchAllRows = function
    # plus local variants: escapeHtmlLokaal, escapeHtmlLocal, escapeHtml2, _escapeHtml
    pattern = re.compile(
        rf'(?:\bfunction\s+|\b(?:const|let|var)\s+)_?({alt})(?:Lokaal|Local|Copy|\d)?\s*(?:\(|=)'
    )
    for path in sorted(ROOT.rglob('*')):
        if path.suffix not in ('.html', '.js') or path.name == 'jopen-utils.js':
            continue
        if SKIP_DIRS & set(p.name for p in path.relative_to(ROOT).parents):
            continue
        for i, line in enumerate(path.read_text(encoding='utf-8', errors='replace').splitlines(), 1):
            m = pattern.search(line)
            if m:
                report(path, i, f'Own copy of jopen-utils helper "{m.group(1)}" — '
                                'use the one from jopen-utils.js (CLAUDE.md, Code).')


# ---------------------------------------------------------------- naming
def dutch_tokens():
    rmap = json.loads((ROOT / 'supabase' / 'rename-map.json').read_text(encoding='utf-8'))
    old, new, renamed = set(), set(), set()
    for tname, t in rmap['tables'].items():
        old.add(tname)
        new.add(t['name'])
        if t['name'] != tname:
            renamed.add(tname)
        for c, n in t.get('columns', {}).items():
            old.add(c)
            if n != 'drop':
                new.add(n)
            if n != c:
                renamed.add(c)
    split = lambda s: set(re.split(r'[_\s]+', s.lower())) - {''}
    old_tokens = set().union(*map(split, old))
    new_tokens = set().union(*map(split, new))
    return (old_tokens - new_tokens - NOT_DUTCH), {o.lower() for o in renamed - new}


def strip_sql(sql):
    """Blank out comments, string literals and dollar-quoted bodies,
    keeping newlines so line numbers stay right."""
    out = []
    i, n = 0, len(sql)
    keep = lambda s: re.sub(r'[^\n]', ' ', s)
    while i < n:
        if sql.startswith('--', i):
            j = sql.find('\n', i)
            j = n if j < 0 else j
            out.append(keep(sql[i:j])); i = j
        elif sql.startswith('/*', i):
            j = sql.find('*/', i + 2)
            j = n if j < 0 else j + 2
            out.append(keep(sql[i:j])); i = j
        elif sql[i] == "'":
            j = i + 1
            while j < n:
                if sql[j] == "'" and sql[j + 1:j + 2] == "'":
                    j += 2
                elif sql[j] == "'":
                    j += 1; break
                else:
                    j += 1
            out.append(keep(sql[i:j])); i = j
        elif sql[i] == '$':
            m = re.match(r'\$[A-Za-z0-9_]*\$', sql[i:])
            if m:
                tag = m.group(0)
                j = sql.find(tag, i + len(tag))
                j = n if j < 0 else j + len(tag)
                out.append(keep(sql[i:j])); i = j
            else:
                out.append(sql[i]); i += 1
        else:
            out.append(sql[i]); i += 1
    return ''.join(out)


def table_columns(sql, open_paren):
    """Column names of a CREATE TABLE body starting at open_paren."""
    depth, start, parts = 0, open_paren + 1, []
    for k in range(open_paren, len(sql)):
        if sql[k] == '(':
            depth += 1
        elif sql[k] == ')':
            depth -= 1
            if depth == 0:
                parts.append((start, sql[start:k]))
                break
        elif sql[k] == ',' and depth == 1:
            parts.append((start, sql[start:k])); start = k + 1
    cols = []
    for pos, part in parts:
        m = re.match(rf'\s*({IDENT})', part)
        if not m:
            continue
        word = m.group(1)
        if word.lower() in ('constraint', 'primary', 'unique', 'foreign', 'check', 'exclude', 'like'):
            continue
        cols.append((pos + m.start(1), word))
    return cols


def check_identifier(path, sql, pos, ident, kind, tokens, old_names, exempt):
    name = ident.strip('"')
    if name.lower() in exempt:
        return
    line = sql.count('\n', 0, pos) + 1
    if ident.startswith('"') or not SNAKE.match(name):
        report(path, line, f'{kind} "{name}" is not snake_case (CLAUDE.md, Database).')
        return
    if name in old_names:
        report(path, line, f'{kind} "{name}" is an old Dutch name — see supabase/rename-map.json.')
        return
    dutch = sorted(set(name.split('_')) & tokens)
    if dutch:
        report(path, line, f'{kind} "{name}" contains Dutch word(s) {", ".join(dutch)} — '
                           'names are English (ARCHITECTURE.md §3.3 glossary). '
                           f'Deliberate? add "-- naming-ok: {name}".')


STATEMENTS = [
    ('table', rf'\bcreate\s+(?:(?:global\s+|local\s+)?(?:temp|temporary|unlogged)\s+)?table\s+(?:if\s+not\s+exists\s+)?{QUALIFIED}'),
    ('view', rf'\bcreate\s+(?:or\s+replace\s+)?(?:materialized\s+)?view\s+(?:if\s+not\s+exists\s+)?{QUALIFIED}'),
    ('function', rf'\bcreate\s+(?:or\s+replace\s+)?(?:function|procedure)\s+{QUALIFIED}'),
    ('type', rf'\bcreate\s+type\s+{QUALIFIED}'),
    ('index', rf'\bcreate\s+(?:unique\s+)?index\s+(?:concurrently\s+)?(?:if\s+not\s+exists\s+)?({IDENT})\s+on\b'),
    ('trigger', rf'\bcreate\s+(?:or\s+replace\s+)?(?:constraint\s+)?trigger\s+({IDENT})'),
    ('column', rf'\badd\s+(?:column\s+)?(?:if\s+not\s+exists\s+)?({IDENT})\s+(?!constraint\b|primary\b|unique\b|foreign\b|check\b)[A-Za-z]'),
    ('column', rf'\brename\s+(?:column\s+)?{IDENT}\s+to\s+({IDENT})'),
    ('name', rf'\brename\s+to\s+({IDENT})'),
]


def check_migrations():
    tokens, old_names = dutch_tokens()
    for path in sorted((ROOT / 'supabase' / 'migrations').glob('*.sql')):
        version = path.name.split('_', 1)[0]
        if version <= NAMING_BASELINE:
            continue
        raw = path.read_text(encoding='utf-8')
        exempt = {e.lower() for e in re.findall(r'--\s*naming-ok:\s*([A-Za-z0-9_]+)', raw)}
        sql = strip_sql(raw)
        for kind, rx in STATEMENTS:
            for m in re.finditer(rx, sql, re.IGNORECASE):
                ident = m.group(1)
                # "rename to" after "rename column x to" is handled by the column rule
                if kind == 'name' and re.search(r'rename\s+(?:column\s+)?\S+\s+$', sql[max(0, m.start() - 80):m.start()], re.I):
                    continue
                check_identifier(path, sql, m.start(1), ident, kind, tokens, old_names, exempt)
                if kind == 'table':
                    paren = sql.find('(', m.end())
                    between = sql[m.end():paren] if paren >= 0 else ''
                    if paren >= 0 and not re.search(r'\b(as|of|partition)\b', between, re.I):
                        for pos, col in table_columns(sql, paren):
                            check_identifier(path, sql, pos, col, 'column', tokens, old_names, exempt)


if __name__ == '__main__':
    check_helper_copies()
    check_migrations()
    for f in findings:
        print(f)
    if findings:
        print(f'ci_guard: {len(findings)} finding(s).')
        sys.exit(1)
    print('ci_guard: ok')
