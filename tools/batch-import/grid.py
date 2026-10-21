# Analysis helper for the 2026 batch-report import (tools/batch-import/README.md).
import sys, ast, collections, re
from openpyxl.utils import coordinate_to_tuple
p, sheet = sys.argv[1], sys.argv[2]
r0, r1 = (int(x) for x in sys.argv[3].split('-')) if len(sys.argv) > 3 else (1, 999)
rows = collections.defaultdict(list)
for line in open(p):
    sh, cell, kind, val = line.rstrip('\n').split('\t')
    if sh != sheet: continue
    r, c = coordinate_to_tuple(cell)
    if r0 <= r <= r1: rows[r].append((c, cell, kind, ast.literal_eval(val)))
for r in sorted(rows):
    print(f'{r:>3}: ' + ' | '.join(f"{cell}{'*' if k=='F' else ''}={v[:28]}" for c, cell, k, v in sorted(rows[r])))
