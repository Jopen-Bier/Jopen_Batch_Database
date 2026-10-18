-- Architecture clean-up, step 9: domain "production" in English.
-- Mapping: supabase/rename-map.json (approved by Jaap, 16-10-2026).
-- Tables stay in schema public.
--
-- Run by hand in the SQL Editor; registered in
-- supabase_migrations.schema_migrations before the file was pushed.
-- One transaction: everything or nothing.

-- ---------------------------------------------------------------------------
-- 1. batches: two identical creation timestamps; aangemaakt_op is kept
--    (becomes created_at). Fails loudly if they ever differ.
-- ---------------------------------------------------------------------------
do $$ begin
  if exists (select 1 from public.batches where created_at is distinct from aangemaakt_op) then
    raise exception 'batches.created_at differs from aangemaakt_op: not dropped';
  end if;
end $$;
alter table public.batches drop column created_at;

-- ---------------------------------------------------------------------------
-- 2. Batch status values in English.
-- ---------------------------------------------------------------------------
alter table public.batches drop constraint batches_status_check;
update public.batches set status = case status
  when 'gepland' then 'planned' when 'brouwen' then 'brewing' when 'vergisting' then 'fermenting'
  when 'verwerking' then 'processing' when 'afvullen' then 'filling' when 'afgerond' then 'completed' else status end;

-- ---------------------------------------------------------------------------
-- 3. Rename tables and columns.
-- ---------------------------------------------------------------------------
alter table public.batches rename column batchnummer to batch_number;
alter table public.batches rename column aantal_brouwsels to brew_count;
alter table public.batches rename column brouwdatum to brew_date;
alter table public.batches rename column gist_temp_start to yeast_temp_start;
alter table public.batches rename column gist_temp_max to yeast_temp_max;
alter table public.batches rename column giststam to yeast_strain;
alter table public.batches rename column gist_gerehydrateerd to yeast_rehydrated;
alter table public.batches rename column gist_gewicht to yeast_weight;
alter table public.batches rename column gist_bij_1e_brouwsel to yeast_with_first_brew;
alter table public.batches rename column gist_geent_op to yeast_pitched_on;
alter table public.batches rename column gist_door to yeast_pitched_by;
alter table public.batches rename column gist_programma_aan to yeast_program_on;
alter table public.batches rename column datum_orderpicken to order_picking_date;
alter table public.batches rename column bitterheid to bitterness;
alter table public.batches rename column kleur to color;
alter table public.batches rename column glt_leeg to glt_empty;
alter table public.batches rename column totaal_eindvolume to total_final_volume;
alter table public.batches rename column naam to name;
alter table public.batches rename column aangemaakt_op to created_at;
alter table public.batches rename column aangemaakt_door to created_by;

alter table public.brew_capacity rename column max_brouwsels to max_brews;

alter table public.brew_planning rename column aantal_brouwsels to brew_count;
alter table public.brew_planning rename column prio to is_priority;
alter table public.brew_planning rename column notities to notes;
alter table public.brew_planning rename column aangemaakt_door to created_by;
alter table public.brew_planning rename column aangemaakt_op to created_at;
alter table public.brew_planning rename column bijgewerkt_op to updated_at;

alter table public.brew_planning_geschiedenis rename to brew_planning_history;
alter table public.brew_planning_history rename column actie to action;
alter table public.brew_planning_history rename column voor to before;
alter table public.brew_planning_history rename column na to after;
alter table public.brew_planning_history rename column gewijzigd_door to updated_by;
alter table public.brew_planning_history rename column gewijzigd_op to updated_at;

alter table public.brew_planning_splits rename column aangemaakt_op to created_at;

-- ---------------------------------------------------------------------------
-- 4. Constraints, defaults, indexes, sequences, policies.
-- ---------------------------------------------------------------------------
alter table public.batches add constraint batches_status_check
  check (status in ('planned','brewing','fermenting','processing','filling','completed'));
alter table public.batches alter column status set default 'planned';
alter table public.batches rename constraint batches_batchnummer_key to batches_batch_number_key;
alter table public.batches rename constraint batches_aangemaakt_door_fkey to batches_created_by_fkey;
alter index public.idx_batches_batchnummer rename to idx_batches_batch_number;

alter table public.brew_planning rename constraint brew_planning_aangemaakt_door_fkey to brew_planning_created_by_fkey;

