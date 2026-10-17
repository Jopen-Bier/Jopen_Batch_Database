select 'b.status' k, status v, count(*) n from batches group by 2
union all select 'h.rows', actie, count(*) from brew_planning_geschiedenis group by 2
union all select 'bp.rows', '', count(*) from brew_planning
union all select 'h.max', max(gewijzigd_op)::text, count(*) from brew_planning_geschiedenis
order by 1, 2;
