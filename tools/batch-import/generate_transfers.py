# Transfers (splits) of the 2026 import as one SQL file, after the month chunks
# (docs/batch-report/import-2026.md). Run by Jaap in the SQL Editor: dry run, then run.
# Usage: python3 -I generate_transfers.py <reader_out_dir> <app.json> <dest_dir>
#
# Rules (Jaap, 22-10):
# - a transfer without a date gets the receiving batch's first filling date,
#   else the source's last processing date (12:00), else the source's last
#   log entry; the comment says so;
# - a receiving batch that was filled while its brew sheet is empty holds only
#   split beer: its brew count becomes 0;
# - receiving batches that are not in the app are skipped (26259, 25392);
#   splits into barrel aging are kept (they are on the source's filling report),
#   the barrel aging batch itself is not changed;
# - a pair in both directions keeps the one from the brewed batch (the other is
#   the receiving batch's "from #..." end value);
# - rerun-safe: a transfer with the same batches and volume is not added twice.
import sys, os, json, glob, datetime
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # python -I leaves the script folder out
from generate_sql import lit
from reader import to_timestamp


def first(values):
    values = sorted(v for v in values if v)
    return values[0] if values else None


def plan(books, app):
    """(transfers, brew_count_zero, skipped) from the reader output."""
    rows, skipped = [], []
    for d in books.values():
        if d.get('hold'):
            continue
        for t in d.get('transfers', []):
            src, to = d['batch_number'], t['to_batch_number']
            tag = f'{src} -> {to} {t["volume_hl"]:g} hl'
            if to == src:
                skipped.append(f'{tag}: to itself')
                continue
            if src not in app or to not in app:
                skipped.append(f'{tag}: {"source" if src not in app else "receiving"} batch not in the app')
                continue
            when, note = t.get('transferred_at'), None
            if not when:
                target = books.get(to) or {}
                fill = first(s.get('filling_date') for s in target.get('filling_sessions', []))
                proc = sorted(s.get('processing_date') for s in d.get('processing_sessions', []) if s.get('processing_date'))
                if fill:
                    when, note = to_timestamp(fill, '12:00'), f'date assumed: first filling of {to}'
                elif proc:
                    when, note = to_timestamp(proc[-1], '12:00'), f'date assumed: last processing of {src}'
                elif d.get('fermentation_log'):
                    when = max(e['measured_at'] for e in d['fermentation_log'])
                    note = f'date assumed: last log entry of {src}'
                else:
                    skipped.append(f'{tag}: no date (receiving batch not filled, source not processed)')
                    continue
            comment = '; '.join(x for x in (t.get('comment'), note, f'import 2026 ({t["source"]})') if x)
            rows.append({'from': src, 'to': to, 'volume_hl': t['volume_hl'], 'tank': t.get('from_tank'),
                         'at': when, 'comment': comment})
    # A pair in both directions: the receiving batch's end value says "from #26093"
    # and was read as a split out. Keep the direction from the batch with brews to
    # the batch with an empty brew sheet.
    pairs = {(r['from'], r['to']) for r in rows}
    def brewed(n):
        return bool((books.get(n) or {}).get('brews'))
    keep = []
    for r in rows:
        if (r['to'], r['from']) in pairs and not brewed(r['from']) and brewed(r['to']):
            skipped.append(f'{r["from"]} -> {r["to"]} {r["volume_hl"]:g} hl: the reverse of the split {r["to"]} -> {r["from"]}')
            continue
        keep.append(r)
    rows = keep
    receiving = {r['to'] for r in rows}
    zero = sorted(n for n in receiving
                  if n in books and not books[n].get('hold') and books[n].get('type') != 'barrel_aging'
                  and not books[n].get('brews') and books[n].get('filling_sessions')
                  and float(app[n]['brew_count'] or 0) != 0)
    return rows, zero, skipped