alter table public.brew_planning_history rename constraint brew_planning_geschiedenis_pkey to brew_planning_history_pkey;
alter table public.brew_planning_history rename constraint brew_planning_geschiedenis_actie_check to brew_planning_history_action_check;
alter table public.brew_planning_history rename constraint brew_planning_geschiedenis_gewijzigd_door_fkey to brew_planning_history_updated_by_fkey;
alter index public.idx_brew_planning_geschiedenis_gewijzigd_op rename to idx_brew_planning_history_updated_at;
alter index public.idx_brew_planning_geschiedenis_planning_id rename to idx_brew_planning_history_planning_id;
alter policy brew_planning_geschiedenis_select on public.brew_planning_history rename to brew_planning_history_select;

-- ---------------------------------------------------------------------------
-- 5. History trigger on the new names; existing snapshots get the English
--    column names as JSON keys (same as to_jsonb() produces from now on).
-- ---------------------------------------------------------------------------
drop trigger trg_brew_planning_geschiedenis on public.brew_planning;
alter function public.log_brew_planning_wijziging() rename to log_brew_planning_change;
create or replace function public.log_brew_planning_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (TG_OP = 'INSERT') then
    insert into brew_planning_history (brew_planning_id, action, after, updated_by)
    values (new.id, 'created', to_jsonb(new), auth.uid());
    return new;
  elsif (TG_OP = 'UPDATE') then
    insert into brew_planning_history (brew_planning_id, action, before, after, updated_by)
    values (new.id, 'updated', to_jsonb(old), to_jsonb(new), auth.uid());
    return new;
  elsif (TG_OP = 'DELETE') then
    insert into brew_planning_history (brew_planning_id, action, before, updated_by)
    values (old.id, 'deleted', to_jsonb(old), auth.uid());
    return old;
  end if;
  return null;
end;
$$;
create trigger trg_brew_planning_history after insert or update or delete on public.brew_planning
  for each row execute function public.log_brew_planning_change();

create temporary table _step9_keys (old_key text primary key, new_key text not null) on commit drop;
insert into _step9_keys values
  ('aantal_brouwsels','brew_count'), ('prio','is_priority'), ('notities','notes'),
  ('aangemaakt_door','created_by'), ('aangemaakt_op','created_at'), ('bijgewerkt_op','updated_at');

update public.brew_planning_history h
   set before = (select jsonb_object_agg(coalesce(k.new_key, e.key), e.value)
                   from jsonb_each(h.before) e left join _step9_keys k on k.old_key = e.key)
 where h.before is not null;
update public.brew_planning_history h
   set after = (select jsonb_object_agg(coalesce(k.new_key, e.key), e.value)
                  from jsonb_each(h.after) e left join _step9_keys k on k.old_key = e.key)
 where h.after is not null;

-- ---------------------------------------------------------------------------
-- 6. Views. Recreated with English names and output columns.
--    brew_planning_changes was not security_invoker (it bypassed RLS);
--    now it is, like the other views.
-- ---------------------------------------------------------------------------
drop view public.brew_planning_geschiedenis_verrijkt;
drop view public.brew_planning_wijzigingen;

create view public.brew_planning_history_detailed with (security_invoker = true) as
  select h.id, h.brew_planning_id, h.action, h.before, h.after, h.updated_by,
         u.name as updated_by_name, h.updated_at
    from public.brew_planning_history h
    left join public.users u on u.id = h.updated_by
   order by h.updated_at desc;

create view public.brew_planning_changes with (security_invoker = true) as
  select h.id, h.brew_planning_id, h.action,
         (h.before ->> 'week_number')::integer as week_before,
         (h.after ->> 'week_number')::integer as week_after,
         (h.before ->> 'iso_year')::integer as year_before,
         (h.after ->> 'iso_year')::integer as year_after,
         (h.after ->> 'brew_count')::numeric as brews_after,
         (h.after ->> 'is_priority')::boolean as is_priority_after,
         h.after ->> 'plan_group' as plan_group_after,
         h.updated_by, u.name as updated_by_name, h.updated_at
    from public.brew_planning_history h
    left join public.users u on u.id = h.updated_by;

grant select on public.brew_planning_history_detailed to authenticated, service_role;
grant select on public.brew_planning_changes to authenticated, service_role;

-- Fails loudly if a history snapshot still has an old key.
do $$ begin
  if exists (select 1 from public.brew_planning_history h, _step9_keys k
             where h.before ? k.old_key or h.after ? k.old_key) then
    raise exception 'brew_planning_history still has old JSON keys';
  end if;
end $$;
