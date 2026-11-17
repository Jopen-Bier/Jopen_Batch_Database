# SQL that fills the gap (gap.json) for a list of batches. Never overwrites a value:
# missing rows are inserted, empty fields filled with coalesce. Per batch it first checks
# the app still holds the row counts seen at the comparison (else: exception, all rolled back).
# Usage: python3 -I gap_sql.py <gap.json> <app.json> <out.sql> [--dry-run] [batch ...]
import sys, json

BREW_COLS = ['software_order_number', 'mash_in_started_at', 'mash_water_hl', 'mash_acid_l', 'mash_rinse_water_hl', 'mash_in_ph',
             'mash_corrected_ph', 'has_mash_schedule_deviation', 'is_iodine_test_ok', 'first_wort_extract', 'last_runnings_extract',
             'last_runnings_ph', 'first_wort_volume_hl', 'cumulative_sparge_volume_hl', 'lauter_time_min', 'boil_start_ph',
             'boil_start_extract', 'boil_start_volume_hl', 'boil_acid_l', 'boil_acid_ph_note', 'boil_time_min', 'boil_end_extract',
             'whirlpool_volume_hl', 'whirlpool_extract', 'whirlpool_ph', 'whirlpool_rest_min', 'aeration_ppm', 'water_addition_hl',
             'brew_volume_hl', 'brewing_ended_at', 'extra_addition']
BATCH_COLS = ['yeast_temp_start', 'yeast_temp_max', 'yeast_strain', 'yeast_rehydrated', 'yeast_weight', 'yeast_with_first_brew',
              'yeast_pitched_on', 'yeast_program_on', 'glt_empty', 'tasting_comment', 'tasting_result']
LOG_COLS = ['extract', 'temp_high', 'temp_low', 'ph', 'comment']
PROC_COLS = ['processing_date', 'start_time', 'end_time', 'outlet', 'discharge_count', 'discharge_interval_min',
             'centrifuge_in_o2_ppb', 'centrifuge_in_co2_gl', 'start_flow_hl_h', 'start_turbidity_ebc']
FILL_COLS = ['filling_date', 'package_format', 'volume_hl', 'start_time', 'end_time', 'is_first_package_checked',
             'is_fill_tube_checked_first', 'is_fill_tube_checked_end', 'are_burst_bottles_controlled']
MEAS_COLS = ['measured_time', 'tpo_ppb', 'hso_ppb', 'do_ppb', 'headspace_volume', 'pressure_bar', 'temp_c', 'co2_gl',
             'keg_co2_gl', 'keg_o2_ppb']
READ_COLS = ['sort_order', 'level_hl', 'o2_ppb', 'co2_gl', 'co2_target', 'comment']

def user(expr):
    return f"(select id from public.users where initials = {expr})"

def sel(cols, r='r'):
    return ', '.join(f'{r}.{c}' for c in cols)

def fill(cols, t='t', r='r'):
    return ', '.join(f'{c} = coalesce({t}.{c}, {r}.{c})' for c in cols)

