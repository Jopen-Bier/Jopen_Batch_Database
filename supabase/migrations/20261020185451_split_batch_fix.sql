-- Batch report, phase 8 fix (rooktest, Jaap 20-10): split_batch() to an
-- existing batch or a discard failed with 'record "v_recipe" is not assigned
-- yet': the log text referenced the recipe record, which is only filled for
-- a new batch, and PL/pgSQL evaluates every record field of an expression.
-- The recipe id and name are now plain variables. Same signature and rights.
-- Plain ASCII (the middle dot is chr(183)).

begin;

-- One call per save of the Split / transfer popup: the transfer, the new
-- batch when the destination is 'new', and a log entry with tag Transfer on
-- the source batch. Runs with the rights of the user (RLS on every table).
-- Returns { transfer_id, to_batch_id, batch_number, log_entry_id }.
create or replace function public.split_batch(
  p_batch_id       bigint,
  p_transferred_at timestamptz,
  p_volume_hl      numeric,
  p_from_tank_id   bigint,
  p_destination    text,            -- 'new' | 'batch' | 'discard'
  p_recipe_id      bigint default null,
  p_to_batch_id    bigint default null,
  p_reason         text default null,
  p_comment        text default null)
returns jsonb
language plpgsql
set search_path to 'public'
as $function$
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
$function$;

revoke all on function public.split_batch(bigint, timestamptz, numeric, bigint, text, bigint, bigint, text, text) from public, anon;
grant execute on function public.split_batch(bigint, timestamptz, numeric, bigint, text, bigint, bigint, text, text) to authenticated;

commit;
