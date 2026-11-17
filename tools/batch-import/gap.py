# The gap to fill per batch: workbook values the app does not have yet.
# Never overwrites: missing rows are inserted, missing fields on existing rows filled.
# Left out (check list): differences, brew_count, brew comments, transfers, count mismatches.
import sys, json, glob, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from compare import norm

BATCH_FIELDS = ['glt_tank', 'lt_tank', 'yeast_temp_start', 'yeast_temp_max', 'yeast_strain', 'yeast_rehydrated', 'yeast_weight',
                'yeast_with_first_brew', 'yeast_pitched_on', 'yeast_pitched_by', 'yeast_program_on', 'glt_empty',
                'tasting_comment', 'tasting_result']

def missing(w, a, keys):
    return {k: w[k] for k in keys if k in w and norm(w[k]) is not None and norm(a.get(k)) is None}

def main():
    rdir, app_path, out_path = sys.argv[1:4]
    app = json.load(open(app_path)); gaps = {}
    for f in sorted(glob.glob(os.path.join(rdir, '*.json'))):
        d = json.load(open(f)); n = d.get('batch_number')
        if not n or n not in app:
            continue
        a = app[n]; g = {}
        bf = missing(d['batch'], a, BATCH_FIELDS)
        if bf: g['batch'] = bf
        # Brews
        ab = {x['brew_number']: x for x in a.get('brews') or []}
        for x in d.get('brews', []):
            if x['brew_number'] not in ab:
                g.setdefault('new_brews', []).append(x)
            else:
                m = missing(x, ab[x['brew_number']], [k for k in x if k != 'brew_number'])
                if m: g.setdefault('brew_fields', []).append({'brew_number': x['brew_number'], **m})
        # Fermentation log (same matching as compare.py)
        al = a.get('fermentation_log') or []; used = set(); wl = d.get('fermentation_log', [])
        for e in wl:
            m = norm(e['measured_at'])
            hit = next((i for i, x in enumerate(al) if i not in used and norm(x['measured_at']) == m), None)
            day = str(e['measured_at'])[:10]
            if hit is None:
                hit = next((i for i, x in enumerate(al) if i not in used and str(x['measured_at'])[:10] == day
                            and norm(x.get('extract')) == norm(e.get('extract'))), None)
            if hit is None:
                ws = [x for x in wl if str(x['measured_at'])[:10] == day]
                cand = [i for i, x in enumerate(al) if i not in used and str(x['measured_at'])[:10] == day]
                if len(ws) == 1 and len(cand) == 1: hit = cand[0]
            if hit is None:
                g.setdefault('new_log', []).append({k: e[k] for k in ('measured_at', 'extract', 'temp_high', 'temp_low', 'ph', 'comment', 'operator', 'tags') if e.get(k) not in (None, [])})
            else:
                used.add(hit)
                mf = missing(e, al[hit], ['extract', 'temp_high', 'temp_low', 'ph', 'comment'])
                if mf: g.setdefault('log_fields', []).append({'measured_at': al[hit]['measured_at'], **mf})
        # Processing sessions
        ap = {x['session_number']: x for x in a.get('processing_sessions') or []}
        for s in d.get('processing_sessions', []):
            s = {k: v for k, v in s.items() if k != '_avg'}
            if s['session_number'] not in ap:
                g.setdefault('new_processing', []).append(s)
            else:
                m = missing(s, ap[s['session_number']], [k for k in s if k != 'session_number'])
                if m: g.setdefault('processing_fields', []).append({'session_number': s['session_number'], **m})
        pc = [norm(c[1]) for c in a.get('processing_comments') or []]
        for c in d.get('processing_comments', []):
            if norm(c['comment']) not in pc:
                g.setdefault('new_processing_comments', []).append(c)
        # HBT fills (by sort order) and their readings
        ah = {x['sort_order']: x for x in a.get('hbts') or []}
        for h in d.get('hbts', []):
            if not h.get('tank'):
                g.setdefault('check', []).append(f"HBT fill {h['sort_order']} without a tank"); continue
            if h['sort_order'] not in ah:
                g.setdefault('new_hbts', []).append(h)
            else:
                ex = ah[h['sort_order']]
                if ex.get('tank') != h['tank']:
                    g.setdefault('check', []).append(f"HBT fill {h['sort_order']}: workbook {h['tank']}, app {ex.get('tank')}"); continue
                m = missing(h, ex, ['avg_pu', 'avg_turbidity_ebc'])
                if m: g.setdefault('hbt_fields', []).append({'sort_order': h['sort_order'], **m})
                if h.get('readings') and not ex.get('readings'):
                    g.setdefault('hbt_readings', []).append({'sort_order': h['sort_order'], 'processing_session_number': h.get('processing_session_number'), 'readings': h['readings']})
                elif len(h.get('readings') or []) != len(ex.get('readings') or []):
                    g.setdefault('check', []).append(f"HBT fill {h['sort_order']}: {len(h.get('readings') or [])} readings in the workbook, {len(ex.get('readings') or [])} in the app")
        # Filling sessions: hbt_index -> the sort order of that workbook fill
        hs = [h['sort_order'] for h in d.get('hbts', [])]
        af = {x['session_number']: x for x in a.get('filling_sessions') or []}
        for s in d.get('filling_sessions', []):
            s = dict(s); s['hbt_sort'] = hs[s['hbt_index']] if s.get('hbt_index') is not None and s['hbt_index'] < len(hs) else None
            if s['session_number'] not in af:
                g.setdefault('new_filling', []).append(s); continue
            ex = af[s['session_number']]
            keys = ['filling_date', 'package_format', 'volume_hl', 'start_time', 'end_time', 'sampled_by',
                    'is_first_package_checked', 'is_fill_tube_checked_first', 'is_fill_tube_checked_end', 'are_burst_bottles_controlled']
            m = missing(s, ex, keys)
            if m: g.setdefault('filling_fields', []).append({'session_number': s['session_number'], **m})
            if s.get('measurements') and not ex.get('measurements'):
                g.setdefault('filling_measurements', []).append({'session_number': s['session_number'], 'measurements': s['measurements']})
            elif len(s.get('measurements') or []) != len(ex.get('measurements') or []):
                g.setdefault('check', []).append(f"Filling {s['session_number']}: {len(s.get('measurements') or [])} measurements in the workbook, {len(ex.get('measurements') or [])} in the app")
            for sub in ('articles', 'materials'):
                have = {x['code'] for x in ex.get(sub) or []}
                tot = {}
                for x in s.get(sub) or []:
                    if x['code'] not in have: tot[x['code']] = tot.get(x['code'], 0) + (x['quantity'] or 0)
                for c, q in tot.items():
                    g.setdefault('filling_' + sub, []).append({'session_number': s['session_number'], 'code': c, 'quantity': q})
        if len(d.get('transfers') or []) != len(a.get('transfers') or []):
            g.setdefault('check', []).append(f"Transfers: {len(d.get('transfers') or [])} in the workbook, {len(a.get('transfers') or [])} in the app")
        if g: gaps[n] = g
    json.dump(gaps, open(out_path, 'w'), ensure_ascii=False, default=str, separators=(',', ':'))
    import collections
    c = collections.Counter()
    for g in gaps.values():
        for k, v in g.items(): c[k] += len(v) if isinstance(v, list) else 1
    print(len(gaps), 'batches', dict(c), os.path.getsize(out_path), 'bytes')

main()
