--
-- PostgreSQL database dump
--



SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA public;


--
-- Name: brew_plan_group; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.brew_plan_group AS ENUM (
    'jk',
    'wp_60hl',
    'wp_120hl',
    'wp_320hl'
);


--
-- Name: admin_get_last_logins(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.admin_get_last_logins() RETURNS TABLE(id uuid, last_login_at timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  if not is_admin() then
    raise exception 'Not authorized';
  end if;
  return query select au.id, au.last_sign_in_at from auth.users au;
end;
$$;


--
-- Name: apply_cellar_plan_order(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.apply_cellar_plan_order() RETURNS integer
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare
  r record;
  v_n integer := 0;
begin
  -- auth.uid() is empty only for the migration owner (below).
  if auth.uid() is not null and not (can_edit('settings') and can_edit('recipes')) then
    raise exception 'needs edit rights on settings and recipes' using errcode = '42501';
  end if;
  for r in select id from recipes
           where status = 'active' or id in (select recipe_id from batches where status = 'planned')
           order by id loop
    perform generate_recipe_cellar_steps(r.id, true);
    v_n := v_n + 1;
  end loop;

  delete from batch_cellar_steps s
  using batches b
  where b.id = s.batch_id and b.status = 'planned'
    and not exists (select 1 from fermentation_log_entries e where e.batch_id = b.id);
  perform snapshot_batch_cellar_steps(b.id)
  from batches b
  where b.status = 'planned'
    and not exists (select 1 from batch_cellar_steps s where s.batch_id = b.id);
  return v_n;
end;
$$;


--
-- Name: can_delete(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.can_delete(p_module_key text) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select is_admin() or exists (
    select 1 from role_permissions rp
    where rp.role_id = current_role_id() and rp.module_key = p_module_key and rp.can_delete
  );
$$;


--
-- Name: can_edit(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.can_edit(p_module_key text) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select is_admin() or exists (
    select 1 from role_permissions rp
    where rp.role_id = current_role_id() and rp.module_key = p_module_key and rp.can_edit
  );
$$;


--
-- Name: can_view(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.can_view(p_module_key text) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select is_admin() or exists (
    select 1 from role_permissions rp
    where rp.role_id = current_role_id() and rp.module_key = p_module_key and rp.can_view
  );
$$;


--
-- Name: current_role_id(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.current_role_id() RETURNS integer
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select role_id from users where id = auth.uid() and is_active;
$$;


--
-- Name: generate_recipe_cellar_steps(bigint, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.generate_recipe_cellar_steps(p_recipe_id bigint, p_reset_order boolean DEFAULT false) RETURNS integer
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $_$
declare
  v_ferm      recipe_fermentation%rowtype;
  v_ps        recipe_process_steps%rowtype;
  v_spec      recipe_specs%rowtype;
  v_lag_temp  numeric;
  v_lag_label text;
  v_part      record;
  v_cold      record;
  v_line      record;
  v_n         integer := 0;
  v_count     integer;
  v_cooled    boolean := false;   -- a cooling step is already planned
  v_cold_hop  boolean := false;   -- a cold dry hop comes before the lagering cooling
  v_tag       text;               -- tag of the part (Settings › Cellar plan)
begin
  -- auth.uid() is empty only for the migration owner (backfill below).
  if auth.uid() is not null and not can_edit('recipes') then
    raise exception 'no edit rights on recipes' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtext('generate_recipe_cellar_steps'), p_recipe_id::integer);

  select * into v_ferm from recipe_fermentation where recipe_id = p_recipe_id;
  select * into v_ps from recipe_process_steps where recipe_id = p_recipe_id;
  select * into v_spec from recipe_specs where recipe_id = p_recipe_id;
  v_lag_temp := v_ferm.lagering_temp;
  -- 0 °P final extract / warm dry hop extract means "not filled in".
  v_spec.final_extract := nullif(v_spec.final_extract, 0);
  v_ferm.dry_hop_warm_extract_1 := nullif(v_ferm.dry_hop_warm_extract_1, 0);
  v_lag_label := coalesce(v_lag_temp::float8 || ' °C', 'lagering temperature');

  create temporary table if not exists _gen_steps (
    n integer, generated_key text, tag_code text, title text, description text,
    trigger_type text, trigger_value numeric, trigger_tol numeric, planned_day numeric,
    recipe_ingredient_ids bigint[], starts_lagering boolean
  ) on commit drop;

  for v_part in select * from cellar_plan_parts where shows_on = 'cellar_plan' order by sort_order, id loop
    select t.code into v_tag from cellar_action_tags t where t.id = v_part.tag_id;

    if v_part.kind = 'dry_warm' then
      if exists (select 1 from recipe_ingredients where recipe_id = p_recipe_id and addition_type = 'dry_hop'
                 and lower(btrim(timing)) like 'warm%') then
        v_n := v_n + 1;
        insert into _gen_steps
        select v_n, 'dry_warm', v_tag, 'Dry warm',
               nullif(concat_ws(' · ',
                 case when v_ferm.dry_hop_warm_temp is not null then 'at ' || v_ferm.dry_hop_warm_temp::float8 || ' °C' end,
                 nullif(btrim(v_ps.dry_hop_method_warm), ''), nullif(btrim(v_ps.dry_hop_comment_warm), '')), ''),
               case when v_ferm.dry_hop_warm_extract_1 is not null then 'extract'
                    when v_ps.dry_hop_1_day is not null then 'day' else 'after_previous' end,
               v_ferm.dry_hop_warm_extract_1,
               case when v_ferm.dry_hop_warm_extract_1 is not null then tolerance_value(v_ferm.dry_hop_warm_extract_1_tol) end,
               v_ps.dry_hop_1_day,
               array(select id from recipe_ingredients where recipe_id = p_recipe_id and addition_type = 'dry_hop'
                     and lower(btrim(timing)) like 'warm%' order by sort_order, id),
               false;
      end if;

    elsif v_part.kind = 'cold_dry_hop' then
      -- Per cold dry hop temperature above the lagering temperature (warmest
      -- first): cool, then dry hop.
      for v_cold in
        select (substring(lower(btrim(timing)) from '^cold_(-?[0-9]+(?:\.[0-9]+)?)$'))::numeric as temp,
               array_agg(id order by sort_order, id) as ids
        from recipe_ingredients
        where recipe_id = p_recipe_id and addition_type = 'dry_hop' and lower(btrim(timing)) ~ '^cold_-?[0-9]'
        group by 1
        having v_lag_temp is null or (substring(lower(btrim(timing)) from '^cold_(-?[0-9]+(?:\.[0-9]+)?)$'))::numeric > v_lag_temp
        order by 1 desc
      loop
        v_n := v_n + 1;
        insert into _gen_steps values (v_n, 'cooling_dry_hop:' || v_cold.temp::float8, v_tag,
          'Cooling to ' || v_cold.temp::float8 || ' °C', null,
          case when v_cooled or v_spec.final_extract is null then 'after_previous' else 'extract' end,
          case when v_cooled then null else v_spec.final_extract end,
          case when v_cooled then null else tolerance_value(v_spec.final_extract_tol) end,
          null, '{}', false);
        v_n := v_n + 1;
        insert into _gen_steps values (v_n, 'dry_hop:' || v_cold.temp::float8, 'dryhopping',
          'Dryhopping @' || v_cold.temp::float8 || ' °C',
          nullif(concat_ws(' · ', nullif(btrim(v_ps.dry_hop_method_16c), ''), nullif(btrim(v_ps.dry_hop_comment_16c), '')), ''),
          'after_previous', null, null, null, v_cold.ids, false);
        v_cooled := true;
        v_cold_hop := true;
      end loop;
      -- Dry hops without a timing: shown here so they are not forgotten.
      if exists (select 1 from recipe_ingredients where recipe_id = p_recipe_id and addition_type = 'dry_hop'
                 and nullif(btrim(timing), '') is null) then
        v_n := v_n + 1;
        insert into _gen_steps
        select v_n, 'dry_hop:unset', 'dryhopping', 'Dryhopping', 'Timing not set in the recipe',
               'after_previous', null, null, null,
               array(select id from recipe_ingredients where recipe_id = p_recipe_id and addition_type = 'dry_hop'
                     and nullif(btrim(timing), '') is null order by sort_order, id),
               false;
        v_cold_hop := true;
      end if;

    elsif v_part.kind = 'cooling_lagering' then
      v_n := v_n + 1;
      insert into _gen_steps values (v_n, 'cooling_lagering', v_tag, 'Cooling to ' || v_lag_label,
        nullif(concat_ws(' · ', 'Lagering temperature from recipe',
          case when v_ferm.lagering_time is not null then v_ferm.lagering_time::float8 || ' days' end,
          case when v_cold_hop then 'cool < 24 h after the dry hop' end), ''),
        case when v_cooled or v_spec.final_extract is null then 'after_previous' else 'extract' end,
        case when v_cooled then null else v_spec.final_extract end,
        case when v_cooled then null else tolerance_value(v_spec.final_extract_tol) end,
        null, '{}', true);
      v_cooled := true;

    elsif v_part.kind = 'sample_lab' then
      v_n := v_n + 1;
      insert into _gen_steps values (v_n, 'sample_lab', v_tag, 'Sample to lab', 'Always after cooling',
        'after_previous', null, null, null, '{}', false);

    elsif v_part.kind = 'dry_hop_at_lagering' then
      -- Cold dry hop at or below the lagering temperature (e.g. cold_2 with
      -- lagering at 2 °C).
      for v_cold in
        select (substring(lower(btrim(timing)) from '^cold_(-?[0-9]+(?:\.[0-9]+)?)$'))::numeric as temp,
               array_agg(id order by sort_order, id) as ids
        from recipe_ingredients
        where recipe_id = p_recipe_id and addition_type = 'dry_hop' and lower(btrim(timing)) ~ '^cold_-?[0-9]'
        group by 1
        having v_lag_temp is not null and (substring(lower(btrim(timing)) from '^cold_(-?[0-9]+(?:\.[0-9]+)?)$'))::numeric <= v_lag_temp
        order by 1 desc
      loop
        v_n := v_n + 1;
        insert into _gen_steps values (v_n, 'dry_hop:' || v_cold.temp::float8, v_tag,
          'Dryhopping @' || v_cold.temp::float8 || ' °C',
          nullif(concat_ws(' · ', nullif(btrim(v_ps.dry_hop_method_16c), ''), nullif(btrim(v_ps.dry_hop_comment_16c), '')), ''),
          'after_previous', null, null, null, v_cold.ids, false);
      end loop;

    else
      -- A timing value of cellar additions: one step per line with it.
      for v_line in
        select ri.id, coalesce(i.name, nullif(btrim(ri.note), ''), 'cellar addition') as name, ri.note
        from recipe_ingredients ri left join ingredients i on i.id = ri.ingredient_id
        where ri.recipe_id = p_recipe_id and ri.addition_type = 'cellar_addition'
          and lower(btrim(ri.timing)) = v_part.code
        order by ri.sort_order, ri.id
      loop
        v_n := v_n + 1;
        insert into _gen_steps values (v_n, 'addition:' || v_line.id, v_tag, 'Addition · ' || v_line.name,
          nullif(concat_ws(' · ', case when not v_part.on_addition_day then lower(left(v_part.label, 1)) || substr(v_part.label, 2) end,
                                  nullif(btrim(v_line.note), '')), ''),
          case when v_part.on_addition_day and v_ps.cellar_addition_day is not null then 'day' else 'after_previous' end,
          null, null,
          case when v_part.on_addition_day then v_ps.cellar_addition_day end,
          array[v_line.id], false);
      end loop;
    end if;
  end loop;

  -- Cellar additions with a timing that is not a value in Settings (or none):
  -- at the end, to check in the recipe.
  for v_line in
    select ri.id, coalesce(i.name, nullif(btrim(ri.note), ''), 'cellar addition') as name, ri.note
    from recipe_ingredients ri left join ingredients i on i.id = ri.ingredient_id
    where ri.recipe_id = p_recipe_id and ri.addition_type = 'cellar_addition'
      and not exists (select 1 from cellar_plan_parts p where p.kind = 'addition_timing' and p.code = lower(btrim(ri.timing)))
    order by ri.sort_order, ri.id
  loop
    v_n := v_n + 1;
    insert into _gen_steps values (v_n, 'addition:' || v_line.id, 'addition', 'Addition · ' || v_line.name,
      nullif(concat_ws(' · ', 'timing to check in the recipe', nullif(btrim(v_line.note), '')), ''),
      case when v_ps.cellar_addition_day is not null then 'day' else 'after_previous' end,
      null, null, v_ps.cellar_addition_day, array[v_line.id], false);
  end loop;

  -- Apply: generated rows take the new content (their place in the plan is
  -- kept, it may have been moved by hand); rows changed by hand only get
  -- their linked lines refreshed; generated rows not asked for go.
  delete from recipe_cellar_steps s
  where s.recipe_id = p_recipe_id and s.is_generated
    and not exists (select 1 from _gen_steps g where g.generated_key = s.generated_key);

  update recipe_cellar_steps s
  set tag_id = t.id, title = g.title, description = g.description, trigger_type = g.trigger_type,
      trigger_value = g.trigger_value, trigger_tol = g.trigger_tol, planned_day = g.planned_day,
      recipe_ingredient_ids = g.recipe_ingredient_ids, starts_lagering = g.starts_lagering,
      updated_by = auth.uid()
  from _gen_steps g join cellar_action_tags t on t.code = g.tag_code
  where s.recipe_id = p_recipe_id and s.is_generated and s.generated_key = g.generated_key
    and (s.tag_id, s.title, s.description, s.trigger_type, s.trigger_value, s.trigger_tol, s.planned_day,
         s.recipe_ingredient_ids, s.starts_lagering)
        is distinct from
        (t.id, g.title, g.description, g.trigger_type, g.trigger_value, g.trigger_tol, g.planned_day,
         g.recipe_ingredient_ids, g.starts_lagering);

  update recipe_cellar_steps s
  set recipe_ingredient_ids = g.recipe_ingredient_ids, updated_by = auth.uid()
  from _gen_steps g
  where s.recipe_id = p_recipe_id and not s.is_generated and s.generated_key = g.generated_key
    and s.recipe_ingredient_ids is distinct from g.recipe_ingredient_ids;

  -- New generated steps go right after the step generated before them.
  insert into recipe_cellar_steps (recipe_id, sort_order, tag_id, title, description, trigger_type,
    trigger_value, trigger_tol, planned_day, recipe_ingredient_ids, starts_lagering, is_generated, generated_key)
  select p_recipe_id,
         coalesce((select max(s.sort_order) from recipe_cellar_steps s join _gen_steps p on p.generated_key = s.generated_key
                   where s.recipe_id = p_recipe_id and p.n < g.n), 0) + 1,
         t.id, g.title, g.description, g.trigger_type, g.trigger_value, g.trigger_tol, g.planned_day,
         g.recipe_ingredient_ids, g.starts_lagering, true, g.generated_key
  from _gen_steps g join cellar_action_tags t on t.code = g.tag_code
  where not exists (select 1 from recipe_cellar_steps s where s.recipe_id = p_recipe_id and s.generated_key = g.generated_key)
  order by g.n;

  -- Renumber 10, 20, 30 … in the resulting order. With p_reset_order a step
  -- with a generated key takes its place in the generated order; any other
  -- step stays right after the keyed step it followed.
  update recipe_cellar_steps s
  set sort_order = o.rn * 10
  from (
    select x.id, row_number() over (
             order by case when p_reset_order then coalesce(x.n, x.anchor_n) else 0 end,
                      case when p_reset_order and x.n is null then 1 else 0 end, x.sort_order, x.id) as rn
    from (
      select s2.id, s2.sort_order, g.n,
             coalesce((select max(g3.n) from recipe_cellar_steps s3 join _gen_steps g3 on g3.generated_key = s3.generated_key
                       where s3.recipe_id = p_recipe_id
                         and (s3.sort_order < s2.sort_order or (s3.sort_order = s2.sort_order and s3.id < s2.id))), 0) as anchor_n
      from recipe_cellar_steps s2
      left join _gen_steps g on g.generated_key = s2.generated_key
      where s2.recipe_id = p_recipe_id
    ) x
  ) o
  where s.id = o.id and s.sort_order <> o.rn * 10;

  drop table _gen_steps;   -- the next call may run as another role
  select count(*) into v_count from recipe_cellar_steps where recipe_id = p_recipe_id;
  return v_count;
end;
$_$;


--
-- Name: is_admin(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_admin() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select exists (
    select 1 from users u join roles r on r.id = u.role_id
    where u.id = auth.uid() and u.is_active and r.name = 'admin'
  );
$$;


--
-- Name: log_batch_change(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.log_batch_change() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_old    jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  v_new    jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  v_row    jsonb := coalesce(v_new, v_old);
  v_row_id text;
begin
  if tg_op = 'UPDATE' and v_old = v_new then
    return null;
  end if;

  if tg_nargs = 0 then
    v_row_id := v_row ->> 'id';
  else
    select string_agg(v_row ->> k, ':' order by ord)
    into v_row_id
    from unnest(tg_argv) with ordinality as a(k, ord);
  end if;

  insert into batch_audit_log (batch_id, table_name, row_id, action, old_data, new_data)
  values ((v_row ->> 'batch_id')::bigint, tg_table_name, v_row_id, lower(tg_op), v_old, v_new);

  return null;
end;
$$;


--
-- Name: log_brew_planning_change(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.log_brew_planning_change() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
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


--
-- Name: product_sheet_calculated_color(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.product_sheet_calculated_color(p_recipe_id bigint) RETURNS numeric
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
                                                                                                                                                                                             select round(
                                                                                                                                                                                                 coalesce(sum(ri.quantity * ri.color_ebc * 0.08), 0) / nullif(r.brew_volume_hl, 0) + 1.75
                                                                                                                                                                                                   , 2)
                                                                                                                                                                                                     from recipes r
                                                                                                                                                                                                       left join recipe_ingredients ri on ri.recipe_id = r.id and ri.addition_type = 'malt'
                                                                                                                                                                                                         where r.id = p_recipe_id
                                                                                                                                                                                                           group by r.brew_volume_hl
                                                                                                                                                                                                           $$;


--
-- Name: product_sheet_relevant_hash(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.product_sheet_relevant_hash(p_recipe_group_id uuid) RETURNS text
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
                                                                                                                                                                                                             select md5(
                                                                                                                                                                                                                 coalesce(s.original_extract::text,'') || '|' || coalesce(s.original_extract_tol,'') || '|' ||
                                                                                                                                                                                                                     coalesce(s.final_extract::text,'') || '|' || coalesce(s.final_extract_tol,'') || '|' ||
                                                                                                                                                                                                                         coalesce(s.alcohol::text,'') || '|' || coalesce(s.alcohol_tol,'') || '|' ||
                                                                                                                                                                                                                             coalesce(s.bitterness::text,'') || '|' || coalesce(s.bitterness_tol,'') || '|' ||
                                                                                                                                                                                                                                 coalesce(product_sheet_calculated_color(r.id)::text,'') || '|' || coalesce(s.color_tol,'') || '|' ||
                                                                                                                                                                                                                                     coalesce(s.ph::text,'') || '|' || coalesce(s.ph_tol,'') || '|' ||
                                                                                                                                                                                                                                         coalesce(s.turbidity_lab::text,'') || '|' || coalesce(s.turbidity_lab_tol,'') || '|' ||
                                                                                                                                                                                                                                             coalesce(s.co2_bottle::text,'') || '|' || coalesce(s.co2_bottle_tol,'') || '|' ||
                                                                                                                                                                                                                                                 coalesce(s.co2_can::text,'') || '|' || coalesce(s.co2_can_tol,'') || '|' ||
                                                                                                                                                                                                                                                     coalesce(s.co2_keg::text,'') || '|' || coalesce(s.co2_keg_tol,'') || '|' ||
                                                                                                                                                                                                                                                         coalesce(s.headspace_o2::text,'') || '|' || coalesce(s.headspace_o2_tol,'') || '|' ||
                                                                                                                                                                                                                                                             coalesce(s.dissolved_o2::text,'') || '|' || coalesce(s.dissolved_o2_tol,'') || '|' ||
                                                                                                                                                                                                                                                                 coalesce(r.flavor_description,'') || '|' ||
                                                                                                                                                                                                                                                                     coalesce(array_to_string(r.flavor_keywords, ','),'') || '|' ||
                                                                                                                                                                                                                                                                         coalesce(r.color_free_text,'') || '|' ||
                                                                                                                                                                                                                                                                             coalesce(r.serving_temperature::text,'') || '|' ||
                                                                                                                                                                                                                                                                                 coalesce((
                                                                                                                                                                                                                                                                                       select string_agg(ri.ingredient_id::text || ':' || coalesce(ri.quantity::text,'') || ':' || coalesce(ri.unit,'') || ':' || ri.addition_type, ',' order by ri.ingredient_id, ri.addition_type)
                                                                                                                                                                                                                                                                                             from recipe_ingredients ri where ri.recipe_id = r.id
                                                                                                                                                                                                                                                                                                 ), '') || '|' ||
                                                                                                                                                                                                                                                                                                     coalesce((
                                                                                                                                                                                                                                                                                                           select string_agg(coalesce(i.ingredient_declaration,'') || ':' || coalesce(i.allergens, '[]'::jsonb)::text, ',' order by i.id)
                                                                                                                                                                                                                                                                                                                 from recipe_ingredients ri2 join ingredients i on i.id = ri2.ingredient_id
                                                                                                                                                                                                                                                                                                                       where ri2.recipe_id = r.id
                                                                                                                                                                                                                                                                                                                           ), '')
                                                                                                                                                                                                                                                                                                                             )
                                                                                                                                                                                                                                                                                                                               from recipes r
                                                                                                                                                                                                                                                                                                                                 left join recipe_specs s on s.recipe_id = r.id
                                                                                                                                                                                                                                                                                                                                   where r.id = product_sheet_relevant_recipe_id(p_recipe_group_id)
                                                                                                                                                                                                                                                                                                                                   $$;


--
-- Name: product_sheet_relevant_recipe_id(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.product_sheet_relevant_recipe_id(p_recipe_group_id uuid) RETURNS bigint
    LANGUAGE sql STABLE
    SET search_path TO 'public'
    AS $$
                                                                                                                                                                                     select id from recipes
                                                                                                                                                                                       where recipe_group_id = p_recipe_group_id
                                                                                                                                                                                         order by version_major desc, version_minor desc
                                                                                                                                                                                           limit 1
                                                                                                                                                                                           $$;


--
-- Name: save_recipe_cellar_steps(bigint, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.save_recipe_cellar_steps(p_recipe_id bigint, p_steps jsonb) RETURNS integer
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare
  v_keep bigint[];
begin
  if not can_edit('recipes') then
    raise exception 'no edit rights on recipes' using errcode = '42501';
  end if;
  if jsonb_typeof(coalesce(p_steps, '[]'::jsonb)) <> 'array' then
    raise exception 'p_steps must be a JSON array';
  end if;

  select coalesce(array_agg((e ->> 'id')::bigint), '{}') into v_keep
  from jsonb_array_elements(coalesce(p_steps, '[]'::jsonb)) e
  where (e ->> 'id') is not null
    and exists (select 1 from recipe_cellar_steps s where s.id = (e ->> 'id')::bigint and s.recipe_id = p_recipe_id);

  delete from recipe_cellar_steps where recipe_id = p_recipe_id and id <> all (v_keep);

  update recipe_cellar_steps s
  set sort_order = (e ->> 'sort_order')::integer,
      tag_id = (e ->> 'tag_id')::bigint,
      title = e ->> 'title',
      description = nullif(btrim(e ->> 'description'), ''),
      trigger_type = e ->> 'trigger_type',
      trigger_value = (e ->> 'trigger_value')::numeric,
      trigger_tol = (e ->> 'trigger_tol')::numeric,
      planned_day = (e ->> 'planned_day')::numeric,
      starts_lagering = coalesce((e ->> 'starts_lagering')::boolean, false),
      is_generated = coalesce((e ->> 'is_generated')::boolean, false),
      updated_by = auth.uid()
  from jsonb_array_elements(p_steps) e
  where s.recipe_id = p_recipe_id and s.id = (e ->> 'id')::bigint
    and (s.sort_order, s.tag_id, s.title, s.description, s.trigger_type, s.trigger_value, s.trigger_tol,
         s.planned_day, s.starts_lagering, s.is_generated)
        is distinct from
        ((e ->> 'sort_order')::integer, (e ->> 'tag_id')::bigint, e ->> 'title', nullif(btrim(e ->> 'description'), ''),
         e ->> 'trigger_type', (e ->> 'trigger_value')::numeric, (e ->> 'trigger_tol')::numeric,
         (e ->> 'planned_day')::numeric, coalesce((e ->> 'starts_lagering')::boolean, false),
         coalesce((e ->> 'is_generated')::boolean, false));

  insert into recipe_cellar_steps (recipe_id, sort_order, tag_id, title, description, trigger_type,
    trigger_value, trigger_tol, planned_day, starts_lagering, is_generated, generated_key)
  select p_recipe_id, (e ->> 'sort_order')::integer, (e ->> 'tag_id')::bigint, e ->> 'title',
         nullif(btrim(e ->> 'description'), ''), e ->> 'trigger_type', (e ->> 'trigger_value')::numeric,
         (e ->> 'trigger_tol')::numeric, (e ->> 'planned_day')::numeric,
         coalesce((e ->> 'starts_lagering')::boolean, false), coalesce((e ->> 'is_generated')::boolean, false),
         e ->> 'generated_key'
  from jsonb_array_elements(coalesce(p_steps, '[]'::jsonb)) e
  where (e ->> 'id') is null or not ((e ->> 'id')::bigint = any (v_keep));

  return generate_recipe_cellar_steps(p_recipe_id);
end;
$$;


--
-- Name: save_recipe_ingredients(bigint, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.save_recipe_ingredients(p_recipe_id bigint, p_lines jsonb) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
declare
  v_keep bigint[];
begin
  -- RLS would only silently skip rows; say it instead
  if auth.uid() is not null and not can_edit('recipes') then
    raise exception 'no edit rights on recipes' using errcode = '42501';
  end if;

  if jsonb_typeof(coalesce(p_lines, '[]'::jsonb)) <> 'array' then
    raise exception 'p_lines must be a JSON array' using errcode = '22023';
  end if;

  if exists (
    select 1 from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) as l
    where l ->> 'id' is not null
    group by l ->> 'id' having count(*) > 1
  ) then
    raise exception 'the same ingredient line occurs twice' using errcode = '22023';
  end if;

  -- ids in the list that are lines of this recipe
  select coalesce(array_agg(ri.id), '{}')
  into v_keep
  from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) as l
  join recipe_ingredients ri on ri.id = (l ->> 'id')::bigint and ri.recipe_id = p_recipe_id;

  delete from recipe_ingredients
  where recipe_id = p_recipe_id
    and not (id = any (v_keep));

  update recipe_ingredients ri
  set ingredient_id          = (l ->> 'ingredient_id')::bigint,
      addition_type          = l ->> 'addition_type',
      quantity               = (l ->> 'quantity')::numeric,
      unit                   = l ->> 'unit',
      timing                 = l ->> 'timing',
      sort_order             = (l ->> 'sort_order')::integer,
      note                   = l ->> 'note',
      hop_dosing_tank        = (l ->> 'hop_dosing_tank')::integer,
      alpha_pct              = (l ->> 'alpha_pct')::numeric,
      color_ebc              = (l ->> 'color_ebc')::numeric,
      all_in_first_brew      = coalesce((l ->> 'all_in_first_brew')::boolean, false),
      source_recipe_group_id = (l ->> 'source_recipe_group_id')::uuid
  from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) as l
  where ri.id = (l ->> 'id')::bigint
    and ri.id = any (v_keep);

  insert into recipe_ingredients (
    recipe_id, ingredient_id, addition_type, quantity, unit, timing, sort_order,
    note, hop_dosing_tank, alpha_pct, color_ebc, all_in_first_brew, source_recipe_group_id)
  select p_recipe_id,
         (l ->> 'ingredient_id')::bigint,
         l ->> 'addition_type',
         (l ->> 'quantity')::numeric,
         l ->> 'unit',
         l ->> 'timing',
         (l ->> 'sort_order')::integer,
         l ->> 'note',
         (l ->> 'hop_dosing_tank')::integer,
         (l ->> 'alpha_pct')::numeric,
         (l ->> 'color_ebc')::numeric,
         coalesce((l ->> 'all_in_first_brew')::boolean, false),
         (l ->> 'source_recipe_group_id')::uuid
  from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) with ordinality as t(l, ord)
  where l ->> 'id' is null
     or not ((l ->> 'id')::bigint = any (v_keep))
  order by ord;
end;
$$;


--
-- Name: set_last_login(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_last_login() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  update users set last_login_at = now() where id = auth.uid();
end;
$$;


--
-- Name: set_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  new.updated_at := now();
  return new;
end;
$$;


--
-- Name: snapshot_batch_cellar_steps(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.snapshot_batch_cellar_steps(p_batch_id bigint) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_count integer;
begin
  if auth.uid() is not null and not can_view('batches') then
    raise exception 'no access to batches' using errcode = '42501';
  end if;

  perform pg_advisory_xact_lock(hashtext('snapshot_batch_cellar_steps'), p_batch_id::integer);

  if exists (select 1 from batch_cellar_steps where batch_id = p_batch_id) then
    return 0;
  end if;

  insert into batch_cellar_steps (batch_id, recipe_cellar_step_id, sort_order, tag_id, title, description,
    trigger_type, trigger_value, trigger_tol, planned_day, recipe_ingredient_ids, starts_lagering)
  select b.id, s.id, s.sort_order, s.tag_id, s.title, s.description,
         s.trigger_type, s.trigger_value, s.trigger_tol, s.planned_day, s.recipe_ingredient_ids, s.starts_lagering
  from batches b
  join recipe_cellar_steps s on s.recipe_id = b.recipe_id
  where b.id = p_batch_id
  order by s.sort_order, s.id;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;


--
-- Name: snapshot_batch_ingredients(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.snapshot_batch_ingredients(p_batch_id bigint) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_count integer;
begin
  if auth.uid() is not null and not can_view('batches') then
    raise exception 'no access to batches' using errcode = '42501';
  end if;

  -- two users opening the same batch at once must not both copy
  perform pg_advisory_xact_lock(hashtext('snapshot_batch_ingredients'), p_batch_id::integer);

  if exists (select 1 from batch_ingredients where batch_id = p_batch_id) then
    return 0;
  end if;

  insert into batch_ingredients (
    batch_id, recipe_ingredient_id, ingredient_id, addition_type, timing, unit, sort_order,
    recipe_quantity, quantity, recipe_alpha_pct, alpha_pct, recipe_color_ebc, color_ebc,
    hop_dosing_tank, all_in_first_brew, note, source_recipe_group_id)
  select b.id, ri.id, ri.ingredient_id, ri.addition_type, ri.timing, ri.unit, ri.sort_order,
         ri.quantity, ri.quantity, ri.alpha_pct, ri.alpha_pct, ri.color_ebc, ri.color_ebc,
         ri.hop_dosing_tank, ri.all_in_first_brew, ri.note, ri.source_recipe_group_id
  from batches b
  join recipe_ingredients ri on ri.recipe_id = b.recipe_id
  where b.id = p_batch_id
  order by ri.addition_type, ri.sort_order, ri.id;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;


--
-- Name: snapshot_new_batch(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.snapshot_new_batch() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
  perform snapshot_batch_ingredients(new.id);
  perform snapshot_batch_cellar_steps(new.id);
  return null;
end;
$$;


--
-- Name: split_batch(bigint, timestamp with time zone, numeric, bigint, text, bigint, bigint, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.split_batch(p_batch_id bigint, p_transferred_at timestamp with time zone, p_volume_hl numeric, p_from_tank_id bigint, p_destination text, p_recipe_id bigint DEFAULT NULL::bigint, p_to_batch_id bigint DEFAULT NULL::bigint, p_reason text DEFAULT NULL::text, p_comment text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $_$
declare
  v_to_batch   bigint := p_to_batch_id;
  v_number     text;
  v_recipe_id   bigint;
  v_recipe_name text;
  v_yy         text := to_char(now() at time zone 'Europe/Amsterdam', 'YY');
  v_transfer   bigint;
  v_entry      bigint;
  v_tank       text;
  v_text       text;
  v_dot        text := ' ' || chr(183) || ' ';   -- space, middle dot, space
begin
  if auth.uid() is not null and not can_edit('batches') then
    raise exception 'no edit rights on batches' using errcode = '42501';
  end if;
  if p_destination not in ('new', 'batch', 'discard') then
    raise exception 'destination must be new, batch or discard' using errcode = '22023';
  end if;
  if p_volume_hl is null or p_volume_hl <= 0 then
    raise exception 'the volume must be more than 0 hl' using errcode = '22023';
  end if;
  if p_transferred_at is null then
    raise exception 'the transfer moment is missing' using errcode = '22023';
  end if;

  if p_destination = 'new' then
    select id, name into v_recipe_id, v_recipe_name from recipes where id = p_recipe_id;
    if not found then
      raise exception 'choose an existing recipe for the new batch' using errcode = '22023';
    end if;
    -- next number of this year (YY + 3 digits); two saves at once wait for each other
    perform pg_advisory_xact_lock(hashtext('next_batch_number'));
    select (coalesce(max(batch_number::integer), v_yy::integer * 1000) + 1)::text
    into v_number
    from batches
    where batch_number ~ ('^' || v_yy || '[0-9]{3}$');
    insert into batches (batch_number, recipe_id, brew_count, name, status, created_by)
    values (v_number, v_recipe_id, 0, v_recipe_name, 'planned', auth.uid())
    returning id into v_to_batch;
  elsif p_destination = 'batch' then
    select batch_number into v_number from batches where id = p_to_batch_id;
    if not found then
      raise exception 'the receiving batch does not exist' using errcode = '22023';
    end if;
  end if;

  insert into batch_transfers (batch_id, from_tank_id, destination, to_batch_id, volume_hl, transferred_at, reason, comment, updated_by)
  values (p_batch_id, p_from_tank_id, case when p_destination = 'discard' then 'discard' else 'batch' end,
          case when p_destination = 'discard' then null else v_to_batch end,
          p_volume_hl, p_transferred_at, nullif(btrim(p_reason), ''), nullif(btrim(p_comment), ''), auth.uid())
  returning id into v_transfer;

  select code into v_tank from tanks where id = p_from_tank_id;
  v_text := 'Transfer' || v_dot || trim(to_char(p_volume_hl, 'FM999990.0')) || ' hl'
            || coalesce(' from ' || v_tank, '')
            || case p_destination
                 when 'new' then ' to new batch ' || v_number || ' (' || v_recipe_name || ')'
                 when 'batch' then ' to batch ' || v_number
                 else ' discarded' || coalesce(v_dot || nullif(btrim(p_reason), ''), '')
               end
            || coalesce(v_dot || nullif(btrim(p_comment), ''), '');
  insert into fermentation_log_entries (batch_id, measured_at, comment, updated_by)
  values (p_batch_id, p_transferred_at, v_text, auth.uid())
  returning id into v_entry;
  insert into fermentation_log_entry_tags (entry_id, tag_id, batch_id)
  select v_entry, t.id, p_batch_id from cellar_action_tags t where t.code = 'transfer';

  return jsonb_build_object('transfer_id', v_transfer, 'to_batch_id', case when p_destination = 'discard' then null else v_to_batch end,
                            'batch_number', v_number, 'log_entry_id', v_entry);
end;
$_$;


--
-- Name: tolerance_value(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.tolerance_value(p_text text) RETURNS numeric
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public'
    AS $$
  select abs(nullif(replace(substring(coalesce(p_text, '') from '-?[0-9]+(?:[.,][0-9]+)?'), ',', '.'), '')::numeric)
$$;


--
-- Name: water_settings_log(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.water_settings_log() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
                                                                           begin
                                                                             insert into water_settings_history (valid_from, updated_by, data)
                                                                                 values (new.updated_at, new.updated_by, to_jsonb(new));
                                                                                   return new;
                                                                                   end;
                                                                                   $$;


--
-- Name: water_settings_stamp(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.water_settings_stamp() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
                                                                     begin
                                                                       new.updated_at := now();
                                                                         new.updated_by := auth.uid();
                                                                           return new;
                                                                           end;
                                                                           $$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: batch_audit_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.batch_audit_log (
    id bigint NOT NULL,
    batch_id bigint,
    table_name text NOT NULL,
    row_id text NOT NULL,
    action text NOT NULL,
    old_data jsonb,
    new_data jsonb,
    changed_by uuid DEFAULT auth.uid(),
    changed_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT batch_audit_log_action_check CHECK ((action = ANY (ARRAY['insert'::text, 'update'::text, 'delete'::text])))
);


--
-- Name: batch_audit_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.batch_audit_log ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.batch_audit_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: batch_brew_comments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.batch_brew_comments (
    id bigint NOT NULL,
    batch_id bigint NOT NULL,
    brew_number integer,
    comment_time time without time zone,
    comment text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    CONSTRAINT batch_brew_comments_brew_number_check CHECK ((brew_number > 0))
);


--
-- Name: batch_brew_comments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.batch_brew_comments ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.batch_brew_comments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: batch_brews; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.batch_brews (
    id bigint NOT NULL,
    batch_id bigint NOT NULL,
    brew_number integer NOT NULL,
    software_order_number text,
    brewer_id uuid,
    mash_in_started_at timestamp with time zone,
    mash_water_hl numeric,
    mash_in_ph numeric,
    mash_acid_l numeric,
    mash_corrected_ph numeric,
    is_iodine_test_ok boolean,
    has_mash_schedule_deviation boolean,
    first_wort_extract numeric,
    last_runnings_extract numeric,
    cumulative_sparge_volume_hl numeric,
    last_runnings_ph numeric,
    first_wort_volume_hl numeric,
    sparge_water_hl numeric,
    sparge_runnings_hl numeric,
    lauter_time_min numeric,
    boil_start_ph numeric,
    boil_start_extract numeric,
    boil_start_volume_hl numeric,
    boil_acid_l numeric,
    boil_acid_ph_note text,
    boil_time_min numeric,
    boil_end_extract numeric,
    extra_addition text,
    whirlpool_volume_hl numeric,
    whirlpool_extract numeric,
    whirlpool_ph numeric,
    whirlpool_rest_min numeric,
    aeration_ppm numeric,
    water_addition_hl numeric,
    brew_volume_hl numeric,
    brewing_ended_at timestamp with time zone,
    process_pause text,
    is_aeration_filter_steamed boolean,
    is_wort_line_sterilized boolean,
    ckt_cip_program text,
    spent_grain_bin text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    brewer_end_id uuid,
    mash_rinse_water_hl numeric,
    CONSTRAINT batch_brews_brew_number_check CHECK ((brew_number > 0)),
    CONSTRAINT batch_brews_ckt_cip_program_check CHECK ((ckt_cip_program = ANY (ARRAY['lo-de'::text, 'lo-zu-de'::text, 'lo-de-hw'::text, 'lo-zu-de-hw'::text])))
);


--
-- Name: COLUMN batch_brews.brewer_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.batch_brews.brewer_id IS 'Brewer start';


--
-- Name: COLUMN batch_brews.brewer_end_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.batch_brews.brewer_end_id IS 'Brewer end';


--
-- Name: COLUMN batch_brews.mash_rinse_water_hl; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.batch_brews.mash_rinse_water_hl IS 'Rinse water (Spoelwater, mashing), hl';


--
-- Name: batch_brews_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.batch_brews ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.batch_brews_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: batch_cellar_steps; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.batch_cellar_steps (
    id bigint NOT NULL,
    batch_id bigint NOT NULL,
    recipe_cellar_step_id bigint,
    sort_order integer NOT NULL,
    tag_id bigint NOT NULL,
    title text NOT NULL,
    description text,
    trigger_type text NOT NULL,
    trigger_value numeric,
    trigger_tol numeric,
    planned_day numeric,
    recipe_ingredient_ids bigint[] DEFAULT '{}'::bigint[] NOT NULL,
    starts_lagering boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    CONSTRAINT batch_cellar_steps_trigger_type_check CHECK ((trigger_type = ANY (ARRAY['extract'::text, 'day'::text, 'after_previous'::text, 'temperature'::text])))
);


--
-- Name: batch_cellar_steps_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.batch_cellar_steps ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.batch_cellar_steps_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: batch_documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.batch_documents (
    id bigint NOT NULL,
    batch_id bigint NOT NULL,
    document_type text NOT NULL,
    file_name text NOT NULL,
    storage_path text NOT NULL,
    size_bytes bigint,
    uploaded_by uuid DEFAULT auth.uid(),
    uploaded_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    CONSTRAINT batch_documents_document_type_check CHECK ((document_type = ANY (ARRAY['production_order'::text, 'filling_order'::text, 'filling_report'::text, 'other'::text])))
);


--
-- Name: batch_documents_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.batch_documents ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.batch_documents_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: batch_hbts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.batch_hbts (
    id bigint NOT NULL,
    batch_id bigint NOT NULL,
    tank_id bigint NOT NULL,
    intended_formats text[] DEFAULT '{}'::text[] NOT NULL,
    avg_inline_o2_ppb numeric,
    avg_pu numeric,
    avg_turbidity_ebc numeric,
    avg_flow_hl_h numeric,
    released_at timestamp with time zone,
    released_by uuid,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    CONSTRAINT batch_hbts_intended_formats_check CHECK ((intended_formats <@ ARRAY['bottle'::text, 'can'::text, 'keg'::text, 'tank'::text])),
    CONSTRAINT batch_hbts_released_check CHECK (((released_at IS NULL) = (released_by IS NULL)))
);


--
-- Name: batch_hbts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.batch_hbts ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.batch_hbts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: batch_ingredients; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.batch_ingredients (
    id bigint NOT NULL,
    batch_id bigint NOT NULL,
    recipe_ingredient_id bigint,
    ingredient_id bigint,
    is_added boolean DEFAULT false NOT NULL,
    addition_type text NOT NULL,
    timing text,
    unit text,
    sort_order integer,
    recipe_quantity numeric,
    quantity numeric,
    recipe_alpha_pct numeric,
    alpha_pct numeric,
    recipe_color_ebc numeric,
    color_ebc numeric,
    hop_dosing_tank integer,
    all_in_first_brew boolean DEFAULT false NOT NULL,
    note text,
    is_removed boolean DEFAULT false NOT NULL,
    deviation_reason text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    source_recipe_group_id uuid,
    CONSTRAINT batch_ingredients_added_has_ingredient CHECK (((NOT is_added) OR (ingredient_id IS NOT NULL))),
    CONSTRAINT batch_ingredients_addition_type_check CHECK ((addition_type = ANY (ARRAY['malt'::text, 'boil_hop'::text, 'dry_hop'::text, 'brewhouse_addition'::text, 'cellar_addition'::text, 'yeast'::text, 'base_beer'::text]))),
    CONSTRAINT batch_ingredients_base_beer_check CHECK (((addition_type = 'base_beer'::text) = (source_recipe_group_id IS NOT NULL)))
);


--
-- Name: batch_ingredients_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.batch_ingredients ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.batch_ingredients_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: batch_transfers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.batch_transfers (
    id bigint NOT NULL,
    batch_id bigint NOT NULL,
    from_tank_id bigint,
    destination text NOT NULL,
    to_batch_id bigint,
    volume_hl numeric NOT NULL,
    transferred_at timestamp with time zone NOT NULL,
    reason text,
    comment text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    CONSTRAINT batch_transfers_destination_check CHECK ((destination = ANY (ARRAY['batch'::text, 'discard'::text]))),
    CONSTRAINT batch_transfers_discard_reason CHECK (((destination <> 'discard'::text) OR (NULLIF(btrim(reason), ''::text) IS NOT NULL))),
    CONSTRAINT batch_transfers_not_self CHECK ((to_batch_id IS DISTINCT FROM batch_id)),
    CONSTRAINT batch_transfers_to_batch_check CHECK (((destination = 'batch'::text) = (to_batch_id IS NOT NULL))),
    CONSTRAINT batch_transfers_volume_hl_check CHECK ((volume_hl > (0)::numeric))
);


--
-- Name: batches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.batches (
    id bigint NOT NULL,
    batch_number text NOT NULL,
    recipe_id bigint NOT NULL,
    brew_count numeric,
    brew_date date,
    status text DEFAULT 'planned'::text NOT NULL,
    operator text,
    yeast_temp_start numeric,
    yeast_temp_max numeric,
    yeast_strain text,
    yeast_rehydrated boolean,
    yeast_weight numeric,
    yeast_with_first_brew boolean,
    yeast_pitched_on date,
    yeast_pitched_by uuid,
    yeast_program_on boolean,
    order_picking_date date,
    "extract" numeric,
    alcohol numeric,
    bitterness numeric,
    color numeric,
    ph numeric,
    glt_empty boolean,
    total_final_volume numeric,
    name text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid,
    order_picking_completed_at timestamp with time zone,
    order_picking_completed_by uuid,
    brewhouse_recipe_number text,
    glt_tank_id bigint,
    time_zero timestamp with time zone,
    lt_tank_id bigint,
    cellar_additions_done boolean DEFAULT false NOT NULL,
    tasting_comment text,
    tasting_result text,
    CONSTRAINT batches_status_check CHECK ((status = ANY (ARRAY['planned'::text, 'brewing'::text, 'fermenting'::text, 'processing'::text, 'filling'::text, 'completed'::text]))),
    CONSTRAINT batches_tasting_result_check CHECK ((tasting_result = ANY (ARRAY['go'::text, 'no_go'::text])))
);


--
-- Name: fermentation_log_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.fermentation_log_entries (
    id bigint NOT NULL,
    batch_id bigint NOT NULL,
    measured_at timestamp with time zone NOT NULL,
    "extract" numeric,
    temp_high numeric,
    temp_low numeric,
    ph numeric,
    comment text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid
);


--
-- Name: fermentation_log_entry_tags; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.fermentation_log_entry_tags (
    entry_id bigint NOT NULL,
    tag_id bigint NOT NULL,
    batch_id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    id bigint NOT NULL,
    batch_cellar_step_id bigint
);


--
-- Name: filling_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.filling_sessions (
    id bigint NOT NULL,
    batch_id bigint NOT NULL,
    session_number integer NOT NULL,
    filling_date date,
    batch_hbt_id bigint,
    package_format text,
    volume_hl numeric,
    start_time time without time zone,
    end_time time without time zone,
    sampled_by uuid,
    is_first_package_checked boolean,
    is_fill_tube_checked_first boolean,
    is_fill_tube_checked_end boolean,
    are_burst_bottles_controlled boolean,
    is_hbt_finished boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    CONSTRAINT filling_sessions_package_format_check CHECK ((package_format = ANY (ARRAY['bottle'::text, 'can'::text, 'keg'::text, 'tank'::text]))),
    CONSTRAINT filling_sessions_session_number_check CHECK ((session_number > 0)),
    CONSTRAINT filling_sessions_volume_hl_check CHECK ((volume_hl >= (0)::numeric))
);


--
-- Name: processing_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.processing_sessions (
    id bigint NOT NULL,
    batch_id bigint NOT NULL,
    session_number integer NOT NULL,
    started_by uuid,
    ended_by uuid,
    processing_date date,
    start_time time without time zone,
    end_time time without time zone,
    tank_id bigint,
    outlet text,
    discharge_count integer,
    discharge_interval_min numeric,
    centrifuge_in_time time without time zone,
    centrifuge_in_o2_ppb numeric,
    centrifuge_in_co2_gl numeric,
    centrifuge_out_time time without time zone,
    centrifuge_out_o2_ppb numeric,
    centrifuge_out_co2_gl numeric,
    start_flow_hl_h numeric,
    start_turbidity_ebc numeric,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    CONSTRAINT processing_sessions_discharge_count_check CHECK ((discharge_count >= 0)),
    CONSTRAINT processing_sessions_outlet_check CHECK ((outlet = ANY (ARRAY['standpipe'::text, 'bottom_valve'::text]))),
    CONSTRAINT processing_sessions_session_number_check CHECK ((session_number > 0))
);


--
-- Name: tanks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tanks (
    id bigint NOT NULL,
    code text NOT NULL,
    tank_type text NOT NULL,
    number integer NOT NULL,
    location text NOT NULL,
    volume_hl numeric NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    CONSTRAINT tanks_location_check CHECK ((location = ANY (ARRAY['wp'::text, 'jk'::text]))),
    CONSTRAINT tanks_tank_type_check CHECK ((tank_type = ANY (ARRAY['ckt'::text, 'glt'::text, 'lt'::text, 'hbt'::text]))),
    CONSTRAINT tanks_volume_hl_check CHECK ((volume_hl > (0)::numeric))
);


--
-- Name: batch_stages; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.batch_stages WITH (security_invoker='true') AS
 WITH step_link AS (
         SELECT et.batch_cellar_step_id AS step_id,
            min(e.measured_at) AS done_at
           FROM (public.fermentation_log_entry_tags et
             JOIN public.fermentation_log_entries e ON ((e.id = et.entry_id)))
          WHERE (et.batch_cellar_step_id IS NOT NULL)
          GROUP BY et.batch_cellar_step_id
        ), open_step AS (
         SELECT bcs.id,
            bcs.batch_id,
            bcs.tag_id,
            row_number() OVER (PARTITION BY bcs.batch_id, bcs.tag_id ORDER BY bcs.sort_order, bcs.id) AS occurrence
           FROM public.batch_cellar_steps bcs
          WHERE (NOT (EXISTS ( SELECT 1
                   FROM step_link l
                  WHERE (l.step_id = bcs.id))))
        ), free_tag AS (
         SELECT et.batch_id,
            et.tag_id,
            e.measured_at,
            row_number() OVER (PARTITION BY et.batch_id, et.tag_id ORDER BY e.measured_at, e.id, et.id) AS occurrence
           FROM (public.fermentation_log_entry_tags et
             JOIN public.fermentation_log_entries e ON ((e.id = et.entry_id)))
          WHERE (et.batch_cellar_step_id IS NULL)
        ), step_state AS (
         SELECT s.batch_id,
            s.id,
            s.sort_order,
            s.title,
            s.starts_lagering,
            COALESCE(l.done_at, f.measured_at) AS done_at
           FROM (((public.batch_cellar_steps s
             LEFT JOIN step_link l ON ((l.step_id = s.id)))
             LEFT JOIN open_step o ON ((o.id = s.id)))
             LEFT JOIN free_tag f ON (((f.batch_id = o.batch_id) AND (f.tag_id = o.tag_id) AND (f.occurrence = o.occurrence))))
        ), plan AS (
         SELECT step_state.batch_id,
            count(*) AS steps_total,
            count(step_state.done_at) AS steps_done,
            (array_agg(step_state.title ORDER BY step_state.sort_order, step_state.id) FILTER (WHERE (step_state.done_at IS NULL)))[1] AS next_step,
            min(step_state.done_at) FILTER (WHERE step_state.starts_lagering) AS lagering_started_at
           FROM step_state
          GROUP BY step_state.batch_id
        ), incoming AS (
         SELECT t.to_batch_id AS batch_id,
            sum(t.volume_hl) AS volume_hl,
            min(t.transferred_at) AS first_at
           FROM public.batch_transfers t
          WHERE (t.to_batch_id IS NOT NULL)
          GROUP BY t.to_batch_id
        ), base AS (
         SELECT b_1.id,
            b_1.status,
            b_1.time_zero,
            b_1.brew_count,
            (ceil(COALESCE(b_1.brew_count, (0)::numeric)))::integer AS brews_planned,
            br.brews_started,
            br.brews_ended,
            br.first_mash_in_at,
            br.last_brew_ended_at,
            inc.volume_hl AS incoming_volume_hl,
            inc.first_at AS first_incoming_at,
            (((ceil(COALESCE(b_1.brew_count, (0)::numeric)) > (0)::numeric) AND ((COALESCE(br.brews_ended, (0)::bigint))::numeric >= ceil(b_1.brew_count))) OR ((COALESCE(br.brews_started, (0)::bigint) = 0) AND (inc.first_at IS NOT NULL))) AS is_brewed
           FROM ((public.batches b_1
             LEFT JOIN LATERAL ( SELECT count(*) FILTER (WHERE (bb.mash_in_started_at IS NOT NULL)) AS brews_started,
                    count(*) FILTER (WHERE (bb.brewing_ended_at IS NOT NULL)) AS brews_ended,
                    min(bb.mash_in_started_at) AS first_mash_in_at,
                    max(bb.brewing_ended_at) AS last_brew_ended_at
                   FROM public.batch_brews bb
                  WHERE (bb.batch_id = b_1.id)) br ON (true))
             LEFT JOIN incoming inc ON ((inc.batch_id = b_1.id)))
        )
 SELECT b.id AS batch_id,
        CASE
            WHEN (b.status = 'completed'::text) THEN 'closed'::text
            WHEN ((COALESCE(h.hbts_total, (0)::bigint) > 0) AND (fs.hbts_finished >= h.hbts_total)) THEN 'filled'::text
            WHEN (fs.first_filling_date IS NOT NULL) THEN 'filling'::text
            WHEN (ps.first_processing_date IS NOT NULL) THEN 'hbt'::text
            WHEN (b.is_brewed AND (p.lagering_started_at IS NOT NULL)) THEN 'lagering'::text
            WHEN b.is_brewed THEN 'fermentation'::text
            WHEN (COALESCE(b.brews_started, (0)::bigint) > 0) THEN 'brewing'::text
            ELSE 'raw'::text
        END AS stage,
    COALESCE(((b.first_mash_in_at AT TIME ZONE 'Europe/Amsterdam'::text))::date,
        CASE
            WHEN (COALESCE(b.brews_started, (0)::bigint) = 0) THEN ((b.first_incoming_at AT TIME ZONE 'Europe/Amsterdam'::text))::date
            ELSE NULL::date
        END) AS start_date,
    NULL::date AS end_date,
    b.brews_planned,
    (COALESCE(b.brews_started, (0)::bigint))::integer AS brews_started,
    (COALESCE(b.brews_ended, (0)::bigint))::integer AS brews_ended,
    b.last_brew_ended_at,
    COALESCE(b.time_zero, b.last_brew_ended_at,
        CASE
            WHEN (COALESCE(b.brews_started, (0)::bigint) = 0) THEN b.first_incoming_at
            ELSE NULL::timestamp with time zone
        END) AS time_zero,
    (COALESCE(p.steps_total, (0)::bigint))::integer AS cellar_steps_total,
    (COALESCE(p.steps_done, (0)::bigint))::integer AS cellar_steps_done,
    p.next_step AS next_cellar_step,
    p.lagering_started_at,
    ps.first_processing_date,
    (COALESCE(h.hbts_total, (0)::bigint))::integer AS hbts_total,
    (COALESCE(h.hbts_released, (0)::bigint))::integer AS hbts_released,
    h.hbt_codes,
    COALESCE(h.hbt_formats, '{}'::text[]) AS hbt_formats,
    fs.first_filling_date,
    (COALESCE(fs.hbts_finished, (0)::bigint))::integer AS hbts_finished,
    fs.filled_volume_hl,
    COALESCE(b.incoming_volume_hl, (0)::numeric) AS incoming_volume_hl,
    b.first_incoming_at,
    (COALESCE(d.documents_uploaded, (0)::bigint))::integer AS documents_uploaded,
    (COALESCE(d.other_documents, (0)::bigint))::integer AS other_documents
   FROM (((((base b
     LEFT JOIN plan p ON ((p.batch_id = b.id)))
     LEFT JOIN LATERAL ( SELECT count(DISTINCT bd.document_type) FILTER (WHERE (bd.document_type <> 'other'::text)) AS documents_uploaded,
            count(*) FILTER (WHERE (bd.document_type = 'other'::text)) AS other_documents
           FROM public.batch_documents bd
          WHERE (bd.batch_id = b.id)) d ON (true))
     LEFT JOIN LATERAL ( SELECT min(s.processing_date) AS first_processing_date
           FROM public.processing_sessions s
          WHERE (s.batch_id = b.id)) ps ON (true))
     LEFT JOIN LATERAL ( SELECT count(*) AS hbts_total,
            count(bh.released_at) AS hbts_released,
            string_agg(t.code, ((' '::text || chr(183)) || ' '::text) ORDER BY bh.sort_order, t.number) AS hbt_codes,
            ARRAY( SELECT DISTINCT f.f
                   FROM public.batch_hbts x,
                    LATERAL unnest(x.intended_formats) f(f)
                  WHERE (x.batch_id = b.id)
                  ORDER BY f.f) AS hbt_formats
           FROM (public.batch_hbts bh
             JOIN public.tanks t ON ((t.id = bh.tank_id)))
          WHERE (bh.batch_id = b.id)) h ON (true))
     LEFT JOIN LATERAL ( SELECT min(f.filling_date) AS first_filling_date,
            count(DISTINCT f.batch_hbt_id) FILTER (WHERE f.is_hbt_finished) AS hbts_finished,
            sum(f.volume_hl) AS filled_volume_hl
           FROM public.filling_sessions f
          WHERE (f.batch_id = b.id)) fs ON (true));


--
-- Name: batch_transfers_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.batch_transfers ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.batch_transfers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: batches_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.batches ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.batches_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: brew_capacity; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.brew_capacity (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    capacity_group text NOT NULL,
    iso_year integer NOT NULL,
    week_number integer NOT NULL,
    max_brews numeric DEFAULT 0 NOT NULL,
    updated_by uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT brew_capacity_capacity_group_check CHECK ((capacity_group = ANY (ARRAY['jk'::text, 'wp'::text]))),
    CONSTRAINT brew_capacity_week_number_check CHECK (((week_number >= 1) AND (week_number <= 53)))
);


--
-- Name: brew_planning; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.brew_planning (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    plan_group public.brew_plan_group NOT NULL,
    iso_year integer NOT NULL,
    week_number integer NOT NULL,
    recipe_id bigint,
    brew_count numeric DEFAULT 1 NOT NULL,
    hl numeric,
    is_priority boolean DEFAULT false NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    notes text,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    recipe_group_id uuid,
    CONSTRAINT brew_planning_week_number_check CHECK (((week_number >= 1) AND (week_number <= 53)))
);


--
-- Name: brew_planning_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.brew_planning_history (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    brew_planning_id uuid NOT NULL,
    action text NOT NULL,
    before jsonb,
    after jsonb,
    updated_by uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT brew_planning_history_action_check CHECK ((action = ANY (ARRAY['created'::text, 'updated'::text, 'deleted'::text])))
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id uuid NOT NULL,
    name text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    last_login_at timestamp with time zone,
    role_id integer,
    initials text
);


--
-- Name: brew_planning_history_detailed; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.brew_planning_history_detailed WITH (security_invoker='true') AS
 SELECT h.id,
    h.brew_planning_id,
    h.action,
    h.before,
    h.after,
    h.updated_by,
    u.name AS updated_by_name,
    h.updated_at
   FROM (public.brew_planning_history h
     LEFT JOIN public.users u ON ((u.id = h.updated_by)))
  ORDER BY h.updated_at DESC;


--
-- Name: brew_planning_splits; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.brew_planning_splits (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    brew_planning_id uuid NOT NULL,
    recipe_id bigint NOT NULL,
    recipe_group_id uuid,
    hl numeric NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: cellar_action_tags; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cellar_action_tags (
    id bigint NOT NULL,
    code text NOT NULL,
    label text NOT NULL,
    is_milestone boolean DEFAULT false NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    CONSTRAINT cellar_action_tags_code_check CHECK ((code ~ '^[a-z0-9_]+$'::text))
);


--
-- Name: cellar_action_tags_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.cellar_action_tags ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.cellar_action_tags_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: cellar_plan_parts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cellar_plan_parts (
    id bigint NOT NULL,
    code text NOT NULL,
    kind text NOT NULL,
    label text NOT NULL,
    shows_on text DEFAULT 'cellar_plan'::text NOT NULL,
    on_addition_day boolean DEFAULT false NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    tag_id bigint NOT NULL,
    CONSTRAINT cellar_plan_parts_code_check CHECK ((code ~ '^[a-z0-9_]+$'::text)),
    CONSTRAINT cellar_plan_parts_fixed_check CHECK (((kind = 'addition_timing'::text) OR ((code = kind) AND (shows_on = 'cellar_plan'::text) AND is_active))),
    CONSTRAINT cellar_plan_parts_kind_check CHECK ((kind = ANY (ARRAY['dry_warm'::text, 'cold_dry_hop'::text, 'cooling_lagering'::text, 'sample_lab'::text, 'dry_hop_at_lagering'::text, 'addition_timing'::text]))),
    CONSTRAINT cellar_plan_parts_shows_on_check CHECK ((shows_on = ANY (ARRAY['cellar_plan'::text, 'processing'::text])))
);


--
-- Name: cellar_plan_parts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.cellar_plan_parts ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.cellar_plan_parts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: document_types; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.document_types (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    code text NOT NULL,
    label text,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: fermentation_log_entries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.fermentation_log_entries ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.fermentation_log_entries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: fermentation_log_entry_tags_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.fermentation_log_entry_tags ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.fermentation_log_entry_tags_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: filling_measurements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.filling_measurements (
    id bigint NOT NULL,
    batch_id bigint NOT NULL,
    filling_session_id bigint NOT NULL,
    measured_time time without time zone,
    tpo_ppb numeric,
    hso_ppb numeric,
    do_ppb numeric,
    headspace_volume numeric,
    pressure_bar numeric,
    temp_c numeric,
    co2_gl numeric,
    keg_co2_gl numeric,
    keg_o2_ppb numeric,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid
);


--
-- Name: filling_measurements_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.filling_measurements ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.filling_measurements_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: filling_session_articles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.filling_session_articles (
    id bigint NOT NULL,
    batch_id bigint NOT NULL,
    filling_session_id bigint NOT NULL,
    article_id bigint NOT NULL,
    quantity numeric,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    comment text,
    CONSTRAINT filling_session_articles_quantity_check CHECK ((quantity >= (0)::numeric))
);


--
-- Name: filling_session_articles_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.filling_session_articles ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.filling_session_articles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: filling_session_materials; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.filling_session_materials (
    id bigint NOT NULL,
    batch_id bigint NOT NULL,
    filling_session_id bigint NOT NULL,
    material_id bigint NOT NULL,
    quantity numeric,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    comment text,
    CONSTRAINT filling_session_materials_quantity_check CHECK ((quantity >= (0)::numeric))
);


--
-- Name: filling_session_materials_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.filling_session_materials ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.filling_session_materials_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: filling_sessions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.filling_sessions ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.filling_sessions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: hbt_readings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.hbt_readings (
    id bigint NOT NULL,
    batch_id bigint NOT NULL,
    batch_hbt_id bigint NOT NULL,
    processing_session_id bigint,
    sort_order integer NOT NULL,
    level_hl numeric,
    o2_ppb numeric,
    co2_gl numeric,
    co2_target text,
    comment text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    CONSTRAINT hbt_readings_co2_target_check CHECK ((co2_target = ANY (ARRAY['bottle'::text, 'can'::text, 'keg'::text, 'tank'::text])))
);


--
-- Name: hbt_readings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.hbt_readings ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.hbt_readings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: ingredient_categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ingredient_categories (
    id bigint NOT NULL,
    name text NOT NULL,
    uses_alpha_pct boolean DEFAULT false NOT NULL,
    uses_extract_pct boolean DEFAULT false NOT NULL,
    uses_yeast_factor boolean DEFAULT false NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: ingredient_categories_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.ingredient_categories ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.ingredient_categories_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: ingredient_declarations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ingredient_declarations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    not_declarable boolean DEFAULT false NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: ingredient_documents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ingredient_documents (
    id bigint NOT NULL,
    ingredient_id bigint NOT NULL,
    file_name text NOT NULL,
    storage_path text NOT NULL,
    size_bytes bigint,
    revision_date date NOT NULL,
    uploaded_by uuid,
    uploaded_at timestamp with time zone DEFAULT now() NOT NULL,
    document_type_id uuid NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    CONSTRAINT ingredient_documents_status_check CHECK ((status = ANY (ARRAY['active'::text, 'archived'::text])))
);


--
-- Name: ingredient_documents_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.ingredient_documents ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.ingredient_documents_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: ingredient_revisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ingredient_revisions (
    id bigint NOT NULL,
    ingredient_id bigint NOT NULL,
    version_major integer NOT NULL,
    version_minor integer NOT NULL,
    date date DEFAULT CURRENT_DATE NOT NULL,
    changed_by_name text,
    change_description text,
    user_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: ingredient_revisions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.ingredient_revisions ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.ingredient_revisions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: recipe_ingredients; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recipe_ingredients (
    id bigint NOT NULL,
    recipe_id bigint NOT NULL,
    ingredient_id bigint,
    addition_type text NOT NULL,
    quantity numeric,
    unit text,
    timing text,
    sort_order integer,
    note text,
    hop_dosing_tank integer,
    alpha_pct numeric,
    color_ebc numeric,
    all_in_first_brew boolean DEFAULT false NOT NULL,
    source_recipe_group_id uuid,
    CONSTRAINT recipe_ingredients_addition_type_check CHECK ((addition_type = ANY (ARRAY['malt'::text, 'boil_hop'::text, 'dry_hop'::text, 'brewhouse_addition'::text, 'cellar_addition'::text, 'yeast'::text, 'base_beer'::text]))),
    CONSTRAINT recipe_ingredients_base_beer_check CHECK ((((addition_type = 'base_beer'::text) = (source_recipe_group_id IS NOT NULL)) AND ((addition_type <> 'base_beer'::text) OR ((ingredient_id IS NULL) AND (quantity > (0)::numeric) AND (quantity <= (100)::numeric)))))
);


--
-- Name: ingredient_usage_counts; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.ingredient_usage_counts WITH (security_invoker='true') AS
 SELECT ingredient_id,
    count(DISTINCT recipe_id) AS recipe_count
   FROM public.recipe_ingredients
  WHERE (ingredient_id IS NOT NULL)
  GROUP BY ingredient_id;


--
-- Name: ingredients; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ingredients (
    id bigint NOT NULL,
    name text NOT NULL,
    unit text,
    price numeric,
    extract_pct numeric,
    alpha_pct numeric,
    yeast_factor numeric,
    supplier text,
    status text DEFAULT 'active'::text NOT NULL,
    created_by uuid,
    updated_by uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    category_id bigint,
    version_major integer DEFAULT 1 NOT NULL,
    version_minor integer DEFAULT 0 NOT NULL,
    ingredient_group_id uuid DEFAULT gen_random_uuid() NOT NULL,
    version_status text DEFAULT 'current'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    supplier_2 text,
    price_2 numeric,
    price_unit_1 text,
    price_unit_2 text,
    color_ebc numeric,
    allergens jsonb,
    ingredient_declaration text,
    storage_temperature text,
    shelf_life numeric,
    shelf_life_after_opening numeric,
    density numeric,
    alcohol_pct numeric,
    shelf_life_unit text,
    shelf_life_after_opening_unit text,
    supplier_3 text,
    price_3 numeric,
    price_unit_3 text,
    price_per_kg numeric,
    price_per_kg_2 numeric,
    price_per_kg_3 numeric,
    minimum_stock numeric,
    CONSTRAINT ingredients_shelf_life_after_opening_unit_check CHECK (((shelf_life_after_opening_unit IS NULL) OR (shelf_life_after_opening_unit = ANY (ARRAY['hours'::text, 'days'::text, 'weeks'::text, 'months'::text, 'years'::text])))),
    CONSTRAINT ingredients_shelf_life_unit_check CHECK (((shelf_life_unit IS NULL) OR (shelf_life_unit = ANY (ARRAY['hours'::text, 'days'::text, 'weeks'::text, 'months'::text, 'years'::text])))),
    CONSTRAINT ingredients_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'active'::text, 'phasing_out'::text]))),
    CONSTRAINT ingredients_version_status_check CHECK ((version_status = ANY (ARRAY['current'::text, 'archived'::text])))
);


--
-- Name: COLUMN ingredients.price_per_kg; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.ingredients.price_per_kg IS 'Prijs per kg voor Supplier #1, los van prijs/eenheid_prijs_1 (die de doseereenheid volgt).';


--
-- Name: COLUMN ingredients.price_per_kg_2; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.ingredients.price_per_kg_2 IS 'Prijs per kg voor Supplier #2.';


--
-- Name: COLUMN ingredients.price_per_kg_3; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.ingredients.price_per_kg_3 IS 'Prijs per kg voor Supplier #3.';


--
-- Name: COLUMN ingredients.minimum_stock; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.ingredients.minimum_stock IS 'Ondergrens voor de Stock overview-pagina ("bijna leeg"-signaal). Eenheid wordt afgeleid uit ingredients.eenheid (het deel vóór een eventuele ''/'', dus g/hl -> g) -- geen apart eenheid-veld nodig.';


--
-- Name: ingredients_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.ingredients ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.ingredients_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: lots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lots (
    id bigint NOT NULL,
    ingredient_id bigint NOT NULL,
    supplier text,
    lot_code text,
    received_date date DEFAULT CURRENT_DATE NOT NULL,
    quantity_received numeric NOT NULL,
    unit text,
    package_count text,
    location text,
    receiving_check boolean DEFAULT false NOT NULL,
    incoming_inspection boolean DEFAULT false NOT NULL,
    best_before_date date,
    alpha_pct numeric,
    status text DEFAULT 'active'::text NOT NULL,
    document_path text,
    note text,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    received_by uuid,
    CONSTRAINT lots_status_check CHECK ((status = ANY (ARRAY['active'::text, 'empty'::text, 'closed'::text])))
);


--
-- Name: lots_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.lots ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.lots_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: packaging_article_materials; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.packaging_article_materials (
    id bigint NOT NULL,
    article_id bigint NOT NULL,
    material_id bigint NOT NULL,
    quantity numeric NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    CONSTRAINT packaging_article_materials_quantity_check CHECK ((quantity > (0)::numeric))
);


--
-- Name: packaging_article_materials_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.packaging_article_materials ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.packaging_article_materials_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: packaging_articles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.packaging_articles (
    id bigint NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    package_format text NOT NULL,
    liters_per_unit numeric NOT NULL,
    ean text,
    mdrank_article_number text,
    sort_order integer DEFAULT 0 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    CONSTRAINT packaging_articles_code_check CHECK ((code ~ '^[a-z0-9_]+$'::text)),
    CONSTRAINT packaging_articles_liters_per_unit_check CHECK ((liters_per_unit > (0)::numeric)),
    CONSTRAINT packaging_articles_package_format_check CHECK ((package_format = ANY (ARRAY['bottle'::text, 'can'::text, 'keg'::text, 'tank'::text])))
);


--
-- Name: packaging_articles_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.packaging_articles ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.packaging_articles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: packaging_materials; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.packaging_materials (
    id bigint NOT NULL,
    code text NOT NULL,
    name text NOT NULL,
    unit text DEFAULT 'pcs'::text NOT NULL,
    mdrank_article_number text,
    sort_order integer DEFAULT 0 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    CONSTRAINT packaging_materials_code_check CHECK ((code ~ '^[a-z0-9_]+$'::text))
);


--
-- Name: packaging_materials_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.packaging_materials ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.packaging_materials_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: permission_modules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.permission_modules (
    module_key text NOT NULL,
    name text NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL
);


--
-- Name: processing_comments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.processing_comments (
    id bigint NOT NULL,
    batch_id bigint NOT NULL,
    comment_time time without time zone,
    comment text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid
);


--
-- Name: processing_comments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.processing_comments ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.processing_comments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: processing_sessions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.processing_sessions ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.processing_sessions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: product_sheet_revisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.product_sheet_revisions (
    id bigint NOT NULL,
    product_sheet_id bigint NOT NULL,
    version integer NOT NULL,
    recipe_version_major integer,
    recipe_version_minor integer,
    date date DEFAULT CURRENT_DATE NOT NULL,
    changed_by_name text,
    change_description text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: product_sheet_revisions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.product_sheet_revisions ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.product_sheet_revisions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: product_sheets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.product_sheets (
    id bigint NOT NULL,
    recipe_group_id uuid NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    current_version integer DEFAULT 1 NOT NULL,
    excise_tax_category text,
    barrel_aged_hl numeric,
    barrel_type text,
    barrel_days numeric,
    energy_kj numeric,
    energy_kcal numeric,
    fat_g numeric,
    carbohydrates_g numeric,
    protein_g numeric,
    salt_g numeric,
    remarks text,
    sync_snapshot jsonb,
    based_on_version_major integer,
    based_on_version_minor integer,
    updated_at timestamp with time zone,
    updated_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid,
    CONSTRAINT product_sheets_status_check CHECK ((status = ANY (ARRAY['active'::text, 'archived'::text])))
);


--
-- Name: COLUMN product_sheets.sync_snapshot; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.product_sheets.sync_snapshot IS 'Snapshot van alleen de label-relevante receptvelden bij de laatste Update, voor de rood/groen sync-status. Vergelijk live tegen dezelfde velden, niet tegen recipes.versie_major/minor als geheel.';


--
-- Name: product_sheet_status; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.product_sheet_status WITH (security_invoker='true') AS
 SELECT id AS product_sheet_id,
    recipe_group_id,
    status,
    current_version,
    updated_at,
    based_on_version_major,
    based_on_version_minor,
    (sync_snapshot ->> 'hash'::text) AS stored_hash,
    public.product_sheet_relevant_hash(recipe_group_id) AS current_hash,
    COALESCE(((sync_snapshot ->> 'hash'::text) = public.product_sheet_relevant_hash(recipe_group_id)), false) AS in_sync
   FROM public.product_sheets ps
  WHERE (status <> 'archived'::text);


--
-- Name: product_sheets_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.product_sheets ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.product_sheets_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: recipe_brewing_specs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recipe_brewing_specs (
    recipe_id bigint NOT NULL,
    mash_filter_chambers numeric,
    roller_mill text,
    mash_thickness numeric,
    boil_volume numeric,
    wort_precooler_temp numeric,
    brew_final_volume numeric,
    target_evaporation numeric,
    boil_intensity numeric,
    whirlpool_rest numeric,
    lauter_factor numeric,
    special_bin_load_kg numeric,
    special_bin_name text,
    mash_in_temp numeric,
    mash_in_time numeric,
    mash_step1_temp numeric,
    mash_step1_time numeric,
    mash_step2_temp numeric,
    mash_step2_time numeric,
    mash_step3_temp numeric,
    mash_step3_time numeric,
    mash_step4_temp numeric,
    mash_step4_time numeric,
    mash_out_temp numeric,
    mash_out_time numeric,
    cumulative_sparge_volume numeric,
    expected_extract_boil_start numeric,
    water_addition_volume_cooling numeric,
    sparge_1 numeric,
    sparge_2 numeric,
    sparge_3 numeric,
    sparge_4 numeric,
    first_wort numeric,
    sparge_water numeric,
    sparge_runoff numeric,
    total_lautered_volume numeric,
    mash_in_acid_l numeric,
    mash_in_tannins_l numeric,
    boil_acid_l numeric,
    inline_sparge_acid_l numeric,
    mash_water numeric,
    ph_mash text,
    ph_boil_start text,
    ph_boil_end text,
    aeration numeric,
    original_gravity_correction_brewhouse numeric,
    brewhouse_recipe_name_wp text,
    brewhouse_recipe_name_jk text
);


--
-- Name: recipe_cellar_steps; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recipe_cellar_steps (
    id bigint NOT NULL,
    recipe_id bigint NOT NULL,
    sort_order integer NOT NULL,
    tag_id bigint NOT NULL,
    title text NOT NULL,
    description text,
    trigger_type text NOT NULL,
    trigger_value numeric,
    trigger_tol numeric,
    planned_day numeric,
    recipe_ingredient_ids bigint[] DEFAULT '{}'::bigint[] NOT NULL,
    starts_lagering boolean DEFAULT false NOT NULL,
    is_generated boolean DEFAULT true NOT NULL,
    generated_key text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid DEFAULT auth.uid(),
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    CONSTRAINT recipe_cellar_steps_day_check CHECK (((trigger_type <> 'day'::text) OR (planned_day IS NOT NULL))),
    CONSTRAINT recipe_cellar_steps_trigger_type_check CHECK ((trigger_type = ANY (ARRAY['extract'::text, 'day'::text, 'after_previous'::text, 'temperature'::text])))
);


--
-- Name: recipe_cellar_steps_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.recipe_cellar_steps ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.recipe_cellar_steps_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: recipe_comments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recipe_comments (
    recipe_id bigint NOT NULL,
    comments text[]
);


--
-- Name: recipe_costs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recipe_costs (
    recipe_id bigint NOT NULL,
    cost_cellar_per_kge numeric,
    cost_brewhouse_per_kge numeric,
    cost_ingredients_per_hl numeric,
    beer_loss_pct numeric
);


--
-- Name: recipe_fermentation; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recipe_fermentation (
    recipe_id bigint NOT NULL,
    pitching_temp numeric,
    main_ferm_temp numeric,
    release_temp numeric,
    dry_hop_warm_temp numeric,
    dry_hop_warm_extract_1 numeric,
    dry_hop_warm_extract_2 numeric,
    dry_hop_warm_extract_3 numeric,
    fermentation_time numeric,
    lagering_time numeric,
    lagering_temp numeric,
    pasteurization numeric,
    turbidity_after_separation numeric,
    beer_risk text,
    beer_status text,
    pitching_temp_tol text,
    main_ferm_temp_tol text,
    release_temp_tol text,
    dry_hop_warm_temp_tol text,
    dry_hop_warm_extract_1_tol text,
    dry_hop_warm_extract_2_tol text,
    dry_hop_warm_extract_3_tol text,
    fermentation_time_tol text,
    lagering_time_tol text,
    lagering_temp_tol text,
    pasteurization_tol text,
    turbidity_after_separation_tol text,
    bitterness_brewhouse numeric,
    bitterness_brewhouse_tol text,
    CONSTRAINT recipe_fermentation_beer_risk_check CHECK (((beer_risk IS NULL) OR (beer_risk = ANY (ARRAY['standard'::text, 'dangerous'::text, 'contains_sugar'::text, 'sensitive'::text])))),
    CONSTRAINT recipe_fermentation_beer_status_check CHECK (((beer_status IS NULL) OR (beer_status = ANY (ARRAY['standard'::text, 'npi'::text, 'to_improve'::text]))))
);


--
-- Name: recipe_ingredients_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.recipe_ingredients ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.recipe_ingredients_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: recipe_packaging; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recipe_packaging (
    recipe_id bigint NOT NULL,
    ean_bottle text,
    best_before_bottle_months numeric,
    best_before_keg_months numeric,
    best_before_can_months numeric,
    abv_pct numeric,
    formats jsonb,
    tpo_spec numeric,
    hso_spec numeric,
    do_spec numeric,
    co2_bottle_can_spec numeric,
    co2_bottle_can_tolerance numeric,
    co2_keg_spec numeric,
    co2_keg_tolerance numeric,
    o2_keg_spec numeric
);


--
-- Name: recipe_process_steps; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recipe_process_steps (
    recipe_id bigint NOT NULL,
    dry_hop_warm boolean DEFAULT false,
    dry_hop_cold boolean DEFAULT false,
    hopsteiner boolean DEFAULT false,
    bevasil boolean DEFAULT false,
    nagardo boolean DEFAULT false,
    gluten_test boolean DEFAULT false,
    sample_to_lab boolean DEFAULT false,
    fuge_after_cooling boolean DEFAULT false,
    cool_to_7c boolean DEFAULT false,
    cool_to_0c boolean DEFAULT false,
    check_hbt_addition boolean DEFAULT false,
    cellar_split boolean DEFAULT false,
    cellar_add_1 boolean DEFAULT false,
    cellar_add_2 boolean DEFAULT false,
    cellar_add_3 boolean DEFAULT false,
    cellar_add_4 boolean DEFAULT false,
    dry_hop_0c boolean,
    dry_hop_comment_warm text,
    dry_hop_method_warm text,
    dry_hop_comment_16c text,
    dry_hop_method_16c text,
    dry_hop_1_day integer,
    dry_hop_2_day integer,
    cellar_addition_day integer,
    processing_comment text,
    total_wp_hop numeric,
    total_dry_hop numeric
);


--
-- Name: recipe_revisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recipe_revisions (
    id bigint NOT NULL,
    recipe_id bigint NOT NULL,
    date date,
    changed_by_name text,
    change_description text,
    version_major integer,
    version_minor integer,
    user_id uuid
);


--
-- Name: recipe_revisions_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.recipe_revisions ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.recipe_revisions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: recipe_specs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recipe_specs (
    recipe_id bigint NOT NULL,
    original_extract numeric,
    final_extract numeric,
    alcohol numeric,
    bitterness numeric,
    color numeric,
    ph numeric,
    adf_pct numeric,
    turbidity_lab numeric,
    co2_bottle numeric,
    co2_can numeric,
    co2_keg numeric,
    headspace_o2 numeric,
    dissolved_o2 numeric,
    original_extract_tol text,
    final_extract_tol text,
    alcohol_tol text,
    bitterness_tol text,
    color_tol text,
    ph_tol text,
    adf_pct_tol text,
    turbidity_lab_tol text,
    co2_bottle_tol text,
    co2_can_tol text,
    co2_keg_tol text,
    headspace_o2_tol text,
    dissolved_o2_tol text
);


--
-- Name: recipe_water; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recipe_water (
    recipe_id bigint NOT NULL,
    ca numeric,
    mg numeric,
    na numeric,
    cl numeric,
    so4 numeric,
    ratio_cl_so4 numeric,
    alkalinity numeric
);


--
-- Name: recipes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recipes (
    id bigint NOT NULL,
    name text NOT NULL,
    beer_style text,
    location text,
    status text DEFAULT 'active'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    version_major integer DEFAULT 1 NOT NULL,
    version_minor integer DEFAULT 0 NOT NULL,
    created_by uuid,
    updated_by uuid,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    recipe_group_id uuid DEFAULT gen_random_uuid() NOT NULL,
    brew_volume_hl numeric,
    recipe_color text,
    flavor_description text,
    flavor_keywords text[],
    serving_temperature numeric,
    color_srm numeric,
    color_free_text text,
    CONSTRAINT recipes_location_check CHECK ((location = ANY (ARRAY['wp'::text, 'jk'::text]))),
    CONSTRAINT recipes_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'active'::text, 'archived'::text])))
);


--
-- Name: recipes_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.recipes ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.recipes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: role_permissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.role_permissions (
    role_id bigint NOT NULL,
    module_key text NOT NULL,
    can_view boolean DEFAULT false NOT NULL,
    can_edit boolean DEFAULT false NOT NULL,
    can_delete boolean DEFAULT false NOT NULL
);


--
-- Name: roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.roles (
    id bigint NOT NULL,
    name text NOT NULL,
    is_system_role boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: roles_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.roles ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.roles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: stock_movements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stock_movements (
    id bigint NOT NULL,
    lot_id bigint,
    movement_type text NOT NULL,
    quantity numeric NOT NULL,
    batch_id bigint,
    recipe_ingredient_id bigint,
    note text,
    booked_in_accounting boolean DEFAULT false NOT NULL,
    booked_by uuid,
    booked_at timestamp with time zone,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    off_recipe boolean DEFAULT false NOT NULL,
    entered_quantity numeric,
    entered_unit text,
    is_spoilage boolean DEFAULT false NOT NULL,
    is_correction boolean DEFAULT false NOT NULL,
    CONSTRAINT stock_movements_movement_type_check CHECK ((movement_type = ANY (ARRAY['receipt'::text, 'reservation'::text, 'consumption'::text, 'correction'::text])))
);


--
-- Name: stock_movements_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.stock_movements ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.stock_movements_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: tanks_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.tanks ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.tanks_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: units; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.units (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    code text NOT NULL,
    label text,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: water_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.water_settings (
    id smallint DEFAULT 1 NOT NULL,
    description text DEFAULT 'Jopen ambient water'::text NOT NULL,
    measured_on date,
    ca numeric NOT NULL,
    mg numeric NOT NULL,
    na numeric NOT NULL,
    cl numeric NOT NULL,
    so4 numeric NOT NULL,
    alkalinity numeric,
    max_ca numeric DEFAULT 300 NOT NULL,
    max_mg numeric DEFAULT 30 NOT NULL,
    max_cl numeric DEFAULT 400 NOT NULL,
    max_so4 numeric DEFAULT 600 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_by uuid,
    CONSTRAINT water_settings_id_check CHECK ((id = 1))
);


--
-- Name: water_settings_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.water_settings_history (
    id bigint NOT NULL,
    valid_from timestamp with time zone NOT NULL,
    updated_by uuid,
    data jsonb NOT NULL
);


--
-- Name: water_settings_history_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.water_settings_history ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.water_settings_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: batch_audit_log batch_audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_audit_log
    ADD CONSTRAINT batch_audit_log_pkey PRIMARY KEY (id);


--
-- Name: batch_brew_comments batch_brew_comments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_brew_comments
    ADD CONSTRAINT batch_brew_comments_pkey PRIMARY KEY (id);


--
-- Name: batch_brews batch_brews_batch_brew_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_brews
    ADD CONSTRAINT batch_brews_batch_brew_number_key UNIQUE (batch_id, brew_number);


--
-- Name: batch_brews batch_brews_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_brews
    ADD CONSTRAINT batch_brews_pkey PRIMARY KEY (id);


--
-- Name: batch_cellar_steps batch_cellar_steps_id_batch_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_cellar_steps
    ADD CONSTRAINT batch_cellar_steps_id_batch_key UNIQUE (id, batch_id);


--
-- Name: batch_cellar_steps batch_cellar_steps_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_cellar_steps
    ADD CONSTRAINT batch_cellar_steps_pkey PRIMARY KEY (id);


--
-- Name: batch_documents batch_documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_documents
    ADD CONSTRAINT batch_documents_pkey PRIMARY KEY (id);


--
-- Name: batch_documents batch_documents_storage_path_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_documents
    ADD CONSTRAINT batch_documents_storage_path_key UNIQUE (storage_path);


--
-- Name: batch_hbts batch_hbts_id_batch_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_hbts
    ADD CONSTRAINT batch_hbts_id_batch_key UNIQUE (id, batch_id);


--
-- Name: batch_hbts batch_hbts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_hbts
    ADD CONSTRAINT batch_hbts_pkey PRIMARY KEY (id);


--
-- Name: batch_ingredients batch_ingredients_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_ingredients
    ADD CONSTRAINT batch_ingredients_pkey PRIMARY KEY (id);


--
-- Name: batch_transfers batch_transfers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_transfers
    ADD CONSTRAINT batch_transfers_pkey PRIMARY KEY (id);


--
-- Name: batches batches_batch_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batches
    ADD CONSTRAINT batches_batch_number_key UNIQUE (batch_number);


--
-- Name: batches batches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batches
    ADD CONSTRAINT batches_pkey PRIMARY KEY (id);


--
-- Name: brew_capacity brew_capacity_group_year_week_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brew_capacity
    ADD CONSTRAINT brew_capacity_group_year_week_key UNIQUE (capacity_group, iso_year, week_number);


--
-- Name: brew_capacity brew_capacity_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brew_capacity
    ADD CONSTRAINT brew_capacity_pkey PRIMARY KEY (id);


--
-- Name: brew_planning_history brew_planning_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brew_planning_history
    ADD CONSTRAINT brew_planning_history_pkey PRIMARY KEY (id);


--
-- Name: brew_planning brew_planning_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brew_planning
    ADD CONSTRAINT brew_planning_pkey PRIMARY KEY (id);


--
-- Name: brew_planning_splits brew_planning_splits_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brew_planning_splits
    ADD CONSTRAINT brew_planning_splits_pkey PRIMARY KEY (id);


--
-- Name: cellar_action_tags cellar_action_tags_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cellar_action_tags
    ADD CONSTRAINT cellar_action_tags_code_key UNIQUE (code);


--
-- Name: cellar_action_tags cellar_action_tags_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cellar_action_tags
    ADD CONSTRAINT cellar_action_tags_pkey PRIMARY KEY (id);


--
-- Name: cellar_plan_parts cellar_plan_parts_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cellar_plan_parts
    ADD CONSTRAINT cellar_plan_parts_code_key UNIQUE (code);


--
-- Name: cellar_plan_parts cellar_plan_parts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cellar_plan_parts
    ADD CONSTRAINT cellar_plan_parts_pkey PRIMARY KEY (id);


--
-- Name: document_types document_types_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_types
    ADD CONSTRAINT document_types_code_key UNIQUE (code);


--
-- Name: document_types document_types_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_types
    ADD CONSTRAINT document_types_pkey PRIMARY KEY (id);


--
-- Name: fermentation_log_entries fermentation_log_entries_id_batch_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fermentation_log_entries
    ADD CONSTRAINT fermentation_log_entries_id_batch_key UNIQUE (id, batch_id);


--
-- Name: fermentation_log_entries fermentation_log_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fermentation_log_entries
    ADD CONSTRAINT fermentation_log_entries_pkey PRIMARY KEY (id);


--
-- Name: fermentation_log_entry_tags fermentation_log_entry_tags_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fermentation_log_entry_tags
    ADD CONSTRAINT fermentation_log_entry_tags_pkey PRIMARY KEY (id);


--
-- Name: filling_measurements filling_measurements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.filling_measurements
    ADD CONSTRAINT filling_measurements_pkey PRIMARY KEY (id);


--
-- Name: filling_session_articles filling_session_articles_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.filling_session_articles
    ADD CONSTRAINT filling_session_articles_key UNIQUE (filling_session_id, article_id);


--
-- Name: filling_session_articles filling_session_articles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.filling_session_articles
    ADD CONSTRAINT filling_session_articles_pkey PRIMARY KEY (id);


--
-- Name: filling_session_materials filling_session_materials_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.filling_session_materials
    ADD CONSTRAINT filling_session_materials_key UNIQUE (filling_session_id, material_id);


--
-- Name: filling_session_materials filling_session_materials_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.filling_session_materials
    ADD CONSTRAINT filling_session_materials_pkey PRIMARY KEY (id);


--
-- Name: filling_sessions filling_sessions_id_batch_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.filling_sessions
    ADD CONSTRAINT filling_sessions_id_batch_key UNIQUE (id, batch_id);


--
-- Name: filling_sessions filling_sessions_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.filling_sessions
    ADD CONSTRAINT filling_sessions_number_key UNIQUE (batch_id, session_number);


--
-- Name: filling_sessions filling_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.filling_sessions
    ADD CONSTRAINT filling_sessions_pkey PRIMARY KEY (id);


--
-- Name: hbt_readings hbt_readings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hbt_readings
    ADD CONSTRAINT hbt_readings_pkey PRIMARY KEY (id);


--
-- Name: ingredient_categories ingredient_categories_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredient_categories
    ADD CONSTRAINT ingredient_categories_name_key UNIQUE (name);


--
-- Name: ingredient_categories ingredient_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredient_categories
    ADD CONSTRAINT ingredient_categories_pkey PRIMARY KEY (id);


--
-- Name: ingredient_declarations ingredient_declarations_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredient_declarations
    ADD CONSTRAINT ingredient_declarations_name_key UNIQUE (name);


--
-- Name: ingredient_declarations ingredient_declarations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredient_declarations
    ADD CONSTRAINT ingredient_declarations_pkey PRIMARY KEY (id);


--
-- Name: ingredient_documents ingredient_documents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredient_documents
    ADD CONSTRAINT ingredient_documents_pkey PRIMARY KEY (id);


--
-- Name: ingredient_documents ingredient_documents_storage_path_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredient_documents
    ADD CONSTRAINT ingredient_documents_storage_path_key UNIQUE (storage_path);


--
-- Name: ingredient_revisions ingredient_revisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredient_revisions
    ADD CONSTRAINT ingredient_revisions_pkey PRIMARY KEY (id);


--
-- Name: ingredients ingredients_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredients
    ADD CONSTRAINT ingredients_pkey PRIMARY KEY (id);


--
-- Name: lots lots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lots
    ADD CONSTRAINT lots_pkey PRIMARY KEY (id);


--
-- Name: packaging_article_materials packaging_article_materials_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.packaging_article_materials
    ADD CONSTRAINT packaging_article_materials_key UNIQUE (article_id, material_id);


--
-- Name: packaging_article_materials packaging_article_materials_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.packaging_article_materials
    ADD CONSTRAINT packaging_article_materials_pkey PRIMARY KEY (id);


--
-- Name: packaging_articles packaging_articles_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.packaging_articles
    ADD CONSTRAINT packaging_articles_code_key UNIQUE (code);


--
-- Name: packaging_articles packaging_articles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.packaging_articles
    ADD CONSTRAINT packaging_articles_pkey PRIMARY KEY (id);


--
-- Name: packaging_materials packaging_materials_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.packaging_materials
    ADD CONSTRAINT packaging_materials_code_key UNIQUE (code);


--
-- Name: packaging_materials packaging_materials_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.packaging_materials
    ADD CONSTRAINT packaging_materials_pkey PRIMARY KEY (id);


--
-- Name: permission_modules permission_modules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.permission_modules
    ADD CONSTRAINT permission_modules_pkey PRIMARY KEY (module_key);


--
-- Name: processing_comments processing_comments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.processing_comments
    ADD CONSTRAINT processing_comments_pkey PRIMARY KEY (id);


--
-- Name: processing_sessions processing_sessions_id_batch_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.processing_sessions
    ADD CONSTRAINT processing_sessions_id_batch_key UNIQUE (id, batch_id);


--
-- Name: processing_sessions processing_sessions_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.processing_sessions
    ADD CONSTRAINT processing_sessions_number_key UNIQUE (batch_id, session_number);


--
-- Name: processing_sessions processing_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.processing_sessions
    ADD CONSTRAINT processing_sessions_pkey PRIMARY KEY (id);


--
-- Name: product_sheet_revisions product_sheet_revisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_sheet_revisions
    ADD CONSTRAINT product_sheet_revisions_pkey PRIMARY KEY (id);


--
-- Name: product_sheets product_sheets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_sheets
    ADD CONSTRAINT product_sheets_pkey PRIMARY KEY (id);


--
-- Name: recipe_brewing_specs recipe_brewing_specs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_brewing_specs
    ADD CONSTRAINT recipe_brewing_specs_pkey PRIMARY KEY (recipe_id);


--
-- Name: recipe_cellar_steps recipe_cellar_steps_key_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_cellar_steps
    ADD CONSTRAINT recipe_cellar_steps_key_unique UNIQUE (recipe_id, generated_key);


--
-- Name: recipe_cellar_steps recipe_cellar_steps_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_cellar_steps
    ADD CONSTRAINT recipe_cellar_steps_pkey PRIMARY KEY (id);


--
-- Name: recipe_comments recipe_comments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_comments
    ADD CONSTRAINT recipe_comments_pkey PRIMARY KEY (recipe_id);


--
-- Name: recipe_costs recipe_costs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_costs
    ADD CONSTRAINT recipe_costs_pkey PRIMARY KEY (recipe_id);


--
-- Name: recipe_fermentation recipe_fermentation_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_fermentation
    ADD CONSTRAINT recipe_fermentation_pkey PRIMARY KEY (recipe_id);


--
-- Name: recipe_ingredients recipe_ingredients_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_ingredients
    ADD CONSTRAINT recipe_ingredients_pkey PRIMARY KEY (id);


--
-- Name: recipe_packaging recipe_packaging_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_packaging
    ADD CONSTRAINT recipe_packaging_pkey PRIMARY KEY (recipe_id);


--
-- Name: recipe_process_steps recipe_process_steps_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_process_steps
    ADD CONSTRAINT recipe_process_steps_pkey PRIMARY KEY (recipe_id);


--
-- Name: recipe_revisions recipe_revisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_revisions
    ADD CONSTRAINT recipe_revisions_pkey PRIMARY KEY (id);


--
-- Name: recipe_specs recipe_specs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_specs
    ADD CONSTRAINT recipe_specs_pkey PRIMARY KEY (recipe_id);


--
-- Name: recipe_water recipe_water_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_water
    ADD CONSTRAINT recipe_water_pkey PRIMARY KEY (recipe_id);


--
-- Name: recipes recipes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipes
    ADD CONSTRAINT recipes_pkey PRIMARY KEY (id);


--
-- Name: role_permissions role_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_permissions
    ADD CONSTRAINT role_permissions_pkey PRIMARY KEY (role_id, module_key);


--
-- Name: roles roles_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_name_key UNIQUE (name);


--
-- Name: roles roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_pkey PRIMARY KEY (id);


--
-- Name: stock_movements stock_movements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_movements
    ADD CONSTRAINT stock_movements_pkey PRIMARY KEY (id);


--
-- Name: tanks tanks_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tanks
    ADD CONSTRAINT tanks_code_key UNIQUE (code);


--
-- Name: tanks tanks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tanks
    ADD CONSTRAINT tanks_pkey PRIMARY KEY (id);


--
-- Name: units units_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.units
    ADD CONSTRAINT units_code_key UNIQUE (code);


--
-- Name: units units_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.units
    ADD CONSTRAINT units_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: water_settings_history water_settings_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.water_settings_history
    ADD CONSTRAINT water_settings_history_pkey PRIMARY KEY (id);


--
-- Name: water_settings water_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.water_settings
    ADD CONSTRAINT water_settings_pkey PRIMARY KEY (id);


--
-- Name: batch_documents_type_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX batch_documents_type_key ON public.batch_documents USING btree (batch_id, document_type) WHERE (document_type <> 'other'::text);


--
-- Name: brew_planning_splits_brew_planning_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX brew_planning_splits_brew_planning_id_idx ON public.brew_planning_splits USING btree (brew_planning_id);


--
-- Name: idx_batch_audit_log_batch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_batch_audit_log_batch_id ON public.batch_audit_log USING btree (batch_id, changed_at);


--
-- Name: idx_batch_brew_comments_batch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_batch_brew_comments_batch_id ON public.batch_brew_comments USING btree (batch_id);


--
-- Name: idx_batch_cellar_steps_batch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_batch_cellar_steps_batch_id ON public.batch_cellar_steps USING btree (batch_id, sort_order);


--
-- Name: idx_batch_documents_batch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_batch_documents_batch_id ON public.batch_documents USING btree (batch_id);


--
-- Name: idx_batch_documents_uploaded_by; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_batch_documents_uploaded_by ON public.batch_documents USING btree (uploaded_by);


--
-- Name: idx_batch_hbts_batch_tank; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_batch_hbts_batch_tank ON public.batch_hbts USING btree (batch_id, tank_id);


--
-- Name: idx_batch_hbts_tank_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_batch_hbts_tank_id ON public.batch_hbts USING btree (tank_id);


--
-- Name: idx_batch_ingredients_batch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_batch_ingredients_batch_id ON public.batch_ingredients USING btree (batch_id);


--
-- Name: idx_batch_ingredients_ingredient_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_batch_ingredients_ingredient_id ON public.batch_ingredients USING btree (ingredient_id);


--
-- Name: idx_batch_ingredients_recipe_ingredient_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_batch_ingredients_recipe_ingredient_id ON public.batch_ingredients USING btree (recipe_ingredient_id);


--
-- Name: idx_batch_transfers_batch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_batch_transfers_batch_id ON public.batch_transfers USING btree (batch_id);


--
-- Name: idx_batch_transfers_from_tank_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_batch_transfers_from_tank_id ON public.batch_transfers USING btree (from_tank_id);


--
-- Name: idx_batch_transfers_to_batch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_batch_transfers_to_batch_id ON public.batch_transfers USING btree (to_batch_id);


--
-- Name: idx_batches_batch_number; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_batches_batch_number ON public.batches USING btree (batch_number DESC);


--
-- Name: idx_batches_glt_tank_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_batches_glt_tank_id ON public.batches USING btree (glt_tank_id);


--
-- Name: idx_batches_lt_tank_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_batches_lt_tank_id ON public.batches USING btree (lt_tank_id);


--
-- Name: idx_batches_recipe_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_batches_recipe_id ON public.batches USING btree (recipe_id);


--
-- Name: idx_brew_capacity_year_week; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_brew_capacity_year_week ON public.brew_capacity USING btree (iso_year, week_number);


--
-- Name: idx_brew_planning_history_planning_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_brew_planning_history_planning_id ON public.brew_planning_history USING btree (brew_planning_id);


--
-- Name: idx_brew_planning_history_updated_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_brew_planning_history_updated_at ON public.brew_planning_history USING btree (updated_at DESC);


--
-- Name: idx_brew_planning_recipe; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_brew_planning_recipe ON public.brew_planning USING btree (recipe_id);


--
-- Name: idx_brew_planning_recipe_group_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_brew_planning_recipe_group_id ON public.brew_planning USING btree (recipe_group_id);


--
-- Name: idx_brew_planning_splits_recipe_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_brew_planning_splits_recipe_id ON public.brew_planning_splits USING btree (recipe_id);


--
-- Name: idx_brew_planning_year_week; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_brew_planning_year_week ON public.brew_planning USING btree (iso_year, week_number);


--
-- Name: idx_cellar_plan_parts_tag_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cellar_plan_parts_tag_id ON public.cellar_plan_parts USING btree (tag_id);


--
-- Name: idx_fermentation_log_entries_batch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_fermentation_log_entries_batch_id ON public.fermentation_log_entries USING btree (batch_id, measured_at);


--
-- Name: idx_fermentation_log_entry_tags_batch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_fermentation_log_entry_tags_batch_id ON public.fermentation_log_entry_tags USING btree (batch_id);


--
-- Name: idx_fermentation_log_entry_tags_entry_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_fermentation_log_entry_tags_entry_id ON public.fermentation_log_entry_tags USING btree (entry_id);


--
-- Name: idx_fermentation_log_entry_tags_step; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_fermentation_log_entry_tags_step ON public.fermentation_log_entry_tags USING btree (batch_cellar_step_id, batch_id);


--
-- Name: idx_fermentation_log_entry_tags_tag_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_fermentation_log_entry_tags_tag_id ON public.fermentation_log_entry_tags USING btree (tag_id);


--
-- Name: idx_filling_measurements_batch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_filling_measurements_batch_id ON public.filling_measurements USING btree (batch_id);


--
-- Name: idx_filling_measurements_session; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_filling_measurements_session ON public.filling_measurements USING btree (filling_session_id, batch_id);


--
-- Name: idx_filling_session_articles_article; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_filling_session_articles_article ON public.filling_session_articles USING btree (article_id);


--
-- Name: idx_filling_session_articles_batch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_filling_session_articles_batch_id ON public.filling_session_articles USING btree (batch_id);


--
-- Name: idx_filling_session_articles_session; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_filling_session_articles_session ON public.filling_session_articles USING btree (filling_session_id, batch_id);


--
-- Name: idx_filling_session_materials_batch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_filling_session_materials_batch_id ON public.filling_session_materials USING btree (batch_id);


--
-- Name: idx_filling_session_materials_material; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_filling_session_materials_material ON public.filling_session_materials USING btree (material_id);


--
-- Name: idx_filling_session_materials_session; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_filling_session_materials_session ON public.filling_session_materials USING btree (filling_session_id, batch_id);


--
-- Name: idx_filling_sessions_hbt; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_filling_sessions_hbt ON public.filling_sessions USING btree (batch_hbt_id, batch_id);


--
-- Name: idx_hbt_readings_batch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_hbt_readings_batch_id ON public.hbt_readings USING btree (batch_id);


--
-- Name: idx_hbt_readings_hbt; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_hbt_readings_hbt ON public.hbt_readings USING btree (batch_hbt_id, batch_id, sort_order);


--
-- Name: idx_hbt_readings_session; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_hbt_readings_session ON public.hbt_readings USING btree (processing_session_id, batch_id);


--
-- Name: idx_ingredient_documents_ing_status_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ingredient_documents_ing_status_type ON public.ingredient_documents USING btree (ingredient_id, status, document_type_id);


--
-- Name: idx_ingredient_documents_ingredient_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ingredient_documents_ingredient_id ON public.ingredient_documents USING btree (ingredient_id);


--
-- Name: idx_ingredient_revisions_ingredient_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ingredient_revisions_ingredient_id ON public.ingredient_revisions USING btree (ingredient_id);


--
-- Name: idx_ingredients_group_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ingredients_group_id ON public.ingredients USING btree (ingredient_group_id);


--
-- Name: idx_lots_ingredient; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_lots_ingredient ON public.lots USING btree (ingredient_id);


--
-- Name: idx_lots_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_lots_status ON public.lots USING btree (status);


--
-- Name: idx_packaging_article_materials_material; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_packaging_article_materials_material ON public.packaging_article_materials USING btree (material_id);


--
-- Name: idx_processing_comments_batch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_processing_comments_batch_id ON public.processing_comments USING btree (batch_id);


--
-- Name: idx_processing_sessions_tank_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_processing_sessions_tank_id ON public.processing_sessions USING btree (tank_id);


--
-- Name: idx_recipe_cellar_steps_recipe_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recipe_cellar_steps_recipe_id ON public.recipe_cellar_steps USING btree (recipe_id, sort_order);


--
-- Name: idx_recipe_ingredients_ingredient_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recipe_ingredients_ingredient_id ON public.recipe_ingredients USING btree (ingredient_id);


--
-- Name: idx_recipe_ingredients_recipe_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recipe_ingredients_recipe_id ON public.recipe_ingredients USING btree (recipe_id);


--
-- Name: idx_recipe_ingredients_source_group; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recipe_ingredients_source_group ON public.recipe_ingredients USING btree (source_recipe_group_id) WHERE (source_recipe_group_id IS NOT NULL);


--
-- Name: idx_recipe_revisions_recipe_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recipe_revisions_recipe_id ON public.recipe_revisions USING btree (recipe_id);


--
-- Name: idx_recipes_recipe_group_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recipes_recipe_group_id ON public.recipes USING btree (recipe_group_id);


--
-- Name: idx_stock_movements_batch; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_stock_movements_batch ON public.stock_movements USING btree (batch_id);


--
-- Name: idx_stock_movements_lot; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_stock_movements_lot ON public.stock_movements USING btree (lot_id);


--
-- Name: idx_stock_movements_movement_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_stock_movements_movement_type ON public.stock_movements USING btree (movement_type);


--
-- Name: idx_stock_movements_recipe_ingredient_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_stock_movements_recipe_ingredient_id ON public.stock_movements USING btree (recipe_ingredient_id);


--
-- Name: product_sheet_revisions_product_sheet_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX product_sheet_revisions_product_sheet_id_idx ON public.product_sheet_revisions USING btree (product_sheet_id);


--
-- Name: product_sheets_recipe_group_id_active_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX product_sheets_recipe_group_id_active_idx ON public.product_sheets USING btree (recipe_group_id) WHERE (status <> 'archived'::text);


--
-- Name: users_initials_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX users_initials_key ON public.users USING btree (upper(initials)) WHERE (initials IS NOT NULL);


--
-- Name: batch_brew_comments trg_batch_brew_comments_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_batch_brew_comments_audit AFTER INSERT OR DELETE OR UPDATE ON public.batch_brew_comments FOR EACH ROW EXECUTE FUNCTION public.log_batch_change();


--
-- Name: batch_brew_comments trg_batch_brew_comments_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_batch_brew_comments_updated_at BEFORE UPDATE ON public.batch_brew_comments FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: batch_brews trg_batch_brews_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_batch_brews_audit AFTER INSERT OR DELETE OR UPDATE ON public.batch_brews FOR EACH ROW EXECUTE FUNCTION public.log_batch_change();


--
-- Name: batch_brews trg_batch_brews_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_batch_brews_updated_at BEFORE UPDATE ON public.batch_brews FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: batch_cellar_steps trg_batch_cellar_steps_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_batch_cellar_steps_audit AFTER INSERT OR DELETE OR UPDATE ON public.batch_cellar_steps FOR EACH ROW EXECUTE FUNCTION public.log_batch_change();


--
-- Name: batch_cellar_steps trg_batch_cellar_steps_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_batch_cellar_steps_updated_at BEFORE UPDATE ON public.batch_cellar_steps FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: batch_documents trg_batch_documents_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_batch_documents_audit AFTER INSERT OR DELETE OR UPDATE ON public.batch_documents FOR EACH ROW EXECUTE FUNCTION public.log_batch_change();


--
-- Name: batch_documents trg_batch_documents_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_batch_documents_updated_at BEFORE UPDATE ON public.batch_documents FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: batch_hbts trg_batch_hbts_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_batch_hbts_audit AFTER INSERT OR DELETE OR UPDATE ON public.batch_hbts FOR EACH ROW EXECUTE FUNCTION public.log_batch_change();


--
-- Name: batch_hbts trg_batch_hbts_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_batch_hbts_updated_at BEFORE UPDATE ON public.batch_hbts FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: batch_ingredients trg_batch_ingredients_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_batch_ingredients_audit AFTER INSERT OR DELETE OR UPDATE ON public.batch_ingredients FOR EACH ROW EXECUTE FUNCTION public.log_batch_change();


--
-- Name: batch_ingredients trg_batch_ingredients_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_batch_ingredients_updated_at BEFORE UPDATE ON public.batch_ingredients FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: batch_transfers trg_batch_transfers_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_batch_transfers_audit AFTER INSERT OR DELETE OR UPDATE ON public.batch_transfers FOR EACH ROW EXECUTE FUNCTION public.log_batch_change();


--
-- Name: batch_transfers trg_batch_transfers_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_batch_transfers_updated_at BEFORE UPDATE ON public.batch_transfers FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: batches trg_batches_snapshot_ingredients; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_batches_snapshot_ingredients AFTER INSERT ON public.batches FOR EACH ROW EXECUTE FUNCTION public.snapshot_new_batch();


--
-- Name: brew_planning trg_brew_planning_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_brew_planning_history AFTER INSERT OR DELETE OR UPDATE ON public.brew_planning FOR EACH ROW EXECUTE FUNCTION public.log_brew_planning_change();


--
-- Name: cellar_action_tags trg_cellar_action_tags_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_cellar_action_tags_updated_at BEFORE UPDATE ON public.cellar_action_tags FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: cellar_plan_parts trg_cellar_plan_parts_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_cellar_plan_parts_updated_at BEFORE UPDATE ON public.cellar_plan_parts FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: fermentation_log_entries trg_fermentation_log_entries_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_fermentation_log_entries_audit AFTER INSERT OR DELETE OR UPDATE ON public.fermentation_log_entries FOR EACH ROW EXECUTE FUNCTION public.log_batch_change();


--
-- Name: fermentation_log_entries trg_fermentation_log_entries_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_fermentation_log_entries_updated_at BEFORE UPDATE ON public.fermentation_log_entries FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: fermentation_log_entry_tags trg_fermentation_log_entry_tags_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_fermentation_log_entry_tags_audit AFTER INSERT OR DELETE OR UPDATE ON public.fermentation_log_entry_tags FOR EACH ROW EXECUTE FUNCTION public.log_batch_change();


--
-- Name: filling_measurements trg_filling_measurements_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_filling_measurements_audit AFTER INSERT OR DELETE OR UPDATE ON public.filling_measurements FOR EACH ROW EXECUTE FUNCTION public.log_batch_change();


--
-- Name: filling_measurements trg_filling_measurements_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_filling_measurements_updated_at BEFORE UPDATE ON public.filling_measurements FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: filling_session_articles trg_filling_session_articles_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_filling_session_articles_audit AFTER INSERT OR DELETE OR UPDATE ON public.filling_session_articles FOR EACH ROW EXECUTE FUNCTION public.log_batch_change();


--
-- Name: filling_session_articles trg_filling_session_articles_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_filling_session_articles_updated_at BEFORE UPDATE ON public.filling_session_articles FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: filling_session_materials trg_filling_session_materials_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_filling_session_materials_audit AFTER INSERT OR DELETE OR UPDATE ON public.filling_session_materials FOR EACH ROW EXECUTE FUNCTION public.log_batch_change();


--
-- Name: filling_session_materials trg_filling_session_materials_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_filling_session_materials_updated_at BEFORE UPDATE ON public.filling_session_materials FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: filling_sessions trg_filling_sessions_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_filling_sessions_audit AFTER INSERT OR DELETE OR UPDATE ON public.filling_sessions FOR EACH ROW EXECUTE FUNCTION public.log_batch_change();


--
-- Name: filling_sessions trg_filling_sessions_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_filling_sessions_updated_at BEFORE UPDATE ON public.filling_sessions FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: hbt_readings trg_hbt_readings_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_hbt_readings_audit AFTER INSERT OR DELETE OR UPDATE ON public.hbt_readings FOR EACH ROW EXECUTE FUNCTION public.log_batch_change();


--
-- Name: hbt_readings trg_hbt_readings_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_hbt_readings_updated_at BEFORE UPDATE ON public.hbt_readings FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: ingredients trg_ingredients_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_ingredients_updated_at BEFORE UPDATE ON public.ingredients FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: packaging_article_materials trg_packaging_article_materials_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_packaging_article_materials_updated_at BEFORE UPDATE ON public.packaging_article_materials FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: packaging_articles trg_packaging_articles_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_packaging_articles_updated_at BEFORE UPDATE ON public.packaging_articles FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: packaging_materials trg_packaging_materials_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_packaging_materials_updated_at BEFORE UPDATE ON public.packaging_materials FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: processing_comments trg_processing_comments_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_processing_comments_audit AFTER INSERT OR DELETE OR UPDATE ON public.processing_comments FOR EACH ROW EXECUTE FUNCTION public.log_batch_change();


--
-- Name: processing_comments trg_processing_comments_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_processing_comments_updated_at BEFORE UPDATE ON public.processing_comments FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: processing_sessions trg_processing_sessions_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_processing_sessions_audit AFTER INSERT OR DELETE OR UPDATE ON public.processing_sessions FOR EACH ROW EXECUTE FUNCTION public.log_batch_change();


--
-- Name: processing_sessions trg_processing_sessions_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_processing_sessions_updated_at BEFORE UPDATE ON public.processing_sessions FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: recipe_cellar_steps trg_recipe_cellar_steps_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_recipe_cellar_steps_updated_at BEFORE UPDATE ON public.recipe_cellar_steps FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: recipes trg_recipes_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_recipes_updated_at BEFORE UPDATE ON public.recipes FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: tanks trg_tanks_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_tanks_updated_at BEFORE UPDATE ON public.tanks FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: water_settings trg_water_settings_log; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_water_settings_log AFTER INSERT OR UPDATE ON public.water_settings FOR EACH ROW EXECUTE FUNCTION public.water_settings_log();


--
-- Name: water_settings trg_water_settings_stamp; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_water_settings_stamp BEFORE UPDATE ON public.water_settings FOR EACH ROW EXECUTE FUNCTION public.water_settings_stamp();


--
-- Name: batch_brew_comments batch_brew_comments_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_brew_comments
    ADD CONSTRAINT batch_brew_comments_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES public.batches(id) ON DELETE CASCADE;


--
-- Name: batch_brew_comments batch_brew_comments_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_brew_comments
    ADD CONSTRAINT batch_brew_comments_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: batch_brew_comments batch_brew_comments_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_brew_comments
    ADD CONSTRAINT batch_brew_comments_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(id);


--
-- Name: batch_brews batch_brews_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_brews
    ADD CONSTRAINT batch_brews_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES public.batches(id) ON DELETE CASCADE;


--
-- Name: batch_brews batch_brews_brewer_end_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_brews
    ADD CONSTRAINT batch_brews_brewer_end_id_fkey FOREIGN KEY (brewer_end_id) REFERENCES public.users(id);


--
-- Name: batch_brews batch_brews_brewer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_brews
    ADD CONSTRAINT batch_brews_brewer_id_fkey FOREIGN KEY (brewer_id) REFERENCES public.users(id);


--
-- Name: batch_brews batch_brews_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_brews
    ADD CONSTRAINT batch_brews_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: batch_brews batch_brews_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_brews
    ADD CONSTRAINT batch_brews_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(id);


--
-- Name: batch_cellar_steps batch_cellar_steps_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_cellar_steps
    ADD CONSTRAINT batch_cellar_steps_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES public.batches(id) ON DELETE CASCADE;


--
-- Name: batch_cellar_steps batch_cellar_steps_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_cellar_steps
    ADD CONSTRAINT batch_cellar_steps_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: batch_cellar_steps batch_cellar_steps_recipe_cellar_step_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_cellar_steps
    ADD CONSTRAINT batch_cellar_steps_recipe_cellar_step_id_fkey FOREIGN KEY (recipe_cellar_step_id) REFERENCES public.recipe_cellar_steps(id) ON DELETE SET NULL;


--
-- Name: batch_cellar_steps batch_cellar_steps_tag_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_cellar_steps
    ADD CONSTRAINT batch_cellar_steps_tag_id_fkey FOREIGN KEY (tag_id) REFERENCES public.cellar_action_tags(id);


--
-- Name: batch_cellar_steps batch_cellar_steps_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_cellar_steps
    ADD CONSTRAINT batch_cellar_steps_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(id);


--
-- Name: batch_documents batch_documents_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_documents
    ADD CONSTRAINT batch_documents_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES public.batches(id) ON DELETE CASCADE;


--
-- Name: batch_documents batch_documents_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_documents
    ADD CONSTRAINT batch_documents_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: batch_documents batch_documents_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_documents
    ADD CONSTRAINT batch_documents_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(id);


--
-- Name: batch_documents batch_documents_uploaded_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_documents
    ADD CONSTRAINT batch_documents_uploaded_by_fkey FOREIGN KEY (uploaded_by) REFERENCES public.users(id);


--
-- Name: batch_hbts batch_hbts_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_hbts
    ADD CONSTRAINT batch_hbts_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES public.batches(id) ON DELETE CASCADE;


--
-- Name: batch_hbts batch_hbts_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_hbts
    ADD CONSTRAINT batch_hbts_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: batch_hbts batch_hbts_released_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_hbts
    ADD CONSTRAINT batch_hbts_released_by_fkey FOREIGN KEY (released_by) REFERENCES public.users(id);


--
-- Name: batch_hbts batch_hbts_tank_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_hbts
    ADD CONSTRAINT batch_hbts_tank_id_fkey FOREIGN KEY (tank_id) REFERENCES public.tanks(id);


--
-- Name: batch_hbts batch_hbts_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_hbts
    ADD CONSTRAINT batch_hbts_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(id);


--
-- Name: batch_ingredients batch_ingredients_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_ingredients
    ADD CONSTRAINT batch_ingredients_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES public.batches(id) ON DELETE CASCADE;


--
-- Name: batch_ingredients batch_ingredients_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_ingredients
    ADD CONSTRAINT batch_ingredients_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: batch_ingredients batch_ingredients_ingredient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_ingredients
    ADD CONSTRAINT batch_ingredients_ingredient_id_fkey FOREIGN KEY (ingredient_id) REFERENCES public.ingredients(id);


--
-- Name: batch_ingredients batch_ingredients_recipe_ingredient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_ingredients
    ADD CONSTRAINT batch_ingredients_recipe_ingredient_id_fkey FOREIGN KEY (recipe_ingredient_id) REFERENCES public.recipe_ingredients(id) ON DELETE SET NULL;


--
-- Name: batch_ingredients batch_ingredients_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_ingredients
    ADD CONSTRAINT batch_ingredients_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(id);


--
-- Name: batch_transfers batch_transfers_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_transfers
    ADD CONSTRAINT batch_transfers_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES public.batches(id) ON DELETE CASCADE;


--
-- Name: batch_transfers batch_transfers_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_transfers
    ADD CONSTRAINT batch_transfers_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: batch_transfers batch_transfers_from_tank_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_transfers
    ADD CONSTRAINT batch_transfers_from_tank_id_fkey FOREIGN KEY (from_tank_id) REFERENCES public.tanks(id);


--
-- Name: batch_transfers batch_transfers_to_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_transfers
    ADD CONSTRAINT batch_transfers_to_batch_id_fkey FOREIGN KEY (to_batch_id) REFERENCES public.batches(id);


--
-- Name: batch_transfers batch_transfers_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batch_transfers
    ADD CONSTRAINT batch_transfers_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(id);


--
-- Name: batches batches_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batches
    ADD CONSTRAINT batches_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: batches batches_glt_tank_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batches
    ADD CONSTRAINT batches_glt_tank_id_fkey FOREIGN KEY (glt_tank_id) REFERENCES public.tanks(id);


--
-- Name: batches batches_lt_tank_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batches
    ADD CONSTRAINT batches_lt_tank_id_fkey FOREIGN KEY (lt_tank_id) REFERENCES public.tanks(id);


--
-- Name: batches batches_order_picking_completed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batches
    ADD CONSTRAINT batches_order_picking_completed_by_fkey FOREIGN KEY (order_picking_completed_by) REFERENCES public.users(id);


--
-- Name: batches batches_recipe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batches
    ADD CONSTRAINT batches_recipe_id_fkey FOREIGN KEY (recipe_id) REFERENCES public.recipes(id);


--
-- Name: batches batches_yeast_pitched_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.batches
    ADD CONSTRAINT batches_yeast_pitched_by_fkey FOREIGN KEY (yeast_pitched_by) REFERENCES public.users(id);


--
-- Name: brew_capacity brew_capacity_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brew_capacity
    ADD CONSTRAINT brew_capacity_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(id);


--
-- Name: brew_planning brew_planning_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brew_planning
    ADD CONSTRAINT brew_planning_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: brew_planning_history brew_planning_history_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brew_planning_history
    ADD CONSTRAINT brew_planning_history_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(id);


--
-- Name: brew_planning brew_planning_recipe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brew_planning
    ADD CONSTRAINT brew_planning_recipe_id_fkey FOREIGN KEY (recipe_id) REFERENCES public.recipes(id);


--
-- Name: brew_planning_splits brew_planning_splits_brew_planning_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brew_planning_splits
    ADD CONSTRAINT brew_planning_splits_brew_planning_id_fkey FOREIGN KEY (brew_planning_id) REFERENCES public.brew_planning(id) ON DELETE CASCADE;


--
-- Name: brew_planning_splits brew_planning_splits_recipe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brew_planning_splits
    ADD CONSTRAINT brew_planning_splits_recipe_id_fkey FOREIGN KEY (recipe_id) REFERENCES public.recipes(id);


--
-- Name: cellar_action_tags cellar_action_tags_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cellar_action_tags
    ADD CONSTRAINT cellar_action_tags_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: cellar_action_tags cellar_action_tags_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cellar_action_tags
    ADD CONSTRAINT cellar_action_tags_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(id);


--
-- Name: cellar_plan_parts cellar_plan_parts_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cellar_plan_parts
    ADD CONSTRAINT cellar_plan_parts_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: cellar_plan_parts cellar_plan_parts_tag_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cellar_plan_parts
    ADD CONSTRAINT cellar_plan_parts_tag_id_fkey FOREIGN KEY (tag_id) REFERENCES public.cellar_action_tags(id);


--
-- Name: cellar_plan_parts cellar_plan_parts_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cellar_plan_parts
    ADD CONSTRAINT cellar_plan_parts_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(id);


--
-- Name: fermentation_log_entries fermentation_log_entries_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fermentation_log_entries
    ADD CONSTRAINT fermentation_log_entries_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES public.batches(id) ON DELETE CASCADE;


--
-- Name: fermentation_log_entries fermentation_log_entries_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fermentation_log_entries
    ADD CONSTRAINT fermentation_log_entries_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: fermentation_log_entries fermentation_log_entries_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fermentation_log_entries
    ADD CONSTRAINT fermentation_log_entries_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(id);


--
-- Name: fermentation_log_entry_tags fermentation_log_entry_tags_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fermentation_log_entry_tags
    ADD CONSTRAINT fermentation_log_entry_tags_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: fermentation_log_entry_tags fermentation_log_entry_tags_entry_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fermentation_log_entry_tags
    ADD CONSTRAINT fermentation_log_entry_tags_entry_fkey FOREIGN KEY (entry_id, batch_id) REFERENCES public.fermentation_log_entries(id, batch_id) ON DELETE CASCADE;


--
-- Name: fermentation_log_entry_tags fermentation_log_entry_tags_step_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fermentation_log_entry_tags
    ADD CONSTRAINT fermentation_log_entry_tags_step_fkey FOREIGN KEY (batch_cellar_step_id, batch_id) REFERENCES public.batch_cellar_steps(id, batch_id) ON DELETE SET NULL (batch_cellar_step_id);


--
-- Name: fermentation_log_entry_tags fermentation_log_entry_tags_tag_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fermentation_log_entry_tags
    ADD CONSTRAINT fermentation_log_entry_tags_tag_id_fkey FOREIGN KEY (tag_id) REFERENCES public.cellar_action_tags(id);


--
-- Name: filling_measurements filling_measurements_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.filling_measurements
    ADD CONSTRAINT filling_measurements_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: filling_measurements filling_measurements_session_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.filling_measurements
    ADD CONSTRAINT filling_measurements_session_fkey FOREIGN KEY (filling_session_id, batch_id) REFERENCES public.filling_sessions(id, batch_id) ON DELETE CASCADE;


--
-- Name: filling_measurements filling_measurements_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.filling_measurements
    ADD CONSTRAINT filling_measurements_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(id);


--
-- Name: filling_session_articles filling_session_articles_article_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.filling_session_articles
    ADD CONSTRAINT filling_session_articles_article_id_fkey FOREIGN KEY (article_id) REFERENCES public.packaging_articles(id);


--
-- Name: filling_session_articles filling_session_articles_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.filling_session_articles
    ADD CONSTRAINT filling_session_articles_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: filling_session_articles filling_session_articles_session_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.filling_session_articles
    ADD CONSTRAINT filling_session_articles_session_fkey FOREIGN KEY (filling_session_id, batch_id) REFERENCES public.filling_sessions(id, batch_id) ON DELETE CASCADE;


--
-- Name: filling_session_articles filling_session_articles_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.filling_session_articles
    ADD CONSTRAINT filling_session_articles_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(id);


--
-- Name: filling_session_materials filling_session_materials_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.filling_session_materials
    ADD CONSTRAINT filling_session_materials_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: filling_session_materials filling_session_materials_material_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.filling_session_materials
    ADD CONSTRAINT filling_session_materials_material_id_fkey FOREIGN KEY (material_id) REFERENCES public.packaging_materials(id);


--
-- Name: filling_session_materials filling_session_materials_session_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.filling_session_materials
    ADD CONSTRAINT filling_session_materials_session_fkey FOREIGN KEY (filling_session_id, batch_id) REFERENCES public.filling_sessions(id, batch_id) ON DELETE CASCADE;


--
-- Name: filling_session_materials filling_session_materials_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.filling_session_materials
    ADD CONSTRAINT filling_session_materials_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(id);


--
-- Name: filling_sessions filling_sessions_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.filling_sessions
    ADD CONSTRAINT filling_sessions_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES public.batches(id) ON DELETE CASCADE;


--
-- Name: filling_sessions filling_sessions_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.filling_sessions
    ADD CONSTRAINT filling_sessions_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: filling_sessions filling_sessions_hbt_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.filling_sessions
    ADD CONSTRAINT filling_sessions_hbt_fkey FOREIGN KEY (batch_hbt_id, batch_id) REFERENCES public.batch_hbts(id, batch_id) ON DELETE SET NULL (batch_hbt_id);


--
-- Name: filling_sessions filling_sessions_sampled_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.filling_sessions
    ADD CONSTRAINT filling_sessions_sampled_by_fkey FOREIGN KEY (sampled_by) REFERENCES public.users(id);


--
-- Name: filling_sessions filling_sessions_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.filling_sessions
    ADD CONSTRAINT filling_sessions_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(id);


--
-- Name: hbt_readings hbt_readings_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hbt_readings
    ADD CONSTRAINT hbt_readings_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: hbt_readings hbt_readings_hbt_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hbt_readings
    ADD CONSTRAINT hbt_readings_hbt_fkey FOREIGN KEY (batch_hbt_id, batch_id) REFERENCES public.batch_hbts(id, batch_id) ON DELETE CASCADE;


--
-- Name: hbt_readings hbt_readings_session_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hbt_readings
    ADD CONSTRAINT hbt_readings_session_fkey FOREIGN KEY (processing_session_id, batch_id) REFERENCES public.processing_sessions(id, batch_id) ON DELETE SET NULL (processing_session_id);


--
-- Name: hbt_readings hbt_readings_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.hbt_readings
    ADD CONSTRAINT hbt_readings_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(id);


--
-- Name: ingredient_documents ingredient_documents_document_type_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredient_documents
    ADD CONSTRAINT ingredient_documents_document_type_id_fkey FOREIGN KEY (document_type_id) REFERENCES public.document_types(id);


--
-- Name: ingredient_documents ingredient_documents_ingredient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredient_documents
    ADD CONSTRAINT ingredient_documents_ingredient_id_fkey FOREIGN KEY (ingredient_id) REFERENCES public.ingredients(id) ON DELETE CASCADE;


--
-- Name: ingredient_documents ingredient_documents_uploaded_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredient_documents
    ADD CONSTRAINT ingredient_documents_uploaded_by_fkey FOREIGN KEY (uploaded_by) REFERENCES public.users(id);


--
-- Name: ingredient_revisions ingredient_revisions_ingredient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredient_revisions
    ADD CONSTRAINT ingredient_revisions_ingredient_id_fkey FOREIGN KEY (ingredient_id) REFERENCES public.ingredients(id) ON DELETE CASCADE;


--
-- Name: ingredient_revisions ingredient_revisions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredient_revisions
    ADD CONSTRAINT ingredient_revisions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: ingredients ingredients_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredients
    ADD CONSTRAINT ingredients_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.ingredient_categories(id);


--
-- Name: ingredients ingredients_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredients
    ADD CONSTRAINT ingredients_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: ingredients ingredients_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredients
    ADD CONSTRAINT ingredients_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(id);


--
-- Name: lots lots_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lots
    ADD CONSTRAINT lots_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: lots lots_ingredient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lots
    ADD CONSTRAINT lots_ingredient_id_fkey FOREIGN KEY (ingredient_id) REFERENCES public.ingredients(id);


--
-- Name: lots lots_received_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lots
    ADD CONSTRAINT lots_received_by_fkey FOREIGN KEY (received_by) REFERENCES public.users(id);


--
-- Name: packaging_article_materials packaging_article_materials_article_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.packaging_article_materials
    ADD CONSTRAINT packaging_article_materials_article_id_fkey FOREIGN KEY (article_id) REFERENCES public.packaging_articles(id) ON DELETE CASCADE;


--
-- Name: packaging_article_materials packaging_article_materials_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.packaging_article_materials
    ADD CONSTRAINT packaging_article_materials_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: packaging_article_materials packaging_article_materials_material_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.packaging_article_materials
    ADD CONSTRAINT packaging_article_materials_material_id_fkey FOREIGN KEY (material_id) REFERENCES public.packaging_materials(id);


--
-- Name: packaging_article_materials packaging_article_materials_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.packaging_article_materials
    ADD CONSTRAINT packaging_article_materials_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(id);


--
-- Name: packaging_articles packaging_articles_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.packaging_articles
    ADD CONSTRAINT packaging_articles_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: packaging_articles packaging_articles_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.packaging_articles
    ADD CONSTRAINT packaging_articles_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(id);


--
-- Name: packaging_materials packaging_materials_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.packaging_materials
    ADD CONSTRAINT packaging_materials_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: packaging_materials packaging_materials_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.packaging_materials
    ADD CONSTRAINT packaging_materials_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(id);


--
-- Name: processing_comments processing_comments_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.processing_comments
    ADD CONSTRAINT processing_comments_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES public.batches(id) ON DELETE CASCADE;


--
-- Name: processing_comments processing_comments_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.processing_comments
    ADD CONSTRAINT processing_comments_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: processing_comments processing_comments_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.processing_comments
    ADD CONSTRAINT processing_comments_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(id);


--
-- Name: processing_sessions processing_sessions_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.processing_sessions
    ADD CONSTRAINT processing_sessions_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES public.batches(id) ON DELETE CASCADE;


--
-- Name: processing_sessions processing_sessions_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.processing_sessions
    ADD CONSTRAINT processing_sessions_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: processing_sessions processing_sessions_ended_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.processing_sessions
    ADD CONSTRAINT processing_sessions_ended_by_fkey FOREIGN KEY (ended_by) REFERENCES public.users(id);


--
-- Name: processing_sessions processing_sessions_started_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.processing_sessions
    ADD CONSTRAINT processing_sessions_started_by_fkey FOREIGN KEY (started_by) REFERENCES public.users(id);


--
-- Name: processing_sessions processing_sessions_tank_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.processing_sessions
    ADD CONSTRAINT processing_sessions_tank_id_fkey FOREIGN KEY (tank_id) REFERENCES public.tanks(id);


--
-- Name: processing_sessions processing_sessions_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.processing_sessions
    ADD CONSTRAINT processing_sessions_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(id);


--
-- Name: product_sheet_revisions product_sheet_revisions_product_sheet_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_sheet_revisions
    ADD CONSTRAINT product_sheet_revisions_product_sheet_id_fkey FOREIGN KEY (product_sheet_id) REFERENCES public.product_sheets(id) ON DELETE CASCADE;


--
-- Name: product_sheets product_sheets_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_sheets
    ADD CONSTRAINT product_sheets_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: product_sheets product_sheets_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_sheets
    ADD CONSTRAINT product_sheets_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(id);


--
-- Name: recipe_brewing_specs recipe_brewing_specs_recipe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_brewing_specs
    ADD CONSTRAINT recipe_brewing_specs_recipe_id_fkey FOREIGN KEY (recipe_id) REFERENCES public.recipes(id) ON DELETE CASCADE;


--
-- Name: recipe_cellar_steps recipe_cellar_steps_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_cellar_steps
    ADD CONSTRAINT recipe_cellar_steps_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: recipe_cellar_steps recipe_cellar_steps_recipe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_cellar_steps
    ADD CONSTRAINT recipe_cellar_steps_recipe_id_fkey FOREIGN KEY (recipe_id) REFERENCES public.recipes(id) ON DELETE CASCADE;


--
-- Name: recipe_cellar_steps recipe_cellar_steps_tag_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_cellar_steps
    ADD CONSTRAINT recipe_cellar_steps_tag_id_fkey FOREIGN KEY (tag_id) REFERENCES public.cellar_action_tags(id);


--
-- Name: recipe_cellar_steps recipe_cellar_steps_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_cellar_steps
    ADD CONSTRAINT recipe_cellar_steps_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(id);


--
-- Name: recipe_comments recipe_comments_recipe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_comments
    ADD CONSTRAINT recipe_comments_recipe_id_fkey FOREIGN KEY (recipe_id) REFERENCES public.recipes(id) ON DELETE CASCADE;


--
-- Name: recipe_costs recipe_costs_recipe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_costs
    ADD CONSTRAINT recipe_costs_recipe_id_fkey FOREIGN KEY (recipe_id) REFERENCES public.recipes(id) ON DELETE CASCADE;


--
-- Name: recipe_fermentation recipe_fermentation_recipe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_fermentation
    ADD CONSTRAINT recipe_fermentation_recipe_id_fkey FOREIGN KEY (recipe_id) REFERENCES public.recipes(id) ON DELETE CASCADE;


--
-- Name: recipe_ingredients recipe_ingredients_ingredient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_ingredients
    ADD CONSTRAINT recipe_ingredients_ingredient_id_fkey FOREIGN KEY (ingredient_id) REFERENCES public.ingredients(id);


--
-- Name: recipe_ingredients recipe_ingredients_recipe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_ingredients
    ADD CONSTRAINT recipe_ingredients_recipe_id_fkey FOREIGN KEY (recipe_id) REFERENCES public.recipes(id) ON DELETE CASCADE;


--
-- Name: recipe_packaging recipe_packaging_recipe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_packaging
    ADD CONSTRAINT recipe_packaging_recipe_id_fkey FOREIGN KEY (recipe_id) REFERENCES public.recipes(id) ON DELETE CASCADE;


--
-- Name: recipe_process_steps recipe_process_steps_recipe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_process_steps
    ADD CONSTRAINT recipe_process_steps_recipe_id_fkey FOREIGN KEY (recipe_id) REFERENCES public.recipes(id) ON DELETE CASCADE;


--
-- Name: recipe_revisions recipe_revisions_recipe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_revisions
    ADD CONSTRAINT recipe_revisions_recipe_id_fkey FOREIGN KEY (recipe_id) REFERENCES public.recipes(id) ON DELETE CASCADE;


--
-- Name: recipe_revisions recipe_revisions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_revisions
    ADD CONSTRAINT recipe_revisions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: recipe_specs recipe_specs_recipe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_specs
    ADD CONSTRAINT recipe_specs_recipe_id_fkey FOREIGN KEY (recipe_id) REFERENCES public.recipes(id) ON DELETE CASCADE;


--
-- Name: recipe_water recipe_water_recipe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_water
    ADD CONSTRAINT recipe_water_recipe_id_fkey FOREIGN KEY (recipe_id) REFERENCES public.recipes(id) ON DELETE CASCADE;


--
-- Name: recipes recipes_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipes
    ADD CONSTRAINT recipes_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: recipes recipes_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipes
    ADD CONSTRAINT recipes_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(id);


--
-- Name: role_permissions role_permissions_module_key_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_permissions
    ADD CONSTRAINT role_permissions_module_key_fkey FOREIGN KEY (module_key) REFERENCES public.permission_modules(module_key) ON DELETE CASCADE;


--
-- Name: role_permissions role_permissions_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.role_permissions
    ADD CONSTRAINT role_permissions_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.roles(id) ON DELETE CASCADE;


--
-- Name: stock_movements stock_movements_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_movements
    ADD CONSTRAINT stock_movements_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES public.batches(id);


--
-- Name: stock_movements stock_movements_booked_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_movements
    ADD CONSTRAINT stock_movements_booked_by_fkey FOREIGN KEY (booked_by) REFERENCES public.users(id);


--
-- Name: stock_movements stock_movements_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_movements
    ADD CONSTRAINT stock_movements_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: stock_movements stock_movements_lot_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_movements
    ADD CONSTRAINT stock_movements_lot_id_fkey FOREIGN KEY (lot_id) REFERENCES public.lots(id);


--
-- Name: stock_movements stock_movements_recipe_ingredient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_movements
    ADD CONSTRAINT stock_movements_recipe_ingredient_id_fkey FOREIGN KEY (recipe_ingredient_id) REFERENCES public.recipe_ingredients(id);


--
-- Name: tanks tanks_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tanks
    ADD CONSTRAINT tanks_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(id);


--
-- Name: tanks tanks_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tanks
    ADD CONSTRAINT tanks_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(id);


--
-- Name: users users_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: users users_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.roles(id);


--
-- Name: water_settings_history water_settings_history_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.water_settings_history
    ADD CONSTRAINT water_settings_history_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(id);


--
-- Name: water_settings water_settings_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.water_settings
    ADD CONSTRAINT water_settings_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES public.users(id);


--
-- Name: batch_audit_log; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.batch_audit_log ENABLE ROW LEVEL SECURITY;

--
-- Name: batch_audit_log batch_audit_log_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY batch_audit_log_select ON public.batch_audit_log FOR SELECT TO authenticated USING (public.can_view('batches'::text));


--
-- Name: batch_brew_comments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.batch_brew_comments ENABLE ROW LEVEL SECURITY;

--
-- Name: batch_brew_comments batch_brew_comments_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY batch_brew_comments_delete ON public.batch_brew_comments FOR DELETE TO authenticated USING (public.can_delete('batches'::text));


--
-- Name: batch_brew_comments batch_brew_comments_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY batch_brew_comments_insert ON public.batch_brew_comments FOR INSERT TO authenticated WITH CHECK (public.can_edit('batches'::text));


--
-- Name: batch_brew_comments batch_brew_comments_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY batch_brew_comments_select ON public.batch_brew_comments FOR SELECT TO authenticated USING (public.can_view('batches'::text));


--
-- Name: batch_brew_comments batch_brew_comments_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY batch_brew_comments_update ON public.batch_brew_comments FOR UPDATE TO authenticated USING (public.can_edit('batches'::text)) WITH CHECK (public.can_edit('batches'::text));


--
-- Name: batch_brews; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.batch_brews ENABLE ROW LEVEL SECURITY;

--
-- Name: batch_brews batch_brews_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY batch_brews_delete ON public.batch_brews FOR DELETE TO authenticated USING (public.can_delete('batches'::text));


--
-- Name: batch_brews batch_brews_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY batch_brews_insert ON public.batch_brews FOR INSERT TO authenticated WITH CHECK (public.can_edit('batches'::text));


--
-- Name: batch_brews batch_brews_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY batch_brews_select ON public.batch_brews FOR SELECT TO authenticated USING (public.can_view('batches'::text));


--
-- Name: batch_brews batch_brews_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY batch_brews_update ON public.batch_brews FOR UPDATE TO authenticated USING (public.can_edit('batches'::text)) WITH CHECK (public.can_edit('batches'::text));


--
-- Name: batch_cellar_steps; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.batch_cellar_steps ENABLE ROW LEVEL SECURITY;

--
-- Name: batch_cellar_steps batch_cellar_steps_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY batch_cellar_steps_delete ON public.batch_cellar_steps FOR DELETE TO authenticated USING (public.can_delete('batches'::text));


--
-- Name: batch_cellar_steps batch_cellar_steps_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY batch_cellar_steps_insert ON public.batch_cellar_steps FOR INSERT TO authenticated WITH CHECK (public.can_edit('batches'::text));


--
-- Name: batch_cellar_steps batch_cellar_steps_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY batch_cellar_steps_select ON public.batch_cellar_steps FOR SELECT TO authenticated USING (public.can_view('batches'::text));


--
-- Name: batch_cellar_steps batch_cellar_steps_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY batch_cellar_steps_update ON public.batch_cellar_steps FOR UPDATE TO authenticated USING (public.can_edit('batches'::text)) WITH CHECK (public.can_edit('batches'::text));


--
-- Name: batch_documents; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.batch_documents ENABLE ROW LEVEL SECURITY;

--
-- Name: batch_documents batch_documents_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY batch_documents_delete ON public.batch_documents FOR DELETE TO authenticated USING (public.can_delete('batches'::text));


--
-- Name: batch_documents batch_documents_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY batch_documents_insert ON public.batch_documents FOR INSERT TO authenticated WITH CHECK (public.can_edit('batches'::text));


--
-- Name: batch_documents batch_documents_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY batch_documents_select ON public.batch_documents FOR SELECT TO authenticated USING (public.can_view('batches'::text));


--
-- Name: batch_documents batch_documents_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY batch_documents_update ON public.batch_documents FOR UPDATE TO authenticated USING (public.can_edit('batches'::text)) WITH CHECK (public.can_edit('batches'::text));


--
-- Name: batch_hbts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.batch_hbts ENABLE ROW LEVEL SECURITY;

--
-- Name: batch_hbts batch_hbts_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY batch_hbts_delete ON public.batch_hbts FOR DELETE TO authenticated USING (public.can_delete('batches'::text));


--
-- Name: batch_hbts batch_hbts_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY batch_hbts_insert ON public.batch_hbts FOR INSERT TO authenticated WITH CHECK (public.can_edit('batches'::text));


--
-- Name: batch_hbts batch_hbts_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY batch_hbts_select ON public.batch_hbts FOR SELECT TO authenticated USING (public.can_view('batches'::text));


--
-- Name: batch_hbts batch_hbts_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY batch_hbts_update ON public.batch_hbts FOR UPDATE TO authenticated USING (public.can_edit('batches'::text)) WITH CHECK (public.can_edit('batches'::text));


--
-- Name: batch_ingredients; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.batch_ingredients ENABLE ROW LEVEL SECURITY;

--
-- Name: batch_ingredients batch_ingredients_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY batch_ingredients_delete ON public.batch_ingredients FOR DELETE TO authenticated USING (public.can_delete('batches'::text));


--
-- Name: batch_ingredients batch_ingredients_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY batch_ingredients_insert ON public.batch_ingredients FOR INSERT TO authenticated WITH CHECK (public.can_edit('batches'::text));


--
-- Name: batch_ingredients batch_ingredients_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY batch_ingredients_select ON public.batch_ingredients FOR SELECT TO authenticated USING (public.can_view('batches'::text));


--
-- Name: batch_ingredients batch_ingredients_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY batch_ingredients_update ON public.batch_ingredients FOR UPDATE TO authenticated USING (public.can_edit('batches'::text)) WITH CHECK (public.can_edit('batches'::text));


--
-- Name: batch_transfers; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.batch_transfers ENABLE ROW LEVEL SECURITY;

--
-- Name: batch_transfers batch_transfers_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY batch_transfers_delete ON public.batch_transfers FOR DELETE TO authenticated USING (public.can_delete('batches'::text));


--
-- Name: batch_transfers batch_transfers_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY batch_transfers_insert ON public.batch_transfers FOR INSERT TO authenticated WITH CHECK (public.can_edit('batches'::text));


--
-- Name: batch_transfers batch_transfers_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY batch_transfers_select ON public.batch_transfers FOR SELECT TO authenticated USING (public.can_view('batches'::text));


--
-- Name: batch_transfers batch_transfers_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY batch_transfers_update ON public.batch_transfers FOR UPDATE TO authenticated USING (public.can_edit('batches'::text)) WITH CHECK (public.can_edit('batches'::text));


--
-- Name: batches; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.batches ENABLE ROW LEVEL SECURITY;

--
-- Name: batches batches_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY batches_delete ON public.batches FOR DELETE USING (public.can_delete('batches'::text));


--
-- Name: batches batches_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY batches_insert ON public.batches FOR INSERT WITH CHECK (public.can_edit('batches'::text));


--
-- Name: batches batches_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY batches_select ON public.batches FOR SELECT USING (public.can_view('batches'::text));


--
-- Name: batches batches_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY batches_update ON public.batches FOR UPDATE USING (public.can_edit('batches'::text)) WITH CHECK (public.can_edit('batches'::text));


--
-- Name: brew_capacity; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.brew_capacity ENABLE ROW LEVEL SECURITY;

--
-- Name: brew_capacity brew_capacity_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brew_capacity_delete ON public.brew_capacity FOR DELETE USING (public.can_delete('brewing_planning'::text));


--
-- Name: brew_capacity brew_capacity_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brew_capacity_insert ON public.brew_capacity FOR INSERT WITH CHECK (public.can_edit('brewing_planning'::text));


--
-- Name: brew_capacity brew_capacity_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brew_capacity_select ON public.brew_capacity FOR SELECT USING (public.can_view('brewing_planning'::text));


--
-- Name: brew_capacity brew_capacity_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brew_capacity_update ON public.brew_capacity FOR UPDATE USING (public.can_edit('brewing_planning'::text)) WITH CHECK (public.can_edit('brewing_planning'::text));


--
-- Name: brew_planning; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.brew_planning ENABLE ROW LEVEL SECURITY;

--
-- Name: brew_planning brew_planning_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brew_planning_delete ON public.brew_planning FOR DELETE USING (public.can_delete('brewing_planning'::text));


--
-- Name: brew_planning_history; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.brew_planning_history ENABLE ROW LEVEL SECURITY;

--
-- Name: brew_planning_history brew_planning_history_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brew_planning_history_select ON public.brew_planning_history FOR SELECT USING (public.can_view('brewing_planning'::text));


--
-- Name: brew_planning brew_planning_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brew_planning_insert ON public.brew_planning FOR INSERT WITH CHECK (public.can_edit('brewing_planning'::text));


--
-- Name: brew_planning brew_planning_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brew_planning_select ON public.brew_planning FOR SELECT USING (public.can_view('brewing_planning'::text));


--
-- Name: brew_planning_splits; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.brew_planning_splits ENABLE ROW LEVEL SECURITY;

--
-- Name: brew_planning_splits brew_planning_splits_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brew_planning_splits_delete ON public.brew_planning_splits FOR DELETE USING (public.can_edit('brewing_planning'::text));


--
-- Name: brew_planning_splits brew_planning_splits_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brew_planning_splits_insert ON public.brew_planning_splits FOR INSERT WITH CHECK (public.can_edit('brewing_planning'::text));


--
-- Name: brew_planning_splits brew_planning_splits_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brew_planning_splits_select ON public.brew_planning_splits FOR SELECT USING (public.can_view('brewing_planning'::text));


--
-- Name: brew_planning_splits brew_planning_splits_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brew_planning_splits_update ON public.brew_planning_splits FOR UPDATE USING (public.can_edit('brewing_planning'::text)) WITH CHECK (public.can_edit('brewing_planning'::text));


--
-- Name: brew_planning brew_planning_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY brew_planning_update ON public.brew_planning FOR UPDATE USING (public.can_edit('brewing_planning'::text)) WITH CHECK (public.can_edit('brewing_planning'::text));


--
-- Name: cellar_action_tags; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.cellar_action_tags ENABLE ROW LEVEL SECURITY;

--
-- Name: cellar_action_tags cellar_action_tags_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY cellar_action_tags_delete ON public.cellar_action_tags FOR DELETE TO authenticated USING (public.can_delete('settings'::text));


--
-- Name: cellar_action_tags cellar_action_tags_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY cellar_action_tags_insert ON public.cellar_action_tags FOR INSERT TO authenticated WITH CHECK (public.can_edit('settings'::text));


--
-- Name: cellar_action_tags cellar_action_tags_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY cellar_action_tags_select ON public.cellar_action_tags FOR SELECT TO authenticated USING (true);


--
-- Name: cellar_action_tags cellar_action_tags_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY cellar_action_tags_update ON public.cellar_action_tags FOR UPDATE TO authenticated USING (public.can_edit('settings'::text)) WITH CHECK (public.can_edit('settings'::text));


--
-- Name: cellar_plan_parts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.cellar_plan_parts ENABLE ROW LEVEL SECURITY;

--
-- Name: cellar_plan_parts cellar_plan_parts_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY cellar_plan_parts_delete ON public.cellar_plan_parts FOR DELETE TO authenticated USING ((public.can_delete('settings'::text) AND (kind = 'addition_timing'::text)));


--
-- Name: cellar_plan_parts cellar_plan_parts_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY cellar_plan_parts_insert ON public.cellar_plan_parts FOR INSERT TO authenticated WITH CHECK ((public.can_edit('settings'::text) AND (kind = 'addition_timing'::text)));


--
-- Name: cellar_plan_parts cellar_plan_parts_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY cellar_plan_parts_select ON public.cellar_plan_parts FOR SELECT TO authenticated USING (true);


--
-- Name: cellar_plan_parts cellar_plan_parts_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY cellar_plan_parts_update ON public.cellar_plan_parts FOR UPDATE TO authenticated USING (public.can_edit('settings'::text)) WITH CHECK (public.can_edit('settings'::text));


--
-- Name: document_types; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.document_types ENABLE ROW LEVEL SECURITY;

--
-- Name: document_types document_types_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY document_types_delete ON public.document_types FOR DELETE USING (public.can_delete('settings'::text));


--
-- Name: document_types document_types_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY document_types_insert ON public.document_types FOR INSERT WITH CHECK (public.can_edit('settings'::text));


--
-- Name: document_types document_types_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY document_types_select ON public.document_types FOR SELECT USING (true);


--
-- Name: document_types document_types_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY document_types_update ON public.document_types FOR UPDATE USING (public.can_edit('settings'::text)) WITH CHECK (public.can_edit('settings'::text));


--
-- Name: fermentation_log_entries; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.fermentation_log_entries ENABLE ROW LEVEL SECURITY;

--
-- Name: fermentation_log_entries fermentation_log_entries_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY fermentation_log_entries_delete ON public.fermentation_log_entries FOR DELETE TO authenticated USING (public.can_delete('batches'::text));


--
-- Name: fermentation_log_entries fermentation_log_entries_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY fermentation_log_entries_insert ON public.fermentation_log_entries FOR INSERT TO authenticated WITH CHECK (public.can_edit('batches'::text));


--
-- Name: fermentation_log_entries fermentation_log_entries_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY fermentation_log_entries_select ON public.fermentation_log_entries FOR SELECT TO authenticated USING (public.can_view('batches'::text));


--
-- Name: fermentation_log_entries fermentation_log_entries_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY fermentation_log_entries_update ON public.fermentation_log_entries FOR UPDATE TO authenticated USING (public.can_edit('batches'::text)) WITH CHECK (public.can_edit('batches'::text));


--
-- Name: fermentation_log_entry_tags; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.fermentation_log_entry_tags ENABLE ROW LEVEL SECURITY;

--
-- Name: fermentation_log_entry_tags fermentation_log_entry_tags_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY fermentation_log_entry_tags_delete ON public.fermentation_log_entry_tags FOR DELETE TO authenticated USING (public.can_delete('batches'::text));


--
-- Name: fermentation_log_entry_tags fermentation_log_entry_tags_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY fermentation_log_entry_tags_insert ON public.fermentation_log_entry_tags FOR INSERT TO authenticated WITH CHECK (public.can_edit('batches'::text));


--
-- Name: fermentation_log_entry_tags fermentation_log_entry_tags_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY fermentation_log_entry_tags_select ON public.fermentation_log_entry_tags FOR SELECT TO authenticated USING (public.can_view('batches'::text));


--
-- Name: fermentation_log_entry_tags fermentation_log_entry_tags_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY fermentation_log_entry_tags_update ON public.fermentation_log_entry_tags FOR UPDATE TO authenticated USING (public.can_edit('batches'::text)) WITH CHECK (public.can_edit('batches'::text));


--
-- Name: filling_measurements; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.filling_measurements ENABLE ROW LEVEL SECURITY;

--
-- Name: filling_measurements filling_measurements_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY filling_measurements_delete ON public.filling_measurements FOR DELETE TO authenticated USING (public.can_delete('batches'::text));


--
-- Name: filling_measurements filling_measurements_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY filling_measurements_insert ON public.filling_measurements FOR INSERT TO authenticated WITH CHECK (public.can_edit('batches'::text));


--
-- Name: filling_measurements filling_measurements_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY filling_measurements_select ON public.filling_measurements FOR SELECT TO authenticated USING (public.can_view('batches'::text));


--
-- Name: filling_measurements filling_measurements_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY filling_measurements_update ON public.filling_measurements FOR UPDATE TO authenticated USING (public.can_edit('batches'::text)) WITH CHECK (public.can_edit('batches'::text));


--
-- Name: filling_session_articles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.filling_session_articles ENABLE ROW LEVEL SECURITY;

--
-- Name: filling_session_articles filling_session_articles_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY filling_session_articles_delete ON public.filling_session_articles FOR DELETE TO authenticated USING (public.can_delete('batches'::text));


--
-- Name: filling_session_articles filling_session_articles_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY filling_session_articles_insert ON public.filling_session_articles FOR INSERT TO authenticated WITH CHECK (public.can_edit('batches'::text));


--
-- Name: filling_session_articles filling_session_articles_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY filling_session_articles_select ON public.filling_session_articles FOR SELECT TO authenticated USING (public.can_view('batches'::text));


--
-- Name: filling_session_articles filling_session_articles_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY filling_session_articles_update ON public.filling_session_articles FOR UPDATE TO authenticated USING (public.can_edit('batches'::text)) WITH CHECK (public.can_edit('batches'::text));


--
-- Name: filling_session_materials; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.filling_session_materials ENABLE ROW LEVEL SECURITY;

--
-- Name: filling_session_materials filling_session_materials_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY filling_session_materials_delete ON public.filling_session_materials FOR DELETE TO authenticated USING (public.can_delete('batches'::text));


--
-- Name: filling_session_materials filling_session_materials_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY filling_session_materials_insert ON public.filling_session_materials FOR INSERT TO authenticated WITH CHECK (public.can_edit('batches'::text));


--
-- Name: filling_session_materials filling_session_materials_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY filling_session_materials_select ON public.filling_session_materials FOR SELECT TO authenticated USING (public.can_view('batches'::text));


--
-- Name: filling_session_materials filling_session_materials_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY filling_session_materials_update ON public.filling_session_materials FOR UPDATE TO authenticated USING (public.can_edit('batches'::text)) WITH CHECK (public.can_edit('batches'::text));


--
-- Name: filling_sessions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.filling_sessions ENABLE ROW LEVEL SECURITY;

--
-- Name: filling_sessions filling_sessions_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY filling_sessions_delete ON public.filling_sessions FOR DELETE TO authenticated USING (public.can_delete('batches'::text));


--
-- Name: filling_sessions filling_sessions_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY filling_sessions_insert ON public.filling_sessions FOR INSERT TO authenticated WITH CHECK (public.can_edit('batches'::text));


--
-- Name: filling_sessions filling_sessions_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY filling_sessions_select ON public.filling_sessions FOR SELECT TO authenticated USING (public.can_view('batches'::text));


--
-- Name: filling_sessions filling_sessions_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY filling_sessions_update ON public.filling_sessions FOR UPDATE TO authenticated USING (public.can_edit('batches'::text)) WITH CHECK (public.can_edit('batches'::text));


--
-- Name: hbt_readings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.hbt_readings ENABLE ROW LEVEL SECURITY;

--
-- Name: hbt_readings hbt_readings_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY hbt_readings_delete ON public.hbt_readings FOR DELETE TO authenticated USING (public.can_delete('batches'::text));


--
-- Name: hbt_readings hbt_readings_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY hbt_readings_insert ON public.hbt_readings FOR INSERT TO authenticated WITH CHECK (public.can_edit('batches'::text));


--
-- Name: hbt_readings hbt_readings_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY hbt_readings_select ON public.hbt_readings FOR SELECT TO authenticated USING (public.can_view('batches'::text));


--
-- Name: hbt_readings hbt_readings_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY hbt_readings_update ON public.hbt_readings FOR UPDATE TO authenticated USING (public.can_edit('batches'::text)) WITH CHECK (public.can_edit('batches'::text));


--
-- Name: ingredient_categories; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ingredient_categories ENABLE ROW LEVEL SECURITY;

--
-- Name: ingredient_categories ingredient_categories_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredient_categories_delete ON public.ingredient_categories FOR DELETE USING (public.can_delete('settings'::text));


--
-- Name: ingredient_categories ingredient_categories_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredient_categories_insert ON public.ingredient_categories FOR INSERT WITH CHECK (public.can_edit('settings'::text));


--
-- Name: ingredient_categories ingredient_categories_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredient_categories_select ON public.ingredient_categories FOR SELECT USING (true);


--
-- Name: ingredient_categories ingredient_categories_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredient_categories_update ON public.ingredient_categories FOR UPDATE USING (public.can_edit('settings'::text)) WITH CHECK (public.can_edit('settings'::text));


--
-- Name: ingredient_declarations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ingredient_declarations ENABLE ROW LEVEL SECURITY;

--
-- Name: ingredient_declarations ingredient_declarations_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredient_declarations_delete ON public.ingredient_declarations FOR DELETE USING (public.can_delete('settings'::text));


--
-- Name: ingredient_declarations ingredient_declarations_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredient_declarations_insert ON public.ingredient_declarations FOR INSERT WITH CHECK (public.can_edit('settings'::text));


--
-- Name: ingredient_declarations ingredient_declarations_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredient_declarations_select ON public.ingredient_declarations FOR SELECT USING (true);


--
-- Name: ingredient_declarations ingredient_declarations_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredient_declarations_update ON public.ingredient_declarations FOR UPDATE USING (public.can_edit('settings'::text)) WITH CHECK (public.can_edit('settings'::text));


--
-- Name: ingredient_documents; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ingredient_documents ENABLE ROW LEVEL SECURITY;

--
-- Name: ingredient_documents ingredient_documents_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredient_documents_delete ON public.ingredient_documents FOR DELETE USING (public.can_delete('ingredients'::text));


--
-- Name: ingredient_documents ingredient_documents_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredient_documents_insert ON public.ingredient_documents FOR INSERT WITH CHECK (public.can_edit('ingredients'::text));


--
-- Name: ingredient_documents ingredient_documents_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredient_documents_select ON public.ingredient_documents FOR SELECT USING (public.can_view('ingredients'::text));


--
-- Name: ingredient_documents ingredient_documents_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredient_documents_update ON public.ingredient_documents FOR UPDATE USING (public.can_edit('ingredients'::text)) WITH CHECK (public.can_edit('ingredients'::text));


--
-- Name: ingredient_revisions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ingredient_revisions ENABLE ROW LEVEL SECURITY;

--
-- Name: ingredient_revisions ingredient_revisions_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredient_revisions_insert ON public.ingredient_revisions FOR INSERT WITH CHECK (public.can_edit('ingredients'::text));


--
-- Name: ingredient_revisions ingredient_revisions_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredient_revisions_select ON public.ingredient_revisions FOR SELECT USING (public.can_view('ingredients'::text));


--
-- Name: ingredients; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.ingredients ENABLE ROW LEVEL SECURITY;

--
-- Name: ingredients ingredients_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredients_delete ON public.ingredients FOR DELETE USING (public.can_delete('ingredients'::text));


--
-- Name: ingredients ingredients_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredients_insert ON public.ingredients FOR INSERT WITH CHECK (public.can_edit('ingredients'::text));


--
-- Name: ingredients ingredients_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredients_select ON public.ingredients FOR SELECT USING (public.can_view('ingredients'::text));


--
-- Name: ingredients ingredients_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY ingredients_update ON public.ingredients FOR UPDATE USING (public.can_edit('ingredients'::text)) WITH CHECK (public.can_edit('ingredients'::text));


--
-- Name: lots; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.lots ENABLE ROW LEVEL SECURITY;

--
-- Name: lots lots_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY lots_delete ON public.lots FOR DELETE USING (public.can_delete('inventory'::text));


--
-- Name: lots lots_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY lots_insert ON public.lots FOR INSERT WITH CHECK (public.can_edit('inventory'::text));


--
-- Name: lots lots_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY lots_select ON public.lots FOR SELECT USING (public.can_view('inventory'::text));


--
-- Name: lots lots_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY lots_update ON public.lots FOR UPDATE USING (public.can_edit('inventory'::text)) WITH CHECK (public.can_edit('inventory'::text));


--
-- Name: packaging_article_materials; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.packaging_article_materials ENABLE ROW LEVEL SECURITY;

--
-- Name: packaging_article_materials packaging_article_materials_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY packaging_article_materials_delete ON public.packaging_article_materials FOR DELETE TO authenticated USING (public.can_delete('settings'::text));


--
-- Name: packaging_article_materials packaging_article_materials_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY packaging_article_materials_insert ON public.packaging_article_materials FOR INSERT TO authenticated WITH CHECK (public.can_edit('settings'::text));


--
-- Name: packaging_article_materials packaging_article_materials_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY packaging_article_materials_select ON public.packaging_article_materials FOR SELECT TO authenticated USING (true);


--
-- Name: packaging_article_materials packaging_article_materials_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY packaging_article_materials_update ON public.packaging_article_materials FOR UPDATE TO authenticated USING (public.can_edit('settings'::text)) WITH CHECK (public.can_edit('settings'::text));


--
-- Name: packaging_articles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.packaging_articles ENABLE ROW LEVEL SECURITY;

--
-- Name: packaging_articles packaging_articles_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY packaging_articles_delete ON public.packaging_articles FOR DELETE TO authenticated USING (public.can_delete('settings'::text));


--
-- Name: packaging_articles packaging_articles_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY packaging_articles_insert ON public.packaging_articles FOR INSERT TO authenticated WITH CHECK (public.can_edit('settings'::text));


--
-- Name: packaging_articles packaging_articles_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY packaging_articles_select ON public.packaging_articles FOR SELECT TO authenticated USING (true);


--
-- Name: packaging_articles packaging_articles_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY packaging_articles_update ON public.packaging_articles FOR UPDATE TO authenticated USING (public.can_edit('settings'::text)) WITH CHECK (public.can_edit('settings'::text));


--
-- Name: packaging_materials; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.packaging_materials ENABLE ROW LEVEL SECURITY;

--
-- Name: packaging_materials packaging_materials_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY packaging_materials_delete ON public.packaging_materials FOR DELETE TO authenticated USING (public.can_delete('settings'::text));


--
-- Name: packaging_materials packaging_materials_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY packaging_materials_insert ON public.packaging_materials FOR INSERT TO authenticated WITH CHECK (public.can_edit('settings'::text));


--
-- Name: packaging_materials packaging_materials_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY packaging_materials_select ON public.packaging_materials FOR SELECT TO authenticated USING (true);


--
-- Name: packaging_materials packaging_materials_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY packaging_materials_update ON public.packaging_materials FOR UPDATE TO authenticated USING (public.can_edit('settings'::text)) WITH CHECK (public.can_edit('settings'::text));


--
-- Name: permission_modules; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.permission_modules ENABLE ROW LEVEL SECURITY;

--
-- Name: permission_modules permission_modules_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY permission_modules_select ON public.permission_modules FOR SELECT USING (true);


--
-- Name: processing_comments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.processing_comments ENABLE ROW LEVEL SECURITY;

--
-- Name: processing_comments processing_comments_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY processing_comments_delete ON public.processing_comments FOR DELETE TO authenticated USING (public.can_delete('batches'::text));


--
-- Name: processing_comments processing_comments_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY processing_comments_insert ON public.processing_comments FOR INSERT TO authenticated WITH CHECK (public.can_edit('batches'::text));


--
-- Name: processing_comments processing_comments_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY processing_comments_select ON public.processing_comments FOR SELECT TO authenticated USING (public.can_view('batches'::text));


--
-- Name: processing_comments processing_comments_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY processing_comments_update ON public.processing_comments FOR UPDATE TO authenticated USING (public.can_edit('batches'::text)) WITH CHECK (public.can_edit('batches'::text));


--
-- Name: processing_sessions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.processing_sessions ENABLE ROW LEVEL SECURITY;

--
-- Name: processing_sessions processing_sessions_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY processing_sessions_delete ON public.processing_sessions FOR DELETE TO authenticated USING (public.can_delete('batches'::text));


--
-- Name: processing_sessions processing_sessions_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY processing_sessions_insert ON public.processing_sessions FOR INSERT TO authenticated WITH CHECK (public.can_edit('batches'::text));


--
-- Name: processing_sessions processing_sessions_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY processing_sessions_select ON public.processing_sessions FOR SELECT TO authenticated USING (public.can_view('batches'::text));


--
-- Name: processing_sessions processing_sessions_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY processing_sessions_update ON public.processing_sessions FOR UPDATE TO authenticated USING (public.can_edit('batches'::text)) WITH CHECK (public.can_edit('batches'::text));


--
-- Name: product_sheet_revisions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.product_sheet_revisions ENABLE ROW LEVEL SECURITY;

--
-- Name: product_sheet_revisions product_sheet_revisions_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY product_sheet_revisions_insert ON public.product_sheet_revisions FOR INSERT WITH CHECK (public.can_edit('product_sheets'::text));


--
-- Name: product_sheet_revisions product_sheet_revisions_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY product_sheet_revisions_select ON public.product_sheet_revisions FOR SELECT USING (public.can_view('product_sheets'::text));


--
-- Name: product_sheets; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.product_sheets ENABLE ROW LEVEL SECURITY;

--
-- Name: product_sheets product_sheets_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY product_sheets_delete ON public.product_sheets FOR DELETE USING (public.can_delete('product_sheets'::text));


--
-- Name: product_sheets product_sheets_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY product_sheets_insert ON public.product_sheets FOR INSERT WITH CHECK (public.can_edit('product_sheets'::text));


--
-- Name: product_sheets product_sheets_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY product_sheets_select ON public.product_sheets FOR SELECT USING (public.can_view('product_sheets'::text));


--
-- Name: product_sheets product_sheets_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY product_sheets_update ON public.product_sheets FOR UPDATE USING (public.can_edit('product_sheets'::text));


--
-- Name: recipe_brewing_specs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recipe_brewing_specs ENABLE ROW LEVEL SECURITY;

--
-- Name: recipe_brewing_specs recipe_brewing_specs_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_brewing_specs_delete ON public.recipe_brewing_specs FOR DELETE USING (public.can_delete('recipes'::text));


--
-- Name: recipe_brewing_specs recipe_brewing_specs_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_brewing_specs_insert ON public.recipe_brewing_specs FOR INSERT WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_brewing_specs recipe_brewing_specs_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_brewing_specs_select ON public.recipe_brewing_specs FOR SELECT USING (public.can_view('recipes'::text));


--
-- Name: recipe_brewing_specs recipe_brewing_specs_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_brewing_specs_update ON public.recipe_brewing_specs FOR UPDATE USING (public.can_edit('recipes'::text)) WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_cellar_steps; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recipe_cellar_steps ENABLE ROW LEVEL SECURITY;

--
-- Name: recipe_cellar_steps recipe_cellar_steps_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_cellar_steps_delete ON public.recipe_cellar_steps FOR DELETE TO authenticated USING (public.can_edit('recipes'::text));


--
-- Name: recipe_cellar_steps recipe_cellar_steps_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_cellar_steps_insert ON public.recipe_cellar_steps FOR INSERT TO authenticated WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_cellar_steps recipe_cellar_steps_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_cellar_steps_select ON public.recipe_cellar_steps FOR SELECT TO authenticated USING (public.can_view('recipes'::text));


--
-- Name: recipe_cellar_steps recipe_cellar_steps_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_cellar_steps_update ON public.recipe_cellar_steps FOR UPDATE TO authenticated USING (public.can_edit('recipes'::text)) WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_comments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recipe_comments ENABLE ROW LEVEL SECURITY;

--
-- Name: recipe_comments recipe_comments_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_comments_delete ON public.recipe_comments FOR DELETE USING (public.can_delete('recipes'::text));


--
-- Name: recipe_comments recipe_comments_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_comments_insert ON public.recipe_comments FOR INSERT WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_comments recipe_comments_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_comments_select ON public.recipe_comments FOR SELECT USING (public.can_view('recipes'::text));


--
-- Name: recipe_comments recipe_comments_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_comments_update ON public.recipe_comments FOR UPDATE USING (public.can_edit('recipes'::text)) WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_costs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recipe_costs ENABLE ROW LEVEL SECURITY;

--
-- Name: recipe_costs recipe_costs_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_costs_delete ON public.recipe_costs FOR DELETE USING (public.can_delete('recipes'::text));


--
-- Name: recipe_costs recipe_costs_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_costs_insert ON public.recipe_costs FOR INSERT WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_costs recipe_costs_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_costs_select ON public.recipe_costs FOR SELECT USING (public.can_view('recipes'::text));


--
-- Name: recipe_costs recipe_costs_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_costs_update ON public.recipe_costs FOR UPDATE USING (public.can_edit('recipes'::text)) WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_fermentation; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recipe_fermentation ENABLE ROW LEVEL SECURITY;

--
-- Name: recipe_fermentation recipe_fermentation_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_fermentation_delete ON public.recipe_fermentation FOR DELETE USING (public.can_delete('recipes'::text));


--
-- Name: recipe_fermentation recipe_fermentation_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_fermentation_insert ON public.recipe_fermentation FOR INSERT WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_fermentation recipe_fermentation_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_fermentation_select ON public.recipe_fermentation FOR SELECT USING (public.can_view('recipes'::text));


--
-- Name: recipe_fermentation recipe_fermentation_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_fermentation_update ON public.recipe_fermentation FOR UPDATE USING (public.can_edit('recipes'::text)) WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_ingredients; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recipe_ingredients ENABLE ROW LEVEL SECURITY;

--
-- Name: recipe_ingredients recipe_ingredients_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_ingredients_delete ON public.recipe_ingredients FOR DELETE USING (public.can_edit('recipes'::text));


--
-- Name: recipe_ingredients recipe_ingredients_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_ingredients_insert ON public.recipe_ingredients FOR INSERT WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_ingredients recipe_ingredients_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_ingredients_select ON public.recipe_ingredients FOR SELECT USING (public.can_view('recipes'::text));


--
-- Name: recipe_ingredients recipe_ingredients_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_ingredients_update ON public.recipe_ingredients FOR UPDATE USING (public.can_edit('recipes'::text)) WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_packaging; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recipe_packaging ENABLE ROW LEVEL SECURITY;

--
-- Name: recipe_packaging recipe_packaging_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_packaging_delete ON public.recipe_packaging FOR DELETE USING (public.can_delete('recipes'::text));


--
-- Name: recipe_packaging recipe_packaging_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_packaging_insert ON public.recipe_packaging FOR INSERT WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_packaging recipe_packaging_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_packaging_select ON public.recipe_packaging FOR SELECT USING (public.can_view('recipes'::text));


--
-- Name: recipe_packaging recipe_packaging_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_packaging_update ON public.recipe_packaging FOR UPDATE USING (public.can_edit('recipes'::text)) WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_process_steps; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recipe_process_steps ENABLE ROW LEVEL SECURITY;

--
-- Name: recipe_process_steps recipe_process_steps_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_process_steps_delete ON public.recipe_process_steps FOR DELETE USING (public.can_delete('recipes'::text));


--
-- Name: recipe_process_steps recipe_process_steps_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_process_steps_insert ON public.recipe_process_steps FOR INSERT WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_process_steps recipe_process_steps_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_process_steps_select ON public.recipe_process_steps FOR SELECT USING (public.can_view('recipes'::text));


--
-- Name: recipe_process_steps recipe_process_steps_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_process_steps_update ON public.recipe_process_steps FOR UPDATE USING (public.can_edit('recipes'::text)) WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_revisions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recipe_revisions ENABLE ROW LEVEL SECURITY;

--
-- Name: recipe_revisions recipe_revisions_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_revisions_delete ON public.recipe_revisions FOR DELETE USING (public.can_delete('recipes'::text));


--
-- Name: recipe_revisions recipe_revisions_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_revisions_insert ON public.recipe_revisions FOR INSERT WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_revisions recipe_revisions_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_revisions_select ON public.recipe_revisions FOR SELECT USING (public.can_view('recipes'::text));


--
-- Name: recipe_revisions recipe_revisions_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_revisions_update ON public.recipe_revisions FOR UPDATE USING (public.can_edit('recipes'::text)) WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_specs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recipe_specs ENABLE ROW LEVEL SECURITY;

--
-- Name: recipe_specs recipe_specs_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_specs_delete ON public.recipe_specs FOR DELETE USING (public.can_delete('recipes'::text));


--
-- Name: recipe_specs recipe_specs_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_specs_insert ON public.recipe_specs FOR INSERT WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_specs recipe_specs_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_specs_select ON public.recipe_specs FOR SELECT USING (public.can_view('recipes'::text));


--
-- Name: recipe_specs recipe_specs_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_specs_update ON public.recipe_specs FOR UPDATE USING (public.can_edit('recipes'::text)) WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_water; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recipe_water ENABLE ROW LEVEL SECURITY;

--
-- Name: recipe_water recipe_water_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_water_delete ON public.recipe_water FOR DELETE USING (public.can_delete('recipes'::text));


--
-- Name: recipe_water recipe_water_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_water_insert ON public.recipe_water FOR INSERT WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipe_water recipe_water_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_water_select ON public.recipe_water FOR SELECT USING (public.can_view('recipes'::text));


--
-- Name: recipe_water recipe_water_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_water_update ON public.recipe_water FOR UPDATE USING (public.can_edit('recipes'::text)) WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recipes ENABLE ROW LEVEL SECURITY;

--
-- Name: recipes recipes_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipes_delete ON public.recipes FOR DELETE USING (public.can_delete('recipes'::text));


--
-- Name: recipes recipes_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipes_insert ON public.recipes FOR INSERT WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: recipes recipes_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipes_select ON public.recipes FOR SELECT USING (public.can_view('recipes'::text));


--
-- Name: recipes recipes_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipes_update ON public.recipes FOR UPDATE USING (public.can_edit('recipes'::text)) WITH CHECK (public.can_edit('recipes'::text));


--
-- Name: role_permissions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.role_permissions ENABLE ROW LEVEL SECURITY;

--
-- Name: role_permissions role_permissions_delete_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY role_permissions_delete_admin ON public.role_permissions FOR DELETE USING (public.is_admin());


--
-- Name: role_permissions role_permissions_insert_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY role_permissions_insert_admin ON public.role_permissions FOR INSERT WITH CHECK (public.is_admin());


--
-- Name: role_permissions role_permissions_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY role_permissions_select ON public.role_permissions FOR SELECT USING (true);


--
-- Name: role_permissions role_permissions_update_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY role_permissions_update_admin ON public.role_permissions FOR UPDATE USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: roles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.roles ENABLE ROW LEVEL SECURITY;

--
-- Name: roles roles_delete_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY roles_delete_admin ON public.roles FOR DELETE USING (public.is_admin());


--
-- Name: roles roles_insert_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY roles_insert_admin ON public.roles FOR INSERT WITH CHECK (public.is_admin());


--
-- Name: roles roles_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY roles_select ON public.roles FOR SELECT USING (true);


--
-- Name: roles roles_update_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY roles_update_admin ON public.roles FOR UPDATE USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: stock_movements; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.stock_movements ENABLE ROW LEVEL SECURITY;

--
-- Name: stock_movements stock_movements_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY stock_movements_delete ON public.stock_movements FOR DELETE USING (public.can_delete('inventory'::text));


--
-- Name: stock_movements stock_movements_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY stock_movements_insert ON public.stock_movements FOR INSERT WITH CHECK (public.can_edit('inventory'::text));


--
-- Name: stock_movements stock_movements_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY stock_movements_select ON public.stock_movements FOR SELECT USING (public.can_view('inventory'::text));


--
-- Name: stock_movements stock_movements_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY stock_movements_update ON public.stock_movements FOR UPDATE USING (public.can_edit('inventory'::text)) WITH CHECK (public.can_edit('inventory'::text));


--
-- Name: tanks; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.tanks ENABLE ROW LEVEL SECURITY;

--
-- Name: tanks tanks_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tanks_delete ON public.tanks FOR DELETE TO authenticated USING (public.can_delete('settings'::text));


--
-- Name: tanks tanks_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tanks_insert ON public.tanks FOR INSERT TO authenticated WITH CHECK (public.can_edit('settings'::text));


--
-- Name: tanks tanks_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tanks_select ON public.tanks FOR SELECT TO authenticated USING (true);


--
-- Name: tanks tanks_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY tanks_update ON public.tanks FOR UPDATE TO authenticated USING (public.can_edit('settings'::text)) WITH CHECK (public.can_edit('settings'::text));


--
-- Name: units; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.units ENABLE ROW LEVEL SECURITY;

--
-- Name: units units_delete; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY units_delete ON public.units FOR DELETE USING (public.can_delete('settings'::text));


--
-- Name: units units_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY units_insert ON public.units FOR INSERT WITH CHECK (public.can_edit('settings'::text));


--
-- Name: units units_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY units_select ON public.units FOR SELECT USING (true);


--
-- Name: units units_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY units_update ON public.units FOR UPDATE USING (public.can_edit('settings'::text)) WITH CHECK (public.can_edit('settings'::text));


--
-- Name: users; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

--
-- Name: users users_delete_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY users_delete_admin ON public.users FOR DELETE TO authenticated USING (public.is_admin());


--
-- Name: users users_insert_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY users_insert_admin ON public.users FOR INSERT TO authenticated WITH CHECK (public.is_admin());


--
-- Name: users users_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY users_select ON public.users FOR SELECT TO authenticated USING (true);


--
-- Name: users users_update_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY users_update_admin ON public.users FOR UPDATE TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());


--
-- Name: water_settings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.water_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: water_settings_history; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.water_settings_history ENABLE ROW LEVEL SECURITY;

--
-- Name: water_settings_history water_settings_history_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY water_settings_history_select ON public.water_settings_history FOR SELECT USING (true);


--
-- Name: water_settings water_settings_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY water_settings_select ON public.water_settings FOR SELECT USING (true);


--
-- Name: water_settings water_settings_update; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY water_settings_update ON public.water_settings FOR UPDATE USING (public.can_edit('settings'::text)) WITH CHECK (public.can_edit('settings'::text));


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: -
--

REVOKE USAGE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO anon;
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT USAGE ON SCHEMA public TO service_role;


--
-- Name: FUNCTION admin_get_last_logins(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.admin_get_last_logins() FROM PUBLIC;
GRANT ALL ON FUNCTION public.admin_get_last_logins() TO service_role;
GRANT ALL ON FUNCTION public.admin_get_last_logins() TO authenticated;


--
-- Name: FUNCTION apply_cellar_plan_order(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.apply_cellar_plan_order() FROM PUBLIC;
GRANT ALL ON FUNCTION public.apply_cellar_plan_order() TO service_role;
GRANT ALL ON FUNCTION public.apply_cellar_plan_order() TO authenticated;


--
-- Name: FUNCTION can_delete(p_module_key text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.can_delete(p_module_key text) TO service_role;


--
-- Name: FUNCTION can_edit(p_module_key text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.can_edit(p_module_key text) TO service_role;


--
-- Name: FUNCTION can_view(p_module_key text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.can_view(p_module_key text) TO service_role;


--
-- Name: FUNCTION current_role_id(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.current_role_id() TO service_role;


--
-- Name: FUNCTION generate_recipe_cellar_steps(p_recipe_id bigint, p_reset_order boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.generate_recipe_cellar_steps(p_recipe_id bigint, p_reset_order boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.generate_recipe_cellar_steps(p_recipe_id bigint, p_reset_order boolean) TO service_role;
GRANT ALL ON FUNCTION public.generate_recipe_cellar_steps(p_recipe_id bigint, p_reset_order boolean) TO authenticated;


--
-- Name: FUNCTION is_admin(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.is_admin() TO service_role;


--
-- Name: FUNCTION log_batch_change(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.log_batch_change() FROM PUBLIC;
GRANT ALL ON FUNCTION public.log_batch_change() TO service_role;


--
-- Name: FUNCTION log_brew_planning_change(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.log_brew_planning_change() FROM PUBLIC;
GRANT ALL ON FUNCTION public.log_brew_planning_change() TO service_role;


--
-- Name: FUNCTION product_sheet_calculated_color(p_recipe_id bigint); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.product_sheet_calculated_color(p_recipe_id bigint) TO service_role;


--
-- Name: FUNCTION product_sheet_relevant_hash(p_recipe_group_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.product_sheet_relevant_hash(p_recipe_group_id uuid) TO service_role;


--
-- Name: FUNCTION product_sheet_relevant_recipe_id(p_recipe_group_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.product_sheet_relevant_recipe_id(p_recipe_group_id uuid) TO service_role;


--
-- Name: FUNCTION save_recipe_cellar_steps(p_recipe_id bigint, p_steps jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.save_recipe_cellar_steps(p_recipe_id bigint, p_steps jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.save_recipe_cellar_steps(p_recipe_id bigint, p_steps jsonb) TO service_role;
GRANT ALL ON FUNCTION public.save_recipe_cellar_steps(p_recipe_id bigint, p_steps jsonb) TO authenticated;


--
-- Name: FUNCTION save_recipe_ingredients(p_recipe_id bigint, p_lines jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.save_recipe_ingredients(p_recipe_id bigint, p_lines jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.save_recipe_ingredients(p_recipe_id bigint, p_lines jsonb) TO service_role;
GRANT ALL ON FUNCTION public.save_recipe_ingredients(p_recipe_id bigint, p_lines jsonb) TO authenticated;


--
-- Name: FUNCTION set_last_login(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_last_login() FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_last_login() TO service_role;
GRANT ALL ON FUNCTION public.set_last_login() TO authenticated;


--
-- Name: FUNCTION set_updated_at(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.set_updated_at() TO service_role;


--
-- Name: FUNCTION snapshot_batch_cellar_steps(p_batch_id bigint); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.snapshot_batch_cellar_steps(p_batch_id bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION public.snapshot_batch_cellar_steps(p_batch_id bigint) TO service_role;
GRANT ALL ON FUNCTION public.snapshot_batch_cellar_steps(p_batch_id bigint) TO authenticated;


--
-- Name: FUNCTION snapshot_batch_ingredients(p_batch_id bigint); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.snapshot_batch_ingredients(p_batch_id bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION public.snapshot_batch_ingredients(p_batch_id bigint) TO service_role;
GRANT ALL ON FUNCTION public.snapshot_batch_ingredients(p_batch_id bigint) TO authenticated;


--
-- Name: FUNCTION snapshot_new_batch(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.snapshot_new_batch() FROM PUBLIC;
GRANT ALL ON FUNCTION public.snapshot_new_batch() TO service_role;


--
-- Name: FUNCTION split_batch(p_batch_id bigint, p_transferred_at timestamp with time zone, p_volume_hl numeric, p_from_tank_id bigint, p_destination text, p_recipe_id bigint, p_to_batch_id bigint, p_reason text, p_comment text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.split_batch(p_batch_id bigint, p_transferred_at timestamp with time zone, p_volume_hl numeric, p_from_tank_id bigint, p_destination text, p_recipe_id bigint, p_to_batch_id bigint, p_reason text, p_comment text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.split_batch(p_batch_id bigint, p_transferred_at timestamp with time zone, p_volume_hl numeric, p_from_tank_id bigint, p_destination text, p_recipe_id bigint, p_to_batch_id bigint, p_reason text, p_comment text) TO service_role;
GRANT ALL ON FUNCTION public.split_batch(p_batch_id bigint, p_transferred_at timestamp with time zone, p_volume_hl numeric, p_from_tank_id bigint, p_destination text, p_recipe_id bigint, p_to_batch_id bigint, p_reason text, p_comment text) TO authenticated;


--
-- Name: FUNCTION tolerance_value(p_text text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.tolerance_value(p_text text) TO service_role;


--
-- Name: FUNCTION water_settings_log(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.water_settings_log() FROM PUBLIC;
GRANT ALL ON FUNCTION public.water_settings_log() TO service_role;


--
-- Name: FUNCTION water_settings_stamp(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.water_settings_stamp() TO service_role;


--
-- Name: TABLE batch_audit_log; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.batch_audit_log TO authenticated;
GRANT ALL ON TABLE public.batch_audit_log TO service_role;


--
-- Name: SEQUENCE batch_audit_log_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.batch_audit_log_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.batch_audit_log_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.batch_audit_log_id_seq TO service_role;


--
-- Name: TABLE batch_brew_comments; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.batch_brew_comments TO authenticated;
GRANT ALL ON TABLE public.batch_brew_comments TO service_role;


--
-- Name: SEQUENCE batch_brew_comments_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.batch_brew_comments_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.batch_brew_comments_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.batch_brew_comments_id_seq TO service_role;


--
-- Name: TABLE batch_brews; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.batch_brews TO authenticated;
GRANT ALL ON TABLE public.batch_brews TO service_role;


--
-- Name: SEQUENCE batch_brews_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.batch_brews_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.batch_brews_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.batch_brews_id_seq TO service_role;


--
-- Name: TABLE batch_cellar_steps; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.batch_cellar_steps TO authenticated;
GRANT ALL ON TABLE public.batch_cellar_steps TO service_role;


--
-- Name: SEQUENCE batch_cellar_steps_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.batch_cellar_steps_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.batch_cellar_steps_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.batch_cellar_steps_id_seq TO service_role;


--
-- Name: TABLE batch_documents; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.batch_documents TO authenticated;
GRANT ALL ON TABLE public.batch_documents TO service_role;


--
-- Name: SEQUENCE batch_documents_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.batch_documents_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.batch_documents_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.batch_documents_id_seq TO service_role;


--
-- Name: TABLE batch_hbts; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.batch_hbts TO authenticated;
GRANT ALL ON TABLE public.batch_hbts TO service_role;


--
-- Name: SEQUENCE batch_hbts_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.batch_hbts_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.batch_hbts_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.batch_hbts_id_seq TO service_role;


--
-- Name: TABLE batch_ingredients; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.batch_ingredients TO authenticated;
GRANT ALL ON TABLE public.batch_ingredients TO service_role;


--
-- Name: SEQUENCE batch_ingredients_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.batch_ingredients_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.batch_ingredients_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.batch_ingredients_id_seq TO service_role;


--
-- Name: TABLE batch_transfers; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.batch_transfers TO authenticated;
GRANT ALL ON TABLE public.batch_transfers TO service_role;


--
-- Name: TABLE batches; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.batches TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.batches TO authenticated;
GRANT ALL ON TABLE public.batches TO service_role;


--
-- Name: TABLE fermentation_log_entries; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.fermentation_log_entries TO authenticated;
GRANT ALL ON TABLE public.fermentation_log_entries TO service_role;


--
-- Name: TABLE fermentation_log_entry_tags; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.fermentation_log_entry_tags TO authenticated;
GRANT ALL ON TABLE public.fermentation_log_entry_tags TO service_role;


--
-- Name: TABLE filling_sessions; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.filling_sessions TO authenticated;
GRANT ALL ON TABLE public.filling_sessions TO service_role;


--
-- Name: TABLE processing_sessions; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.processing_sessions TO authenticated;
GRANT ALL ON TABLE public.processing_sessions TO service_role;


--
-- Name: TABLE tanks; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.tanks TO authenticated;
GRANT ALL ON TABLE public.tanks TO service_role;


--
-- Name: TABLE batch_stages; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.batch_stages TO authenticated;
GRANT ALL ON TABLE public.batch_stages TO service_role;


--
-- Name: SEQUENCE batch_transfers_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.batch_transfers_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.batch_transfers_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.batch_transfers_id_seq TO service_role;


--
-- Name: SEQUENCE batches_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.batches_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.batches_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.batches_id_seq TO service_role;


--
-- Name: TABLE brew_capacity; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.brew_capacity TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.brew_capacity TO authenticated;
GRANT ALL ON TABLE public.brew_capacity TO service_role;


--
-- Name: TABLE brew_planning; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.brew_planning TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.brew_planning TO authenticated;
GRANT ALL ON TABLE public.brew_planning TO service_role;


--
-- Name: TABLE brew_planning_history; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.brew_planning_history TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.brew_planning_history TO authenticated;
GRANT ALL ON TABLE public.brew_planning_history TO service_role;


--
-- Name: TABLE users; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.users TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.users TO authenticated;
GRANT ALL ON TABLE public.users TO service_role;


--
-- Name: TABLE brew_planning_history_detailed; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.brew_planning_history_detailed TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.brew_planning_history_detailed TO authenticated;
GRANT ALL ON TABLE public.brew_planning_history_detailed TO service_role;


--
-- Name: TABLE brew_planning_splits; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.brew_planning_splits TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.brew_planning_splits TO authenticated;
GRANT ALL ON TABLE public.brew_planning_splits TO service_role;


--
-- Name: TABLE cellar_action_tags; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.cellar_action_tags TO authenticated;
GRANT ALL ON TABLE public.cellar_action_tags TO service_role;


--
-- Name: SEQUENCE cellar_action_tags_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.cellar_action_tags_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.cellar_action_tags_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.cellar_action_tags_id_seq TO service_role;


--
-- Name: TABLE cellar_plan_parts; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.cellar_plan_parts TO authenticated;
GRANT ALL ON TABLE public.cellar_plan_parts TO service_role;


--
-- Name: SEQUENCE cellar_plan_parts_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.cellar_plan_parts_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.cellar_plan_parts_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.cellar_plan_parts_id_seq TO service_role;


--
-- Name: TABLE document_types; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.document_types TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.document_types TO authenticated;
GRANT ALL ON TABLE public.document_types TO service_role;


--
-- Name: SEQUENCE fermentation_log_entries_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.fermentation_log_entries_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.fermentation_log_entries_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.fermentation_log_entries_id_seq TO service_role;


--
-- Name: SEQUENCE fermentation_log_entry_tags_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.fermentation_log_entry_tags_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.fermentation_log_entry_tags_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.fermentation_log_entry_tags_id_seq TO service_role;


--
-- Name: TABLE filling_measurements; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.filling_measurements TO authenticated;
GRANT ALL ON TABLE public.filling_measurements TO service_role;


--
-- Name: SEQUENCE filling_measurements_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.filling_measurements_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.filling_measurements_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.filling_measurements_id_seq TO service_role;


--
-- Name: TABLE filling_session_articles; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.filling_session_articles TO authenticated;
GRANT ALL ON TABLE public.filling_session_articles TO service_role;


--
-- Name: SEQUENCE filling_session_articles_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.filling_session_articles_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.filling_session_articles_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.filling_session_articles_id_seq TO service_role;


--
-- Name: TABLE filling_session_materials; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.filling_session_materials TO authenticated;
GRANT ALL ON TABLE public.filling_session_materials TO service_role;


--
-- Name: SEQUENCE filling_session_materials_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.filling_session_materials_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.filling_session_materials_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.filling_session_materials_id_seq TO service_role;


--
-- Name: SEQUENCE filling_sessions_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.filling_sessions_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.filling_sessions_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.filling_sessions_id_seq TO service_role;


--
-- Name: TABLE hbt_readings; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.hbt_readings TO authenticated;
GRANT ALL ON TABLE public.hbt_readings TO service_role;


--
-- Name: SEQUENCE hbt_readings_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.hbt_readings_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.hbt_readings_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.hbt_readings_id_seq TO service_role;


--
-- Name: TABLE ingredient_categories; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ingredient_categories TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ingredient_categories TO authenticated;
GRANT ALL ON TABLE public.ingredient_categories TO service_role;


--
-- Name: SEQUENCE ingredient_categories_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.ingredient_categories_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.ingredient_categories_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.ingredient_categories_id_seq TO service_role;


--
-- Name: TABLE ingredient_declarations; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ingredient_declarations TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ingredient_declarations TO authenticated;
GRANT ALL ON TABLE public.ingredient_declarations TO service_role;


--
-- Name: TABLE ingredient_documents; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ingredient_documents TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ingredient_documents TO authenticated;
GRANT ALL ON TABLE public.ingredient_documents TO service_role;


--
-- Name: SEQUENCE ingredient_documents_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.ingredient_documents_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.ingredient_documents_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.ingredient_documents_id_seq TO service_role;


--
-- Name: TABLE ingredient_revisions; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ingredient_revisions TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ingredient_revisions TO authenticated;
GRANT ALL ON TABLE public.ingredient_revisions TO service_role;


--
-- Name: SEQUENCE ingredient_revisions_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.ingredient_revisions_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.ingredient_revisions_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.ingredient_revisions_id_seq TO service_role;


--
-- Name: TABLE recipe_ingredients; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_ingredients TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_ingredients TO authenticated;
GRANT ALL ON TABLE public.recipe_ingredients TO service_role;


--
-- Name: TABLE ingredient_usage_counts; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ingredient_usage_counts TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ingredient_usage_counts TO authenticated;
GRANT ALL ON TABLE public.ingredient_usage_counts TO service_role;


--
-- Name: TABLE ingredients; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ingredients TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ingredients TO authenticated;
GRANT ALL ON TABLE public.ingredients TO service_role;


--
-- Name: SEQUENCE ingredients_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.ingredients_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.ingredients_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.ingredients_id_seq TO service_role;


--
-- Name: TABLE lots; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.lots TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.lots TO authenticated;
GRANT ALL ON TABLE public.lots TO service_role;


--
-- Name: SEQUENCE lots_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.lots_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.lots_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.lots_id_seq TO service_role;


--
-- Name: TABLE packaging_article_materials; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.packaging_article_materials TO authenticated;
GRANT ALL ON TABLE public.packaging_article_materials TO service_role;


--
-- Name: SEQUENCE packaging_article_materials_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.packaging_article_materials_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.packaging_article_materials_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.packaging_article_materials_id_seq TO service_role;


--
-- Name: TABLE packaging_articles; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.packaging_articles TO authenticated;
GRANT ALL ON TABLE public.packaging_articles TO service_role;


--
-- Name: SEQUENCE packaging_articles_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.packaging_articles_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.packaging_articles_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.packaging_articles_id_seq TO service_role;


--
-- Name: TABLE packaging_materials; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.packaging_materials TO authenticated;
GRANT ALL ON TABLE public.packaging_materials TO service_role;


--
-- Name: SEQUENCE packaging_materials_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.packaging_materials_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.packaging_materials_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.packaging_materials_id_seq TO service_role;


--
-- Name: TABLE permission_modules; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.permission_modules TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.permission_modules TO authenticated;
GRANT ALL ON TABLE public.permission_modules TO service_role;


--
-- Name: TABLE processing_comments; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.processing_comments TO authenticated;
GRANT ALL ON TABLE public.processing_comments TO service_role;


--
-- Name: SEQUENCE processing_comments_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.processing_comments_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.processing_comments_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.processing_comments_id_seq TO service_role;


--
-- Name: SEQUENCE processing_sessions_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.processing_sessions_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.processing_sessions_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.processing_sessions_id_seq TO service_role;


--
-- Name: TABLE product_sheet_revisions; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.product_sheet_revisions TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.product_sheet_revisions TO authenticated;
GRANT ALL ON TABLE public.product_sheet_revisions TO service_role;


--
-- Name: SEQUENCE product_sheet_revisions_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.product_sheet_revisions_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.product_sheet_revisions_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.product_sheet_revisions_id_seq TO service_role;


--
-- Name: TABLE product_sheets; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.product_sheets TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.product_sheets TO authenticated;
GRANT ALL ON TABLE public.product_sheets TO service_role;


--
-- Name: TABLE product_sheet_status; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.product_sheet_status TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.product_sheet_status TO authenticated;
GRANT ALL ON TABLE public.product_sheet_status TO service_role;


--
-- Name: SEQUENCE product_sheets_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.product_sheets_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.product_sheets_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.product_sheets_id_seq TO service_role;


--
-- Name: TABLE recipe_brewing_specs; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_brewing_specs TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_brewing_specs TO authenticated;
GRANT ALL ON TABLE public.recipe_brewing_specs TO service_role;


--
-- Name: TABLE recipe_cellar_steps; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_cellar_steps TO authenticated;
GRANT ALL ON TABLE public.recipe_cellar_steps TO service_role;


--
-- Name: SEQUENCE recipe_cellar_steps_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.recipe_cellar_steps_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.recipe_cellar_steps_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.recipe_cellar_steps_id_seq TO service_role;


--
-- Name: TABLE recipe_comments; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_comments TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_comments TO authenticated;
GRANT ALL ON TABLE public.recipe_comments TO service_role;


--
-- Name: TABLE recipe_costs; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_costs TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_costs TO authenticated;
GRANT ALL ON TABLE public.recipe_costs TO service_role;


--
-- Name: TABLE recipe_fermentation; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_fermentation TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_fermentation TO authenticated;
GRANT ALL ON TABLE public.recipe_fermentation TO service_role;


--
-- Name: SEQUENCE recipe_ingredients_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.recipe_ingredients_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.recipe_ingredients_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.recipe_ingredients_id_seq TO service_role;


--
-- Name: TABLE recipe_packaging; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_packaging TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_packaging TO authenticated;
GRANT ALL ON TABLE public.recipe_packaging TO service_role;


--
-- Name: TABLE recipe_process_steps; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_process_steps TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_process_steps TO authenticated;
GRANT ALL ON TABLE public.recipe_process_steps TO service_role;


--
-- Name: TABLE recipe_revisions; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_revisions TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_revisions TO authenticated;
GRANT ALL ON TABLE public.recipe_revisions TO service_role;


--
-- Name: SEQUENCE recipe_revisions_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.recipe_revisions_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.recipe_revisions_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.recipe_revisions_id_seq TO service_role;


--
-- Name: TABLE recipe_specs; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_specs TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_specs TO authenticated;
GRANT ALL ON TABLE public.recipe_specs TO service_role;


--
-- Name: TABLE recipe_water; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_water TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipe_water TO authenticated;
GRANT ALL ON TABLE public.recipe_water TO service_role;


--
-- Name: TABLE recipes; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipes TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.recipes TO authenticated;
GRANT ALL ON TABLE public.recipes TO service_role;


--
-- Name: SEQUENCE recipes_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.recipes_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.recipes_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.recipes_id_seq TO service_role;


--
-- Name: TABLE role_permissions; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.role_permissions TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.role_permissions TO authenticated;
GRANT ALL ON TABLE public.role_permissions TO service_role;


--
-- Name: TABLE roles; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.roles TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.roles TO authenticated;
GRANT ALL ON TABLE public.roles TO service_role;


--
-- Name: SEQUENCE roles_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.roles_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.roles_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.roles_id_seq TO service_role;


--
-- Name: TABLE stock_movements; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.stock_movements TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.stock_movements TO authenticated;
GRANT ALL ON TABLE public.stock_movements TO service_role;


--
-- Name: SEQUENCE stock_movements_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.stock_movements_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.stock_movements_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.stock_movements_id_seq TO service_role;


--
-- Name: SEQUENCE tanks_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.tanks_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.tanks_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.tanks_id_seq TO service_role;


--
-- Name: TABLE units; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.units TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.units TO authenticated;
GRANT ALL ON TABLE public.units TO service_role;


--
-- Name: TABLE water_settings; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.water_settings TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.water_settings TO authenticated;
GRANT ALL ON TABLE public.water_settings TO service_role;


--
-- Name: TABLE water_settings_history; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.water_settings_history TO anon;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.water_settings_history TO authenticated;
GRANT ALL ON TABLE public.water_settings_history TO service_role;


--
-- Name: SEQUENCE water_settings_history_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT,USAGE ON SEQUENCE public.water_settings_history_id_seq TO anon;
GRANT SELECT,USAGE ON SEQUENCE public.water_settings_history_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.water_settings_history_id_seq TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT SELECT,USAGE ON SEQUENCES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT SELECT,USAGE ON SEQUENCES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT SELECT,INSERT,DELETE,UPDATE ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT SELECT,INSERT,DELETE,UPDATE ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO service_role;


--
-- PostgreSQL database dump complete
--


