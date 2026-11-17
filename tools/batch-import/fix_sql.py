# Apply Jaap's check-list decisions (fix.json) + transfers. Guarded: a field is only
# changed while the app still holds the value seen at the comparison.
import sys, json
fix = json.load(open('fix.json'))
fix['items'] = [i for i in fix['items'] if '(count)' not in i['c']]
fix['transfers'] = [
  {'from': '26261', 'to': '26354', 'hl': 20.0, 'tank': 'LT53', 'at': '2026-10-28T12:00:00+01:00', 'comment': 'to #26354; date from the log entry "Took 40HL for B.A."; import 2026-11 (Afvulverslag!D45)'},
  {'from': '26261', 'to': '26356', 'hl': 20.0, 'tank': 'LT53', 'at': '2026-10-28T12:00:00+01:00', 'comment': 'to #26356; date from the log entry "Took 40HL for B.A."; import 2026-11 (Afvulverslag!D46)'},
  {'from': '26311', 'to': '26332', 'hl': 23.0, 'tank': 'GLT63', 'at': '2026-10-30T12:00:00+01:00', 'comment': 'to #26332; import 2026-11 (Afvulverslag!D45)'},
  {'from': '26332', 'to': '26370', 'hl': 23.0, 'tank': 'GLT41', 'at': '2026-11-02T12:00:00+01:00', 'comment': 'For Super Dupa #26370; date: processing of 26332; import 2026-11 (Verwerking!E58 + Afvulverslag!D44)'}]
dry = '--dry-run' in sys.argv
doc = json.dumps(fix, ensure_ascii=True, separators=(',', ':')).replace("'", "''")
sql = f"""do $body$
declare
  d jsonb := '{doc}'::jsonb;
  i jsonb; v_b bigint; v_to bigint; v_new jsonb; v_old jsonb; v_loc text; v_n int; v_ok int := 0; v_skip text[] := '{{}}'; v_lines text[] := '{{}}';
begin
  for i in select * from jsonb_array_elements(d->'items') loop
    select id into v_b from public.batches where batch_number = i->>'b';
    if i->>'k' = 'user' then
      v_new := jsonb_build_object(i->>'c', (select id from public.users where initials = i->>'new'));
      v_old := jsonb_build_object(i->>'c', (select id from public.users where initials = i->>'old'));
    elsif i->>'k' = 'tank' then
      v_new := jsonb_build_object(i->>'c', (select id from public.tanks where code = i->>'new'));
      v_old := jsonb_build_object(i->>'c', (select id from public.tanks where code = i->>'old'));
    else
      v_new := jsonb_build_object(i->>'c', i->'new'); v_old := jsonb_build_object(i->>'c', i->'old');
    end if;
    if v_new->(i->>'c') = 'null'::jsonb then v_skip := v_skip || (i->>'b' || ' ' || (i->>'c') || ': unknown ' || (i->>'new')); continue; end if;
    v_loc := case when i->>'t' = 'batches' then 't.id = $3'
             else format('t.batch_id = $3 and t.%1$I = (jsonb_populate_record(null::public.%2$I, $4)).%1$I', (select k from jsonb_object_keys(i->'loc') k), i->>'t') end;
    execute format('update public.%1$I t set %2$I = (jsonb_populate_record(null::public.%1$I, $1)).%2$I where %3$s and t.%2$I is not distinct from (jsonb_populate_record(null::public.%1$I, $2)).%2$I',
                   i->>'t', i->>'c', v_loc) using v_new, v_old, v_b, i->'loc';
    get diagnostics v_n = row_count;
    if v_n = 1 then v_ok := v_ok + 1; else v_skip := v_skip || (i->>'b' || ' ' || (i->>'t') || '.' || (i->>'c') || ' ' || coalesce(i->>'loc', '') || ': ' || v_n || ' rows'); end if;
  end loop;
  v_lines := v_lines || ('updated ' || v_ok);
  for i in select * from jsonb_array_elements(d->'extra') loop
    select id into v_b from public.batches where batch_number = i->>'b';
    if i->>'op' = 'tags' then
      insert into public.fermentation_log_entry_tags (entry_id, batch_id, tag_id)
      select e.id, v_b, t.id from public.fermentation_log_entries e, jsonb_array_elements_text(i->'tags') c join public.cellar_action_tags t on t.code = c
      where e.batch_id = v_b and e.measured_at = (i->>'at')::timestamptz
        and not exists (select 1 from public.fermentation_log_entry_tags x where x.entry_id = e.id and x.tag_id = t.id);
      get diagnostics v_n = row_count; v_lines := v_lines || (i->>'b' || ' tags added ' || v_n);
    else
      delete from public.filling_measurements m using public.filling_sessions s
      where s.id = m.filling_session_id and s.batch_id = v_b and s.session_number = (i->>'s')::int
        and m.tpo_ppb is null and m.hso_ppb is null and m.do_ppb is null and m.headspace_volume is null and m.pressure_bar is null
        and m.temp_c is null and m.co2_gl is null and m.keg_co2_gl is null and m.keg_o2_ppb is null;
      get diagnostics v_n = row_count; v_lines := v_lines || (i->>'b' || ' empty measurements deleted ' || v_n);
    end if;
  end loop;
  for i in select * from jsonb_array_elements(d->'transfers') loop
    select id into v_b from public.batches where batch_number = i->>'from';
    select id into v_to from public.batches where batch_number = i->>'to';
    if v_b is null or v_to is null then raise exception 'transfer %->%: batch not in the app', i->>'from', i->>'to'; end if;
    insert into public.batch_transfers (batch_id, to_batch_id, destination, from_tank_id, volume_hl, transferred_at, comment)
    select v_b, v_to, 'batch', (select id from public.tanks where code = i->>'tank'), (i->>'hl')::numeric, (i->>'at')::timestamptz, i->>'comment'
    where not exists (select 1 from public.batch_transfers x where x.batch_id = v_b and x.to_batch_id = v_to and x.volume_hl = (i->>'hl')::numeric);
    get diagnostics v_n = row_count; v_lines := v_lines || (i->>'from' || '->' || (i->>'to') || ' transfer ' || v_n);
  end loop;
  {"raise exception 'DRY RUN - rolled back. %', array_to_string(v_lines || v_skip, ' | ');" if dry else "raise notice 'Done: %', array_to_string(v_lines || v_skip, ' | ');"}
end
$body$;
"""
open(sys.argv[1], 'w').write(sql); print(len(fix['items']), 'items', len(sql), 'chars')
