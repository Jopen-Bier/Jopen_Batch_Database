# Compare reader output (workbooks) with the app data, per batch, tab, row and field.
# Usage: python3 -I compare.py <reader_out_dir> <app.json> <out.json>
# Status per field: add (workbook only), same, differs (both, different), app_only.
import sys, os, json, glob, datetime, re, difflib

def norm(v):
    if v is None or v == '' or v == []:
        return None
    if isinstance(v, bool):
        return v
    if isinstance(v, (int, float)):
        return round(float(v), 4)
    if isinstance(v, list):
        return tuple(sorted(str(x) for x in v))
    s = str(v).strip()
    try:
        if 'T' in s and len(s) >= 16:
            d = datetime.datetime.fromisoformat(s.replace('Z', '+00:00'))
            return d.astimezone(datetime.timezone.utc).strftime('%Y-%m-%d %H:%M')
    except ValueError:
        pass
    if len(s) == 8 and s[2] == ':' and s[5] == ':':
        s = s[:5]                      # 06:40:00 -> 06:40
    s = re.sub(r'(?<=\d),(?=\d)', '.', s)   # 5,22 -> 5.22
    try:
        return round(float(s), 4)
    except ValueError:
        return ' '.join(s.split()).lower()

TEXT = {'comment', 'tasting_comment', 'boil_acid_ph_note', 'yeast_strain', 'extra_addition', 'software_order_number'}

def alike(k, w, a):
    if w == a:
        return True
    if k == 'tags' and isinstance(w, tuple) and isinstance(a, tuple):
        return set(w) <= set(a)          # the app may carry extra tags
    if k in TEXT and isinstance(w, str) and isinstance(a, str):
        return difflib.SequenceMatcher(None, w, a).ratio() >= 0.85   # typos
    return False

def cmp_fields(wb, app, skip=()):
    out = []
    for k, v in wb.items():
        if k in skip or isinstance(v, (dict,)) or (isinstance(v, list) and v and isinstance(v[0], dict)):
            continue
        a, w = norm(app.get(k)), norm(v)
        if w is None:
            continue
        out.append((k, v, app.get(k), 'add' if a is None else 'same' if alike(k, w, a) else 'differs'))
    return out