def template(dry, doc, digest):
    return f"""do $body$
#variable_conflict use_column
declare
  d jsonb := '{doc}'::jsonb;
  k text; g jsonb; e jsonb; x jsonb; v_batch bigint; v_id bigint; v_hbt bigint; v_n int[]; v_exp int[];
  v_before text; v_after text; v_lines text[] := '{{}}';
begin
  if md5(d::text) <> '{digest}' then raise exception 'data checksum mismatch: nothing written'; end if;
  for k, g in select * from jsonb_each(d) loop
    select id into v_batch from public.batches where batch_number = k;
    if v_batch is null then raise exception 'batch % not in the app', k; end if;
    v_exp := array(select jsonb_array_elements_text(g->'expect')::int);
    v_n := array[(select count(*) from public.batch_brews where batch_id = v_batch)::int,
                 (select count(*) from public.fermentation_log_entries where batch_id = v_batch)::int,
                 (select count(*) from public.processing_sessions where batch_id = v_batch)::int,
                 (select count(*) from public.batch_hbts where batch_id = v_batch)::int,
                 (select count(*) from public.filling_sessions where batch_id = v_batch)::int];
    if v_n <> v_exp then
      raise exception 'batch %: the app changed since the comparison (brews/log/proc/hbt/fill now %, expected %)', k, v_n, v_exp;
    end if;
    select stage into v_before from public.batch_stages where batch_id = v_batch;

    -- Batch fields: only where still empty
    if g ? 'batch' then
      update public.batches t set {fill(BATCH_COLS)},
        glt_tank_id = coalesce(t.glt_tank_id, (select id from public.tanks where code = g->'batch'->>'glt_tank')),
        lt_tank_id = coalesce(t.lt_tank_id, (select id from public.tanks where code = g->'batch'->>'lt_tank')),
        yeast_pitched_by = coalesce(t.yeast_pitched_by, {user("g->'batch'->>'yeast_pitched_by'")})
      from jsonb_populate_record(null::public.batches, (g->'batch') - 'yeast_pitched_by'::text) r where t.id = v_batch;
    end if;

    -- Brews: new ones, and empty fields of existing ones
    insert into public.batch_brews (batch_id, brew_number, {', '.join(BREW_COLS)}, brewer_id, brewer_end_id, created_by)
    select v_batch, r.brew_number, {sel(BREW_COLS)}, {user("e->>'brewer'")}, {user("e->>'brewer_end'")}, {user("e->>'brewer'")}
    from jsonb_array_elements(coalesce(g->'new_brews', '[]')) e, jsonb_populate_record(null::public.batch_brews, e) r;
    update public.batch_brews t set {fill(BREW_COLS)},
      brewer_id = coalesce(t.brewer_id, {user("e->>'brewer'")}), brewer_end_id = coalesce(t.brewer_end_id, {user("e->>'brewer_end'")})
    from jsonb_array_elements(coalesce(g->'brew_fields', '[]')) e, jsonb_populate_record(null::public.batch_brews, e) r
    where t.batch_id = v_batch and t.brew_number = r.brew_number;

    -- Fermentation log: new entries with their tags; empty fields of matched entries
    for e in select * from jsonb_array_elements(coalesce(g->'new_log', '[]')) loop
      insert into public.fermentation_log_entries (batch_id, measured_at, {', '.join(LOG_COLS)}, created_by)
      select v_batch, r.measured_at, {sel(LOG_COLS)}, {user("e->>'operator'")}
      from jsonb_populate_record(null::public.fermentation_log_entries, e) r returning id into v_id;
      insert into public.fermentation_log_entry_tags (entry_id, batch_id, tag_id, created_by)
      select v_id, v_batch, t.id, {user("e->>'operator'")}
      from jsonb_array_elements_text(coalesce(e->'tags', '[]')) c join public.cellar_action_tags t on t.code = c;
    end loop;
    update public.fermentation_log_entries t set {fill(LOG_COLS)}
    from jsonb_array_elements(coalesce(g->'log_fields', '[]')) e, jsonb_populate_record(null::public.fermentation_log_entries, e) r
    where t.batch_id = v_batch and t.measured_at = r.measured_at;

    -- Processing sessions and comments
    insert into public.processing_sessions (batch_id, session_number, {', '.join(PROC_COLS)}, tank_id, started_by, ended_by, created_by)
    select v_batch, r.session_number, {sel(PROC_COLS)}, (select id from public.tanks where code = e->>'tank'),
           {user("e->>'started_by'")}, {user("e->>'ended_by'")}, {user("e->>'started_by'")}
    from jsonb_array_elements(coalesce(g->'new_processing', '[]')) e, jsonb_populate_record(null::public.processing_sessions, e - 'started_by'::text - 'ended_by'::text) r;
    update public.processing_sessions t set {fill(PROC_COLS)},
      tank_id = coalesce(t.tank_id, (select id from public.tanks where code = e->>'tank')),
      started_by = coalesce(t.started_by, {user("e->>'started_by'")}), ended_by = coalesce(t.ended_by, {user("e->>'ended_by'")})
    from jsonb_array_elements(coalesce(g->'processing_fields', '[]')) e, jsonb_populate_record(null::public.processing_sessions, e - 'started_by'::text - 'ended_by'::text) r
    where t.batch_id = v_batch and t.session_number = r.session_number;
    insert into public.processing_comments (batch_id, comment_time, comment)
    select v_batch, r.comment_time, r.comment
    from jsonb_array_elements(coalesce(g->'new_processing_comments', '[]')) e, jsonb_populate_record(null::public.processing_comments, e) r;

    -- HBT fills with their readings; readings / averages of existing fills
    for e in select * from jsonb_array_elements(coalesce(g->'new_hbts', '[]')) loop
      insert into public.batch_hbts (batch_id, tank_id, sort_order, intended_formats, avg_pu, avg_turbidity_ebc)
      select v_batch, (select id from public.tanks where code = e->>'tank'), r.sort_order, coalesce(r.intended_formats, '{{}}'), r.avg_pu, r.avg_turbidity_ebc
      from jsonb_populate_record(null::public.batch_hbts, e) r returning id into v_hbt;
      insert into public.hbt_readings (batch_id, batch_hbt_id, processing_session_id, {', '.join(READ_COLS)})
      select v_batch, v_hbt, (select id from public.processing_sessions where batch_id = v_batch and session_number = (e->>'processing_session_number')::int), {sel(READ_COLS)}
      from jsonb_array_elements(coalesce(e->'readings', '[]')) x, jsonb_populate_record(null::public.hbt_readings, x) r;
    end loop;
    update public.batch_hbts t set avg_pu = coalesce(t.avg_pu, r.avg_pu), avg_turbidity_ebc = coalesce(t.avg_turbidity_ebc, r.avg_turbidity_ebc)
    from jsonb_array_elements(coalesce(g->'hbt_fields', '[]')) e, jsonb_populate_record(null::public.batch_hbts, e) r
    where t.batch_id = v_batch and t.sort_order = r.sort_order;
    for e in select * from jsonb_array_elements(coalesce(g->'hbt_readings', '[]')) loop
      insert into public.hbt_readings (batch_id, batch_hbt_id, processing_session_id, {', '.join(READ_COLS)})
      select v_batch, (select id from public.batch_hbts where batch_id = v_batch and sort_order = (e->>'sort_order')::int order by created_at limit 1),
             (select id from public.processing_sessions where batch_id = v_batch and session_number = (e->>'processing_session_number')::int), {sel(READ_COLS)}
      from jsonb_array_elements(e->'readings') x, jsonb_populate_record(null::public.hbt_readings, x) r;
    end loop;

    -- Filling sessions with measurements, articles, materials
    for e in select * from jsonb_array_elements(coalesce(g->'new_filling', '[]')) loop
      insert into public.filling_sessions (batch_id, session_number, batch_hbt_id, {', '.join(FILL_COLS)}, is_hbt_finished, sampled_by, first_package_checked_by, first_package_checked_by_2, created_by)
      select v_batch, r.session_number,
             (select id from public.batch_hbts where batch_id = v_batch and sort_order = (e->>'hbt_sort')::int order by created_at limit 1),
             {sel(FILL_COLS)}, coalesce(r.is_hbt_finished, false), {user("e->>'sampled_by'")}, {user("e->'first_package_checked_by'->>0")}, {user("e->'first_package_checked_by'->>1")}, {user("e->>'filled_by'")}
      from jsonb_populate_record(null::public.filling_sessions, e - 'sampled_by'::text - 'first_package_checked_by'::text - 'also_filled_by'::text) r returning id into v_id;
      insert into public.filling_measurements (batch_id, filling_session_id, {', '.join(MEAS_COLS)})
      select v_batch, v_id, {sel(MEAS_COLS)}
      from jsonb_array_elements(coalesce(e->'measurements', '[]')) x, jsonb_populate_record(null::public.filling_measurements, x) r;
      insert into public.filling_session_articles (batch_id, filling_session_id, article_id, quantity)
      select v_batch, v_id, a.id, sum((x->>'quantity')::numeric)
      from jsonb_array_elements(coalesce(e->'articles', '[]')) x join public.packaging_articles a on a.code = x->>'code' group by a.id;
      insert into public.filling_session_materials (batch_id, filling_session_id, material_id, quantity)
      select v_batch, v_id, m.id, sum((x->>'quantity')::numeric)
      from jsonb_array_elements(coalesce(e->'materials', '[]')) x join public.packaging_materials m on m.code = x->>'code' group by m.id;
    end loop;
    update public.filling_sessions t set {fill(FILL_COLS)}, sampled_by = coalesce(t.sampled_by, {user("e->>'sampled_by'")})
    from jsonb_array_elements(coalesce(g->'filling_fields', '[]')) e, jsonb_populate_record(null::public.filling_sessions, e - 'sampled_by'::text - 'first_package_checked_by'::text - 'also_filled_by'::text) r
    where t.batch_id = v_batch and t.session_number = r.session_number;
    for e in select * from jsonb_array_elements(coalesce(g->'filling_measurements', '[]')) loop
      insert into public.filling_measurements (batch_id, filling_session_id, {', '.join(MEAS_COLS)})
      select v_batch, (select id from public.filling_sessions where batch_id = v_batch and session_number = (e->>'session_number')::int), {sel(MEAS_COLS)}
      from jsonb_array_elements(e->'measurements') x, jsonb_populate_record(null::public.filling_measurements, x) r;
    end loop;
    insert into public.filling_session_articles (batch_id, filling_session_id, article_id, quantity)
    select v_batch, s.id, a.id, (x->>'quantity')::numeric
    from jsonb_array_elements(coalesce(g->'filling_articles', '[]')) x
    join public.filling_sessions s on s.batch_id = v_batch and s.session_number = (x->>'session_number')::int
    join public.packaging_articles a on a.code = x->>'code';
    insert into public.filling_session_materials (batch_id, filling_session_id, material_id, quantity)
    select v_batch, s.id, m.id, (x->>'quantity')::numeric
    from jsonb_array_elements(coalesce(g->'filling_materials', '[]')) x
    join public.filling_sessions s on s.batch_id = v_batch and s.session_number = (x->>'session_number')::int
    join public.packaging_materials m on m.code = x->>'code';

    select stage into v_after from public.batch_stages where batch_id = v_batch;
    v_lines := v_lines || (k || ' ' || coalesce(v_before, '-') || '->' || coalesce(v_after, '-') ||
      ' brews ' || (select count(*) from public.batch_brews where batch_id = v_batch) ||
      ' log ' || (select count(*) from public.fermentation_log_entries where batch_id = v_batch) ||
      ' proc ' || (select count(*) from public.processing_sessions where batch_id = v_batch) ||
      ' hbt ' || (select count(*) from public.batch_hbts where batch_id = v_batch) ||
      ' readings ' || (select count(*) from public.hbt_readings where batch_id = v_batch) ||
      ' fill ' || (select count(*) from public.filling_sessions where batch_id = v_batch) ||
      ' meas ' || (select count(*) from public.filling_measurements where batch_id = v_batch));
  end loop;
  {"raise exception 'DRY RUN - rolled back. Results: %', array_to_string(v_lines, ' | ');" if dry else "raise notice 'Done: %', array_to_string(v_lines, ' | ');"}
end
$body$;
"""

