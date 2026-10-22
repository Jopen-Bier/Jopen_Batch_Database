# Lot numbers from the 2026 batch reports (Jaap, 23-10) into batch_ingredients.lot_number.
# They are on the recipe sheet (Recept-voorblad / Recipe Sheet), one "Lotnummer" /
# "Lot Number" column per block: malts, hops (boil, then dry hops after the WARM row),
# brewhouse additions, dry yeast, cellar additions.
#   python3 -I import_lots.py read <out_dir> <workbook>...      -> <out_dir>/<batch>.json
#   python3 -I import_lots.py sql <out_dir> <dest_dir>           -> import_lots_{dry_run,run}.sql
# The SQL makes the ingredient snapshot where a batch has none yet (as opening the
# Overview does), then fills lot_number by ingredient name (units in brackets and
# spaces ignored), only where it is still empty. Unmatched names are listed.
import sys, os, re, json, glob, datetime
import openpyxl
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # python -I leaves the script folder out
from generate_sql import lit

SHEETS = ('Recept-voorblad', 'Recipe Sheet')
SECTIONS = [  # title above the header row -> addition_type
    (r'malt|mout', 'malt'), (r'hop', 'boil_hop'), (r'brouw|brewer', 'brewhouse_addition'),
    (r'yeast|gist', 'yeast'), (r'cellar|kelder', 'cellar_addition'),
]
STOP = re.compile(r'^(totaal|total|hop totaal|hop total|target water)', re.I)


def lot_text(v):
    if v is None:
        return None
    if isinstance(v, float):
        v = int(v) if v.is_integer() else v
    t = str(v).strip()
    return None if t in ('', '-', '0') else t


def read(path):
    m = re.match(r'^(2\d{4})', os.path.basename(path))
    out = {'batch_number': m.group(1) if m else None, 'source': os.path.basename(path), 'lots': []}
    wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
    try:
        ws = next((wb[s] for s in wb.sheetnames if s.strip() in SHEETS), None)
        if ws is None:
            out['problem'] = 'no recipe sheet'
            return out
        rows = [[c.value for c in row] for row in ws.iter_rows(max_col=14, max_row=140)]
    finally:
        wb.close()
    section, lot_col, title, header = None, None, '', {}
    for row in rows:
        a = row[0].strip() if isinstance(row[0], str) else row[0]
        lot_at = next((i for i, v in enumerate(row) if isinstance(v, str) and v.strip().lower() in ('lotnummer', 'lot number', 'lotnumber')), None)
        if lot_at is not None:
            kind = next((k for rx, k in SECTIONS if re.search(rx, str(title), re.I)), None)
            section, lot_col = kind, lot_at
            # the column labels of this block (KG, EBC, alpha, Gram, Kooktijd, Hoeveelheid, Wanneer, ...)
            header = {i: v.strip() for i, v in enumerate(row) if isinstance(v, str) and v.strip() and i != lot_at}
            continue
        if isinstance(a, str) and a and all(v in (None, '') for v in row[1:]):
            title = a            # a section title row (only column A filled) ends the block
            section = None
            continue
        if section is None:
            continue
        if isinstance(a, str) and STOP.match(a):
            section = None
            continue
        if any(isinstance(v, str) and v.strip().upper() == 'WARM' for v in row[1:]) and section == 'boil_hop':
            section = 'dry_hop'  # the hop block: boil hops, then "WARM", then dry hops
            continue
        if not isinstance(a, str) or a in ('', '-'):
            continue
        lot = lot_text(row[lot_col]) if lot_col < len(row) else None
        if lot:
            out['lots'].append({'type': section, 'name': a, 'lot': lot})
        # the amounts as they are on the sheet (for the next step: the batch's real amounts)
        values = {label: row[i] for i, label in header.items() if i > 0 and i < len(row) and row[i] not in (None, '', '-')}
        if section == 'dry_hop' and 'Gram' not in values and len(row) > 4 and row[4] not in (None, '', '-'):
            values['Gram'] = row[4]          # dry hop rows sit under the boil hop header
        if section == 'dry_hop' and len(row) > 6 and row[6] not in (None, '', '-'):
            values['Kooktijd'] = row[6]
        if section == 'yeast' and len(row) > 10 and isinstance(row[10], str):
            values['unit'] = row[10]
        out.setdefault('rows', []).append({'type': section, 'name': a, 'lot': lot,
                                          'values': {k: (v if isinstance(v, (int, float, str)) else str(v)) for k, v in values.items()}})
    return out


