import re, sys
TABLES = sys.argv[1].split(',')          # NEW table names (after the rename)
files = sys.argv[2:]
for f in files:
    s = open(f, encoding='utf-8').read(); orig = s; n = 0
    pos = 0
    while True:
        m = re.search(r"\.from\(\s*'(" + '|'.join(TABLES) + r")'\s*\)", s[pos:])
        if not m: break
        i = pos + m.end(); table = m.group(1)
        # statement end
        d = 0; j = i
        while j < len(s):
            c = s[j]
            if c in '([{': d += 1
            elif c in ')]}':
                d -= 1
                if d < 0: break
            elif c == ';' and d == 0: break
            j += 1
        seg = s[i:j]
        mm = re.search(r"\.(insert|update|upsert)\(", seg)
        if mm and not seg[mm.end():].lstrip().startswith('toDb('):
            a = i + mm.end()                      # start of argument
            d = 0; k = a
            while k < len(s):
                c = s[k]
                if c in '([{': d += 1
                elif c in ')]}':
                    if d == 0: break
                    d -= 1
                elif c == ',' and d == 0: break
                k += 1
            arg = s[a:k]
            s = s[:a] + f"toDb('{table}', {arg.strip()})" + s[k:]
            n += 1
        pos = i
    if s != orig:
        open(f, 'w', encoding='utf-8').write(s)
        print(f, n, 'payload(s) wrapped')
