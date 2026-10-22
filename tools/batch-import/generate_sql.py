# SQL for the 2026 import (docs/batch-report/import-2026.md, step 5).
# Usage: python3 -I generate_sql.py <reader_out_dir> <app.json> <out_dir> <chunk_name> [batch_number ...]
# Without batch numbers: every reader JSON in the dir. Writes
# <out_dir>/import_<chunk>_dry_run.sql and import_<chunk>_run.sql: one DO block
# that, per batch, checks the batch exists and its tabs are still empty (else
# the batch is skipped and reported), fills the batch columns that are still
# empty, inserts the rows, and reports rows per table and stage before / after.
# The dry run ends with an exception, so nothing is kept.
# Plain ASCII: other characters are written as chr(n).
# Transfers are not written here (they change the receiving batch): see
# docs/batch-report/import-2026.md.
import sys, os, json, glob, datetime

TABLES = ['batch_brews', 'batch_brew_comments', 'fermentation_log_entries', 'fermentation_log_entry_tags',
          'processing_sessions', 'processing_comments', 'batch_hbts', 'hbt_readings', 'filling_sessions',
          'filling_measurements', 'filling_session_articles', 'filling_session_materials']
SHORT = dict(zip(TABLES, ['brews', 'brew_comments', 'log', 'tags', 'proc', 'proc_comments', 'hbts', 'readings',
                          'fill', 'meas', 'articles', 'materials']))


def lit(v, cast=None):
    """A Python value as an ASCII SQL literal."""
    if v is None:
        return 'null'
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, (int, float)):
        s = repr(round(v, 6)) if isinstance(v, float) else str(v)
        return s[:-2] if s.endswith('.0') else s
    if isinstance(v, list):
        return 'array[' + ', '.join(lit(x) for x in v) + ']::text[]' if v else "'{}'::text[]"
    s = str(v)
    parts, cur = [], ''
    for ch in s:
        if 32 <= ord(ch) < 127:
            cur += "''" if ch == "'" else ch
        else:
            if cur:
                parts.append(f"'{cur}'")
                cur = ''
            parts.append(f'chr({ord(ch)})')
    if cur or not parts:
        parts.append(f"'{cur}'")
    out = ' || '.join(parts)
    if len(parts) > 1:
        out = f'({out})'
    return f'{out}::{cast}' if cast else out


def user(ini):
    return f"(v_users->>{lit(ini.upper())})::uuid" if ini else 'null'


def ref(kind, code):
    return f"(v_{kind}->>{lit(code)})::bigint" if code else 'null'


def insert(table, cols, returning=None):
    names = ', '.join(cols)
    vals = ', '.join(cols.values())
    ret = f' returning id into {returning}' if returning else ''
    return f'    insert into public.{table} ({names}) values ({vals}){ret};\n'