def sql(src, dest):
    rows = []
    for p in sorted(glob.glob(os.path.join(src, '*.json'))):
        d = json.load(open(p))
        for x in d.get('lots', []):
            rows.append((d['batch_number'], x['type'], x['name'], x['lot']))
    values = ',\n    '.join(f'({lit(b)}, {lit(t)}, {lit(n)}, {lit(l)})' for b, t, n, l in rows)
    body = f"""do $$
declare
  r record;
  v_snap int := 0;
  v_set int := 0;
  v_n int;
  v_unmatched text;
  v_result text;
begin
  create temp table _lots (batch_number text, addition_type text, name text, lot text) on commit drop;
  insert into _lots values
    {values};
  alter table _lots add column key text;
  -- the name without a unit in brackets, letters and digits only ("Calcium Chloride (g/brew)" = "calciumchloride")
  update _lots set key = regexp_replace(lower(regexp_replace(name, '\\s*\\([^)]*\\)\\s*$', '')), '[^a-z0-9]', '', 'g');

  -- 1. ingredient snapshot for batches that have none yet (as opening the Overview does)
  for r in select distinct b.id from _lots l join public.batches b on b.batch_number = l.batch_number
           where not exists (select 1 from public.batch_ingredients bi where bi.batch_id = b.id) loop
    perform public.snapshot_batch_ingredients(r.id);
    v_snap := v_snap + 1;
  end loop;

  -- 2. same name and same type, then same name within the family (boil and dry hop are one family)
  for v_n in 1..2 loop
    with m as (
      select distinct on (bi.id) bi.id, l.lot
      from _lots l
      join public.batches b on b.batch_number = l.batch_number
      join public.batch_ingredients bi on bi.batch_id = b.id and not bi.is_removed and bi.lot_number is null
      join public.ingredients i on i.id = bi.ingredient_id
      where regexp_replace(lower(regexp_replace(i.name, '\\s*\\([^)]*\\)\\s*$', '')), '[^a-z0-9]', '', 'g') = l.key
        and (case when v_n = 1 then bi.addition_type = l.addition_type
                  else (case when bi.addition_type in ('boil_hop', 'dry_hop') then 'hop' else bi.addition_type end)
                     = (case when l.addition_type in ('boil_hop', 'dry_hop') then 'hop' else l.addition_type end) end)
      order by bi.id, (bi.addition_type = l.addition_type) desc)
    update public.batch_ingredients bi set lot_number = m.lot from m where bi.id = m.id;
    get diagnostics v_n = row_count;
    v_set := v_set + v_n;
  end loop;

  -- 3. workbook lots that found no ingredient row (by name: how often)
  select string_agg(name || ' x' || n, '; ' order by n desc, name) into v_unmatched
  from (select l.name, count(*) n from _lots l
        join public.batches b on b.batch_number = l.batch_number
        where not exists (select 1 from public.batch_ingredients bi join public.ingredients i on i.id = bi.ingredient_id
                          where bi.batch_id = b.id and bi.lot_number = l.lot
                            and regexp_replace(lower(regexp_replace(i.name, '\\s*\\([^)]*\\)\\s*$', '')), '[^a-z0-9]', '', 'g') = l.key)
        group by l.name order by count(*) desc, l.name limit 80) x;
  v_result := format('%s lots in the workbooks, %s ingredient rows got a lot, %s batches got their ingredient snapshot.'
                     || chr(10) || 'Not matched: %s',
                     (select count(*) from _lots), v_set, v_snap, coalesce(v_unmatched, 'none'));
  --END--
end $$;
"""
    os.makedirs(dest, exist_ok=True)
    for mode, end in (('dry_run', "  raise exception 'DRY RUN - rolled back. Results: %', v_result;"),
                      ('run', "  raise notice 'Done: %', v_result;")):
        text = (f"-- Lot numbers from the 2026 batch reports, {'DRY RUN: ends with an exception, nothing is kept' if mode == 'dry_run' else 'RUN: after the dry run'}.\n"
                f"-- Generated {datetime.date.today().isoformat()} by tools/batch-import/import_lots.py. Only empty lot numbers are filled. Plain ASCII.\n\n"
                + body.replace('  --END--', end))
        text.encode('ascii')
        open(os.path.join(dest, f'import_lots_{mode}.sql'), 'w').write(text)
    print(f'{len(rows)} lots from {len(set(r[0] for r in rows))} batches')


if __name__ == '__main__':
    if sys.argv[1] == 'read':
        os.makedirs(sys.argv[2], exist_ok=True)
        for p in sys.argv[3:]:
            try:
                d = read(p)
            except Exception as e:  # one bad workbook must not stop the run
                print('FAILED', os.path.basename(p), type(e).__name__, e)
                continue
            if d['batch_number']:
                json.dump(d, open(os.path.join(sys.argv[2], d['batch_number'] + '.json'), 'w'), ensure_ascii=False, indent=1)
    else:
        sql(sys.argv[2], sys.argv[3])
