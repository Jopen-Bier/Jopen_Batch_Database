# Analysis helper for the 2026 batch-report import (tools/batch-import/README.md).
import sys, ast, collections, re
def load(p):
    d = collections.defaultdict(dict)
    for line in open(p):
        sh, cell, kind, val = line.rstrip('\n').split('\t')
        d[sh][cell] = (kind, ast.literal_eval(val))
    return d
a, b = load(sys.argv[1]), load(sys.argv[2])
isnum = lambda v: re.fullmatch(r'-?[\d.,: TE+-]+', v) is not None
for sh in a:
    la = {c: v for c, (k, v) in a[sh].items() if k == 'V' and not isnum(v) and len(v) < 60}
    lb = {c: v for c, (k, v) in b[sh].items() if k == 'V' and not isnum(v) and len(v) < 60}
    same = sum(1 for c in la if lb.get(c) == la[c])
    print(f'== {sh}: labels {len(la)} / {len(lb)}, same cell+text {same}')
    # labels present in both but at different cells
    inv_b = collections.defaultdict(list)
    for c, v in lb.items(): inv_b[v].append(c)
    moved = [(v, c, inv_b[v]) for c, v in la.items() if lb.get(c) != v and v in inv_b]
    for v, c, cs in moved[:12]: print(f'   moved {v!r}: {c} -> {cs}')
    if len(moved) > 12: print(f'   … {len(moved)} moved')
