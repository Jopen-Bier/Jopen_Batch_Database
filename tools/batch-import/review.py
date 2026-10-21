# Review workbooks for the 2026 import (docs/batch-report/import-2026.md, step 3).
# Usage: python3 -I review.py <reader_out_dir> <app.json> <review_dir>
# app.json: {batch_number: {name, status, brew_count, recipe, location, has_data}}
# from the live database. Writes <review_dir>/<batch>_review.xlsx (overview +
# one sheet per tab: source cell, label, value, target column, status) and
# <review_dir>/summary.xlsx (one row per batch: found, rows per table, warnings).
import sys, os, json, glob
import openpyxl
from openpyxl.styles import Font, PatternFill, Alignment

TABS = [('Brouwen', 'Brewing'), ('Gistkaart Invoer', 'Fermentation log'), ('Verwerking', 'Processing'),
        ('Afvullen', 'Filling'), ('Afvulverslag', 'Filling report')]
FILL = {'read': None, 'formula': 'DDEBF7', 'missing': 'FFF2CC', 'suspicious': 'F8CBAD', 'not_imported': 'E7E6E6'}
BOLD = Font(bold=True)


def counts(d):
    return {
        'batch_brews': len(d.get('brews', [])),
        'batch_brew_comments': len(d.get('brew_comments', [])),
        'fermentation_log_entries': len(d.get('fermentation_log', [])),
        'fermentation_log_entry_tags': sum(len(e.get('tags', [])) for e in d.get('fermentation_log', [])),
        'processing_sessions': len(d.get('processing_sessions', [])),
        'processing_comments': len(d.get('processing_comments', [])),
        'batch_hbts': len(d.get('hbts', [])),
        'hbt_readings': sum(len(h['readings']) for h in d.get('hbts', [])),
        'filling_sessions': len(d.get('filling_sessions', [])),
        'filling_measurements': sum(len(s.get('measurements', [])) for s in d.get('filling_sessions', [])),
        'filling_session_articles': sum(len(s.get('articles', [])) for s in d.get('filling_sessions', [])),
        'filling_session_materials': sum(len(s.get('materials', [])) for s in d.get('filling_sessions', [])),
        'batch_transfers': len(d.get('transfers', [])),
    }


