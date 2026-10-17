-- Counts only (no row data): this output ends up in the Actions log.
select 'b.status' k, status v, count(*) n from batches group by 2
union all select 'h.rows', action, count(*) from brew_planning_history group by 2
union all select 'bp.rows', '', count(*) from brew_planning
union all select 'h.max', max(updated_at)::text, count(*) from brew_planning_history
union all select 'h.key.before', k, count(*) from brew_planning_history, jsonb_object_keys(coalesce(before,'{}')) k group by 2
union all select 'h.key.after', k, count(*) from brew_planning_history, jsonb_object_keys(coalesce(after,'{}')) k group by 2
union all select 'detailed.rows', '', count(*) from brew_planning_history_detailed
union all select 'changes.rows', '', count(*) from brew_planning_changes
union all select 'changes.brews_after', '', count(brews_after) from brew_planning_changes
order by 1, 2;
-- trigger test inside a rolled-back block
begin;
update brew_planning set notes = notes where id = (select id from brew_planning limit 1);
select 'trigger.new_row' k, action || ': ' || (select string_agg(k2, ',' order by k2) from jsonb_object_keys(after) k2) v, 1 n from (select * from brew_planning_history order by updated_at desc limit 1) x;
rollback;