def main():
    rdir, app_path, out_path = sys.argv[1:4]
    app = json.load(open(app_path))
    rows, summary = [], []
    for f in sorted(glob.glob(os.path.join(rdir, '*.json'))):
        d = json.load(open(f))
        n = d.get('batch_number')
        s = {'batch': n or os.path.basename(f)[:5], 'source': d['source'], 'type': d['type'],
             'add': 0, 'same': 0, 'differs': 0, 'app_only': 0, 'rows_add': {}, 'warnings': len(d.get('warnings', []))}
        def rec(tab, key, field, wv, av, st):
            s[st] += 1
            if st != 'same':
                rows.append({'batch': s['batch'], 'tab': tab, 'row': key, 'field': field,
                             'workbook': wv, 'app': av, 'status': st})
        if not n:
            s['note'] = 'empty template: nothing filled in'
            summary.append(s); continue
        a = app.get(n)
        if a is None:
            s['note'] = 'batch not in the app'
            summary.append(s); continue
        # Batch fields
        for k, wv, av, st in cmp_fields(d['batch'], a):
            rec('Batch', '-', k, wv, av, st)
        nb = len(d.get('brews', []))
        if nb and a.get('brew_count') is not None and norm(a['brew_count']) != norm(nb):
            rec('Batch', '-', 'brew_count', nb, a['brew_count'], 'differs')
        # Keyed row tables
        def keyed(tab, wl, al, keyf, skip=(), children=None):
            am = {}
            for r in al or []:
                am.setdefault(keyf(r), r)
            used = set()
            for r in wl or []:
                k = keyf(r)
                if k in am:
                    used.add(k)
                    for fld, wv, av, st in cmp_fields(r, am[k], skip):
                        rec(tab, k, fld, wv, av, st)
                    if children:
                        children(k, r, am[k])
                else:
                    filled = [x for x in r if norm(r[x]) is not None and x not in skip]
                    rec(tab, k, '(whole row)', f'{len(filled)} fields', None, 'add')
                    s['rows_add'][tab] = s['rows_add'].get(tab, 0) + 1
            for k, r in am.items():
                if k not in used:
                    rec(tab, k, '(whole row)', None, 'entered in the app', 'app_only')
        keyed('Brewing', d.get('brews'), a.get('brews'), lambda r: r['brew_number'])
        # Brew comments: by text
        ac = [norm(c[1]) for c in a.get('brew_comments') or []]
        for c in d.get('brew_comments', []):
            st = 'same' if any(alike('comment', norm(c['comment']), x) for x in ac) else 'add'
            rec('Brew comments', c['brew_number'], 'comment', c['comment'], None, st)
            if st == 'add':
                s['rows_add']['Brew comments'] = s['rows_add'].get('Brew comments', 0) + 1
        # Fermentation log: same moment, else same day with the same Plato
        al = a.get('fermentation_log') or []
        used = set()
        for e in d.get('fermentation_log', []):
            m = norm(e['measured_at'])
            hit = next((i for i, x in enumerate(al) if i not in used and norm(x['measured_at']) == m), None)
            if hit is None:
                day = str(e['measured_at'])[:10]
                hit = next((i for i, x in enumerate(al) if i not in used and str(x['measured_at'])[:10] == day
                            and norm(x.get('extract')) == norm(e.get('extract'))), None)
            if hit is None:
                day = str(e['measured_at'])[:10]
                wsame = [x for x in d.get('fermentation_log', []) if str(x['measured_at'])[:10] == day]
                cand = [i for i, x in enumerate(al) if i not in used and str(x['measured_at'])[:10] == day]
                if len(wsame) == 1 and len(cand) == 1:
                    hit = cand[0]
            key = str(e['measured_at'])[:16].replace('T', ' ')
            if hit is None:
                rec('Fermentation log', key, '(whole row)', f"P {e.get('extract')} pH {e.get('ph')}", None, 'add')
                s['rows_add']['Fermentation log'] = s['rows_add'].get('Fermentation log', 0) + 1
                continue
            used.add(hit)
            for fld, wv, av, st in cmp_fields(e, al[hit], skip=('row', 'measured_at')):
                rec('Fermentation log', key, fld, wv, av, st)
        for i, x in enumerate(al):
            if i not in used:
                rec('Fermentation log', str(x['measured_at'])[:16].replace('T', ' '), '(whole row)', None, 'entered in the app', 'app_only')
        keyed('Processing', d.get('processing_sessions'), a.get('processing_sessions'), lambda r: r['session_number'], skip=('_avg',))
        pc = {norm(c[1]) for c in a.get('processing_comments') or []}
        for c in d.get('processing_comments', []):
            rec('Processing comments', c.get('comment_time') or '-', 'comment', c['comment'], None,
                'same' if norm(c['comment']) in pc else 'add')
        def hbt_children(k, w, ap):
            wr, ar = len(w.get('readings') or []), len(ap.get('readings') or [])
            if wr != ar:
                rec('HBT', k, 'readings (count)', wr, ar, 'add' if ar < wr else 'differs')
        keyed('HBT', d.get('hbts'), a.get('hbts'), lambda r: r['sort_order'],
              skip=('processing_session_number', 'split_to', 'readings'), children=hbt_children)
        def fill_children(k, w, ap):
            wm, am_ = len(w.get('measurements') or []), len(ap.get('measurements') or [])
            if wm != am_:
                rec('Filling', k, 'measurements (count)', wm, am_, 'add' if am_ < wm else 'differs')
            for sub in ('articles', 'materials'):
                aq = {x['code']: x['quantity'] for x in ap.get(sub) or []}
                for x in w.get(sub) or []:
                    av = aq.get(x['code'])
                    st = 'add' if av is None else 'same' if norm(av) == norm(x['quantity']) else 'differs'
                    rec('Filling report', k, f"{sub[:-1]} {x['code']}", x['quantity'], av, st)
        keyed('Filling', d.get('filling_sessions'), a.get('filling_sessions'), lambda r: r['session_number'],
              skip=('hbt_index', 'hbt_tank', 'from_report_only', 'articles', 'materials', 'measurements',
                    'also_filled_by', 'first_package_checked_by'), children=fill_children)
        wt, at = len(d.get('transfers') or []), len(a.get('transfers') or [])
        if wt != at:
            rec('Transfers', '-', 'count', wt, at, 'add' if at < wt else 'differs')
        summary.append(s)
    json.dump({'summary': summary, 'rows': rows}, open(out_path, 'w'), default=str, ensure_ascii=False, indent=0)
    tot = {k: sum(x[k] for x in summary) for k in ('add', 'same', 'differs', 'app_only')}
    print(len(summary), 'workbooks', tot)

if __name__ == "__main__":
    main()