def batch_sql(d):
    n = d['batch_number']
    b = d['batch']
    src = d['source'].encode('ascii', 'replace').decode().replace('*/', '')  # comments stay plain ASCII too
    out = [f"\n  -- {n} ({src}) " + '-' * 20 + '\n',
           f"  select id into v_batch from public.batches where batch_number = {lit(n)};\n",
           f"  if v_batch is null then\n    v_skipped := v_skipped || {lit(n + ' (not in the app)', 'text')};\n",
           "  elsif exists (select 1 from public.batch_brews where batch_id = v_batch)\n"
           "     or exists (select 1 from public.fermentation_log_entries where batch_id = v_batch)\n"
           "     or exists (select 1 from public.processing_sessions where batch_id = v_batch)\n"
           "     or exists (select 1 from public.filling_sessions where batch_id = v_batch)\n"
           "     or exists (select 1 from public.batch_brew_comments where batch_id = v_batch)\n"
           "     or exists (select 1 from public.processing_comments where batch_id = v_batch)\n"
           "     or exists (select 1 from public.batch_hbts where batch_id = v_batch) then\n"
           f"    v_skipped := v_skipped || {lit(n + ' (has data)', 'text')};\n",
           "  else\n    v_proc := '{}';\n    v_hbt := '{}';\n",
           "    select stage into v_before from public.batch_stages where batch_id = v_batch;\n"]
    # Batch columns: only where still empty (never overwrite).
    sets = []
    for key, val in (('glt_tank_id', ref('tanks', b.get('glt_tank'))), ('lt_tank_id', ref('tanks', b.get('lt_tank'))),
                     ('yeast_temp_start', lit(b.get('yeast_temp_start'))), ('yeast_temp_max', lit(b.get('yeast_temp_max'))),
                     ('yeast_strain', lit(b.get('yeast_strain'))), ('yeast_rehydrated', lit(b.get('yeast_rehydrated'))),
                     ('yeast_weight', lit(b.get('yeast_weight'))), ('yeast_with_first_brew', lit(b.get('yeast_with_first_brew'))),
                     ('yeast_pitched_on', lit(b.get('yeast_pitched_on'), 'date')),
                     ('yeast_pitched_by', user(b.get('yeast_pitched_by'))),
                     ('yeast_program_on', lit(b.get('yeast_program_on'))), ('glt_empty', lit(b.get('glt_empty'))),
                     ('tasting_comment', lit(b.get('tasting_comment'))), ('tasting_result', lit(b.get('tasting_result')))):
        if val != 'null':
            sets.append(f'{key} = coalesce({key}, {val})')
    if sets:
        out.append('    update public.batches set ' + ',\n        '.join(sets) + '\n    where id = v_batch;\n')
    # Brew count: the workbook knows how many brews were done (Jaap, 21-10).
    nb = len(d.get('brews', []))
    out.append("    select brew_count into v_bc from public.batches where id = v_batch;\n")
    if nb:
        out.append(f"    update public.batches set brew_count = {nb} where id = v_batch and brew_count is distinct from {nb};\n")
    for x in d.get('brews', []):
        cols = {'batch_id': 'v_batch', 'brew_number': lit(x['brew_number'])}
        for k, v in x.items():
            if k in ('brew_number', 'brewer', 'brewer_end'):
                continue
            cast = 'timestamptz' if k.endswith('_at') else None
            cols[k] = lit(v, cast)
        cols['brewer_id'] = user(x.get('brewer'))
        cols['brewer_end_id'] = user(x.get('brewer_end'))
        cols['created_by'] = user(x.get('brewer'))
        out.append(insert('batch_brews', cols))
    for c in d.get('brew_comments', []):
        out.append(insert('batch_brew_comments', {'batch_id': 'v_batch', 'brew_number': lit(c['brew_number']),
                                                  'comment': lit(c['comment'])}))
    for e in d.get('fermentation_log', []):
        cols = {'batch_id': 'v_batch', 'measured_at': lit(e['measured_at'], 'timestamptz')}
        for k in ('extract', 'temp_high', 'temp_low', 'ph', 'comment'):
            if e.get(k) is not None:
                cols[k] = lit(e[k])
        cols['created_by'] = user(e.get('operator'))
        out.append(insert('fermentation_log_entries', cols, 'v_id' if e.get('tags') else None))
        for t in e.get('tags', []):
            out.append(insert('fermentation_log_entry_tags', {'entry_id': 'v_id', 'batch_id': 'v_batch',
                                                              'tag_id': ref('tags', t), 'created_by': user(e.get('operator'))}))
    sessions = d.get('processing_sessions', [])
    for s in sessions:
        cols = {'batch_id': 'v_batch', 'session_number': lit(s['session_number']),
                'started_by': user(s.get('started_by')), 'ended_by': user(s.get('ended_by')),
                'processing_date': lit(s.get('processing_date'), 'date'),
                'start_time': lit(s.get('start_time'), 'time'), 'end_time': lit(s.get('end_time'), 'time'),
                'tank_id': ref('tanks', s.get('tank')), 'outlet': lit(s.get('outlet'))}
        for k in ('discharge_count', 'discharge_interval_min', 'centrifuge_in_o2_ppb', 'centrifuge_in_co2_gl',
                  'centrifuge_out_o2_ppb', 'centrifuge_out_co2_gl', 'start_flow_hl_h', 'start_turbidity_ebc'):
            if s.get(k) is not None:
                cols[k] = lit(s[k])
        cols['created_by'] = user(s.get('started_by'))
        out.append(insert('processing_sessions', cols, 'v_id'))
        out.append(f"    v_proc[{s['session_number']}] := v_id;\n")
    for c in d.get('processing_comments', []):
        out.append(insert('processing_comments', {'batch_id': 'v_batch', 'comment_time': lit(c.get('comment_time'), 'time'),
                                                  'comment': lit(c['comment'])}))
    for i, h in enumerate(d.get('hbts', [])):
        if not h.get('tank'):
            # A fill without a known tank cannot be stored (tank_id is required): left out, reported.
            out.append(f"    v_lines := v_lines || {lit(n + ': HBT fill ' + str(h['sort_order']) + ' without a tank left out', 'text')};\n")
            continue
        cols = {'batch_id': 'v_batch', 'tank_id': ref('tanks', h['tank']), 'sort_order': lit(h['sort_order']),
                'intended_formats': lit(h.get('intended_formats') or [])}
        for k in ('avg_pu', 'avg_turbidity_ebc'):
            if h.get(k) is not None:
                cols[k] = lit(h[k])
        out.append(insert('batch_hbts', cols, 'v_id'))
        out.append(f'    v_hbt[{i + 1}] := v_id;\n')
        sess = f"v_proc[{h['processing_session_number']}]" if h.get('processing_session_number') else 'null'
        for r in h['readings']:
            rc = {'batch_id': 'v_batch', 'batch_hbt_id': 'v_id', 'processing_session_id': sess,
                  'sort_order': lit(r['sort_order'])}
            for k in ('level_hl', 'o2_ppb', 'co2_gl', 'co2_target', 'comment'):
                if r.get(k) is not None:
                    rc[k] = lit(r[k])
            out.append(insert('hbt_readings', rc))
    for s in d.get('filling_sessions', []):
        cols = {'batch_id': 'v_batch', 'session_number': lit(s['session_number']),
                'filling_date': lit(s['filling_date'], 'date'),
                'batch_hbt_id': f"v_hbt[{s['hbt_index'] + 1}]" if s.get('hbt_index') is not None else 'null',
                'package_format': lit(s.get('package_format')), 'volume_hl': lit(s.get('volume_hl')),
                'start_time': lit(s.get('start_time'), 'time'), 'end_time': lit(s.get('end_time'), 'time'),
                'sampled_by': user(s.get('sampled_by')),
                'is_hbt_finished': lit(bool(s.get('is_hbt_finished'))), 'created_by': user(s.get('filled_by'))}
        for k in ('is_first_package_checked', 'is_fill_tube_checked_first', 'is_fill_tube_checked_end',
                  'are_burst_bottles_controlled'):
            if s.get(k) is not None:
                cols[k] = lit(s[k])
        out.append(insert('filling_sessions', cols, 'v_id'))
        for m in s.get('measurements', []):
            mc = {'batch_id': 'v_batch', 'filling_session_id': 'v_id'}
            for k, v in m.items():
                mc[k] = lit(v, 'time' if k == 'measured_time' else None)
            out.append(insert('filling_measurements', mc))
        for a in s.get('articles', []):
            out.append(insert('filling_session_articles', {'batch_id': 'v_batch', 'filling_session_id': 'v_id',
                                                           'article_id': ref('articles', a['code']), 'quantity': lit(a['quantity']),
                                                           **({'comment': lit(a['comment'])} if a.get('comment') else {})}))
        for a in s.get('materials', []):
            out.append(insert('filling_session_materials', {'batch_id': 'v_batch', 'filling_session_id': 'v_id',
                                                            'material_id': ref('materials', a['code']), 'quantity': lit(a['quantity']),
                                                            **({'comment': lit(a['comment'])} if a.get('comment') else {})}))
    out.append('    select stage into v_after from public.batch_stages where batch_id = v_batch;\n')
    counts = ' || '.join(
        f"' {SHORT[t]} ' || (select count(*) from public.{t} where batch_id = v_batch)" for t in TABLES)
    out.append(f"    v_lines := v_lines || ({lit(n + ': ')} || coalesce(v_before, '?') || '->' || coalesce(v_after, '?') || case when v_bc is distinct from (select brew_count from public.batches where id = v_batch) then ' brew_count ' || coalesce(v_bc::text, '-') || '->' || (select brew_count from public.batches where id = v_batch) else '' end || {counts});\n")
    out.append("    v_done := v_done + 1;\n  end if;\n")
    return ''.join(out)