def app_checks(d, app):
    """Warnings that need the app's data: batch found, empty tabs, recipe, transfers."""
    out = []
    a = app.get(d['batch_number'])
    if not a:
        return ['batch not in the app: not imported'], 'missing'
    if a['has_data']:
        out.append('batch already has data in the app: not imported (never overwrite)')
    wr = d.get('workbook_recipe')
    if wr and wr.get('version') and not a['recipe'].endswith('v' + wr['version']):
        out.append(f'recipe version: workbook v{wr["version"]}, app {a["recipe"]} (app kept)')
    brews = len(d.get('brews', []))
    planned = -(-float(a['brew_count'] or 0) // 1)
    if brews and brews != planned:
        out.append(f'workbook has {brews} brews, the app brew count is {a["brew_count"]:g} '
                   f'(stage needs brews ended >= brew count; dosing uses the brew count)')
    for t in d.get('transfers', []):
        to = app.get(t['to_batch_number'])
        if not to:
            out.append(f'transfer to {t["to_batch_number"]}: batch not in the app')
        elif float(to['brew_count'] or 0) % 1:
            out.append(f'transfer to {t["to_batch_number"]} ({to["name"]}): its brew count {to["brew_count"]:g} already '
                       f'includes this beer (old workaround); recording the transfer would count it twice')
    status = 'skip' if (a['has_data']) else 'import'
    return out, status


def autosize(ws, maxw=60):
    for c in ws.columns:
        w = max(len(str(x.value or '')) for x in c)
        ws.column_dimensions[c[0].column_letter].width = min(max(8, w + 2), maxw)
    ws.freeze_panes = 'A2'
    for c in ws[1]:
        c.font = BOLD


def batch_review(d, app, extra, status, path):
    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = 'Overview'
    a = app.get(d['batch_number'], {})
    ws.append(['Batch', d['batch_number']])
    ws.append(['Workbook', d['source']])
    ws.append(['In the app', f'{a.get("name", "-")} · {a.get("recipe", "-")} · {a.get("status", "-")}'])
    ws.append(['Import', status])
    ws.append([])
    ws.append(['Table', 'Rows to import'])
    for k, v in counts(d).items():
        ws.append([k, v])
    ws.append([])
    ws.append(['Batch columns', 'Value'])
    for k, v in d['batch'].items():
        ws.append([k, v if not isinstance(v, list) else ', '.join(v)])
    ws.append([])
    ws.append(['Warnings'])
    for w in extra + d['warnings']:
        ws.append([w])
    for t in d.get('transfers', []):
        ws.append([f'Transfer: {t["volume_hl"]:g} hl from {t["from_tank"]} to {t["to_batch_number"]} '
                   f'at {t["transferred_at"] or "?"} ({t.get("date_from", "no date")})'])
    for r in ws.iter_rows():
        if r[0].value in ('Batch', 'Table', 'Batch columns', 'Warnings'):
            r[0].font = BOLD
    ws.column_dimensions['A'].width = 40
    ws.column_dimensions['B'].width = 70
    for sheet, title in TABS:
        rows = [r for r in d['review'] if r['sheet'] == sheet]
        t = wb.create_sheet(title)
        t.append(['Cell', 'Label', 'Value in workbook', 'Into (table.column)', 'Status', 'Note'])
        for r in rows:
            t.append([r['cell'], r['label'], r['value'] if not isinstance(r['value'], list) else str(r['value']),
                      r['target'], r['status'], r['note']])
            color = FILL.get(r['status'])
            if color:
                for c in t[t.max_row]:
                    c.fill = PatternFill('solid', fgColor=color)
        autosize(t)
    legend = wb.create_sheet('Legend')
    for k, txt in (('read', 'read and imported'), ('formula', 'formula cell imported (recipe value in the yeast block)'),
                   ('missing', 'expected but empty; a default is used where noted'),
                   ('suspicious', 'imported or kept as a comment, but check it'),
                   ('not_imported', 'value in the workbook without a place in the app')):
        legend.append([k, txt])
        if FILL.get(k):
            legend[legend.max_row][0].fill = PatternFill('solid', fgColor=FILL[k])
    legend.column_dimensions['A'].width = 14
    legend.column_dimensions['B'].width = 70
    wb.save(path)


def main():
    src, app_path, dest = sys.argv[1], sys.argv[2], sys.argv[3]
    app = json.load(open(app_path))
    os.makedirs(dest, exist_ok=True)
    summary = openpyxl.Workbook()
    ws = summary.active
    ws.title = 'Summary'
    keys = list(counts({}).keys())
    ws.append(['Batch', 'Name (app)', 'Recipe (app)', 'Workbook recipe', 'Status (app)', 'Import', 'Warnings',
               'Suspicious cells', 'Not imported cells'] + keys + ['First warnings'])
    allw = summary.create_sheet('Warnings')
    allw.append(['Batch', 'Warning'])
    for p in sorted(glob.glob(os.path.join(src, '*.json'))):
        d = json.load(open(p))
        extra, status = app_checks(d, app)
        batch_review(d, app, extra, status, os.path.join(dest, f'{d["batch_number"]}_review.xlsx'))
        a = app.get(d['batch_number'], {})
        wr = d.get('workbook_recipe') or {}
        warns = extra + d['warnings']
        c = counts(d)
        ws.append([d['batch_number'], a.get('name'), a.get('recipe'), f'{wr.get("name", "")} v{wr.get("version", "")}',
                   a.get('status'), status, len(warns),
                   sum(r['status'] == 'suspicious' for r in d['review']),
                   sum(r['status'] == 'not_imported' for r in d['review'])] + [c[k] for k in keys]
                  + [' | '.join(warns[:3])])
        for w in warns:
            allw.append([d['batch_number'], w])
    autosize(ws, 40)
    autosize(allw, 120)
    for c in ws[1]:
        c.alignment = Alignment(wrap_text=True, vertical='top')
    summary.save(os.path.join(dest, 'summary.xlsx'))
    print('review written to', dest)


if __name__ == '__main__':
    main()
