# Analysis helper for the 2026 batch-report import (tools/batch-import/README.md).
import sys, openpyxl, datetime
p, out = sys.argv[1], sys.argv[2]
wb = openpyxl.load_workbook(p, data_only=True)
wbf = openpyxl.load_workbook(p, data_only=False)
with open(out, 'w') as f:
    for ws in wb.worksheets:
        wsf = wbf[ws.title]
        for row in ws.iter_rows():
            for c in row:
                v = c.value
                if v is None or (isinstance(v, str) and not v.strip()): continue
                fv = wsf[c.coordinate].value
                formula = isinstance(fv, str) and fv.startswith('=')
                if isinstance(v, (datetime.datetime, datetime.date, datetime.time)): v = v.isoformat()
                f.write(f"{ws.title}\t{c.coordinate}\t{'F' if formula else 'V'}\t{str(v)[:80]!r}\n")