def merge_duplicate_codes(d):
    """filling_session_articles / _materials are unique per session and code: add up repeats."""
    for s in d.get('filling_sessions', []):
        for key in ('articles', 'materials'):
            tot, notes = {}, {}
            for a in s.get(key, []):
                tot[a['code']] = tot.get(a['code'], 0) + a['quantity']
                if a.get('comment'):
                    notes[a['code']] = ', '.join(x for x in (notes.get(a['code']), a['comment']) if x)
            s[key] = [{'code': c, 'quantity': q, 'comment': notes.get(c)} for c, q in tot.items()]


def main():
    src, app_path, dest, chunk = sys.argv[1:5]
    wanted = set(sys.argv[5:])
    app = json.load(open(app_path))
    data = []
    for p in sorted(glob.glob(os.path.join(src, '*.json'))):
        d = json.load(open(p))
        if wanted and d['batch_number'] not in wanted:
            continue
        if not any(d.get(k) for k in ('brews', 'brew_comments', 'fermentation_log', 'processing_sessions',
                                      'processing_comments', 'hbts', 'filling_sessions')):
            print(f'{d["batch_number"]}: nothing to import (no brews, log, processing or filling read)')
            continue
        if d.get('hold'):
            print(f'{d["batch_number"]}: held ({d["hold"]}): left out')
            continue
        a = app.get(d['batch_number'])
        if not a or a['has_data']:
            print(f'{d["batch_number"]}: not in the app or has data: left out')
            continue
        merge_duplicate_codes(d)
        data.append(d)
    if not data:
        print('nothing to write')
        return
    body = ''.join(batch_sql(d) for d in data)
    totals = ' || '.join(
        f"' {SHORT[t]} ' || (select count(*) from public.{t} t join public.batches b on b.id = t.batch_id "
        f"where b.batch_number = any(v_numbers))" for t in TABLES)
    numbers = 'array[' + ', '.join(lit(d['batch_number']) for d in data) + ']'
    os.makedirs(dest, exist_ok=True)
    stamp = datetime.date.today().isoformat()
    for mode in ('dry_run', 'run'):
        head = (f"-- Import 2026 batch reports, chunk {chunk} ({len(data)} batches), "
                f"{'DRY RUN: ends with an exception, nothing is kept' if mode == 'dry_run' else 'RUN: after the dry run'}.\n"
                f"-- Generated {stamp} by tools/batch-import/generate_sql.py. Plain ASCII.\n"
                "-- Per batch: skipped when it is not in the app or already has data in a tab;\n"
                "-- batch columns are only filled where empty. Result: rows per table and stage before -> after.\n\n")
        end = ("  raise exception 'DRY RUN - rolled back. Results: %', v_result;\n" if mode == 'dry_run'
               else "  raise notice 'Done: %', v_result;\n")
        sql = (head + "do $$\ndeclare\n"
               "  v_users jsonb := (select jsonb_object_agg(upper(initials), id) from public.users where initials is not null);\n"
               "  v_tanks jsonb := (select jsonb_object_agg(code, id) from public.tanks);\n"
               "  v_tags jsonb := (select jsonb_object_agg(code, id) from public.cellar_action_tags);\n"
               "  v_articles jsonb := (select jsonb_object_agg(code, id) from public.packaging_articles);\n"
               "  v_materials jsonb := (select jsonb_object_agg(code, id) from public.packaging_materials);\n"
               f"  v_numbers text[] := {numbers};\n"
               "  v_batch bigint;\n  v_id bigint;\n  v_proc bigint[];\n  v_hbt bigint[];\n"
               "  v_before text;\n  v_after text;\n  v_bc numeric;\n  v_done int := 0;\n"
               "  v_lines text[] := '{}';\n  v_skipped text[] := '{}';\n  v_result text;\n"
               "begin\n" + body +
               f"\n  v_result := format('%s imported, skipped: %s' || chr(10) || '%s' || chr(10) || 'Totals:%s',\n"
               f"    v_done, coalesce(nullif(array_to_string(v_skipped, ', '), ''), 'none'),\n"
               f"    array_to_string(v_lines, chr(10)), {totals});\n" + end + "end\n$$;\n")
        bad = [c for c in sql if ord(c) > 127]
        assert not bad, f'non-ASCII left: {set(bad)}'
        with open(os.path.join(dest, f'import_{chunk}_{mode}.sql'), 'w') as f:
            f.write(sql)
    print(f'chunk {chunk}: {len(data)} batches ->', os.path.join(dest, f'import_{chunk}_dry_run.sql'))


if __name__ == '__main__':
    main()