def sql(rows, zero, mode):
    out = ["-- Import 2026: transfers (splits) between batches, "
           + ("DRY RUN: ends with an exception, nothing is kept.\n" if mode == 'dry_run' else "RUN: after the dry run.\n"),
           f"-- Generated {datetime.date.today().isoformat()} by tools/batch-import/generate_transfers.py. Plain ASCII.\n",
           "-- Run after all month chunks. A transfer that is already there (same batches and volume) is skipped.\n\n",
           "do $$\ndeclare\n  v_tanks jsonb := (select jsonb_object_agg(code, id) from public.tanks);\n",
           "  v_from bigint;\n  v_to bigint;\n  v_done int := 0;\n  v_skip text[] := '{}';\n  v_zero text[] := '{}';\n",
           "  v_before jsonb;\n  v_result text;\nbegin\n",
           "  select jsonb_object_agg(b.batch_number, s.stage) into v_before from public.batch_stages s\n"
           "    join public.batches b on b.id = s.batch_id where b.batch_number like '26%';\n"]
    for r in rows:
        tag = lit(f'{r["from"]}->{r["to"]} {r["volume_hl"]:g}', 'text')
        out.append(f"\n  select id into v_from from public.batches where batch_number = {lit(r['from'])};\n"
                   f"  select id into v_to from public.batches where batch_number = {lit(r['to'])};\n"
                   "  if exists (select 1 from public.batch_transfers where batch_id = v_from and to_batch_id = v_to\n"
                   f"             and volume_hl = {lit(r['volume_hl'])}) then\n"
                   f"    v_skip := v_skip || {tag};\n  else\n"
                   "    insert into public.batch_transfers (batch_id, from_tank_id, destination, to_batch_id, volume_hl, transferred_at, comment)\n"
                   f"    values (v_from, {'(v_tanks ->> ' + lit(r['tank']) + ')::bigint' if r['tank'] else 'null'}, 'batch', v_to, "
                   f"{lit(r['volume_hl'])}, {lit(r['at'], 'timestamptz')}, {lit(r['comment'])});\n"
                   "    v_done := v_done + 1;\n  end if;\n")
    if zero:
        out.append("\n  -- Receiving batches with an empty brew sheet: only split beer, brew count 0.\n"
                   "  select coalesce(array_agg(batch_number || ' ' || brew_count order by batch_number), '{}') into v_zero\n"
                   f"    from public.batches where batch_number = any({lit(zero)}) and brew_count <> 0;\n"
                   f"  update public.batches set brew_count = 0 where batch_number = any({lit(zero)}) and brew_count <> 0;\n")
    out.append("\n  select format('%s transfers added, already there: %s' || chr(10) || 'brew count -> 0: %s' || chr(10) || 'stage changes: %s',\n"
               "    v_done, coalesce(nullif(array_to_string(v_skip, ', '), ''), 'none'),\n"
               "    coalesce(nullif(array_to_string(v_zero, ', '), ''), 'none'),\n"
               "    coalesce(string_agg(b.batch_number || ' ' || (v_before ->> b.batch_number) || '->' || s.stage, ', ' order by b.batch_number), 'none'))\n"
               "    into v_result from public.batch_stages s join public.batches b on b.id = s.batch_id\n"
               "    where b.batch_number like '26%' and s.stage is distinct from (v_before ->> b.batch_number);\n")
    out.append("  raise exception 'DRY RUN - rolled back. Results: %', v_result;\n" if mode == 'dry_run'
               else "  raise notice 'Done: %', v_result;\n")
    out.append("end $$;\n")
    return ''.join(out)


def main():
    src, app_path, dest = sys.argv[1:4]
    app = json.load(open(app_path))
    books = {}
    for p in sorted(glob.glob(os.path.join(src, '*.json'))):
        d = json.load(open(p))
        if d.get('batch_number'):
            books[d['batch_number']] = d
    rows, zero, skipped = plan(books, app)
    os.makedirs(dest, exist_ok=True)
    for mode in ('dry_run', 'run'):
        text = sql(rows, zero, mode)
        text.encode('ascii')  # plain ASCII or fail here
        with open(os.path.join(dest, f'import_transfers_{mode}.sql'), 'w') as f:
            f.write(text)
    print(f'{len(rows)} transfers, brew count 0 for {len(zero)} batches: {", ".join(zero)}')
    for s in skipped:
        print('skipped:', s)


if __name__ == '__main__':
    main()