def main():
    gap_path, app_path, out = sys.argv[1:4]
    dry = '--dry-run' in sys.argv
    only = [a for a in sys.argv[4:] if not a.startswith('--')]
    gap, app = json.load(open(gap_path)), json.load(open(app_path))
    data = {}
    for n, g in gap.items():
        if only and n not in only:
            continue
        g = {k: v for k, v in g.items() if k != 'check'}
        if not g:
            continue
        a = app[n]
        g['expect'] = [len(a.get(t) or []) for t in ('brews', 'fermentation_log', 'processing_sessions', 'hbts', 'filling_sessions')]
        data[n] = g
    if '--strip' in sys.argv:
        for g in data.values():
            for sec in ('new_hbts', 'new_filling'):
                for r in g.get(sec, []):
                    for k in ('hbt_tank', 'from_report_only', 'also_filled_by', 'end_level_hl', 'split_to', 'hbt_index'):
                        r.pop(k, None)
    doc = json.dumps(data, ensure_ascii=True, separators=(',', ':')).replace("'", "''")
    import subprocess
    digest = subprocess.run(['psql', '-h', '/tmp', '-p', '5433', '-U', 'postgres', '-d', 't', '-tA', '-c',
                             "select md5('" + doc + "'::jsonb::text)"], capture_output=True, text=True, check=True).stdout.strip()
    sql = template(dry, doc, digest)
    open(out, 'w').write(sql)
    print(out, len(data), 'batches', len(sql), 'chars')

main()
