-- Counts only (no row data): this output ends up in the Actions log.
select 'recipes.status' k, status v, count(*) n from recipes group by 2
union all select 'recipes.location', coalesce(location,'NULL'), count(*) from recipes group by 2
union all select 'ri.addition_type', addition_type, count(*) from recipe_ingredients group by 2
union all select 'rf.beer_risk', coalesce(beer_risk,'NULL'), count(*) from recipe_fermentation group by 2
union all select 'rf.beer_status', coalesce(beer_status,'NULL'), count(*) from recipe_fermentation group by 2
union all select 'brewhouse_name', 'wp', count(*) from recipe_brewing_specs where brewhouse_recipe_name_wp is not null
union all select 'brewhouse_name', 'jk', count(*) from recipe_brewing_specs where brewhouse_recipe_name_jk is not null
union all select 'ps.status', status, count(*) from product_sheets group by 2
union all select 'ps.in_sync', in_sync::text, count(*) from product_sheet_status group by 2
union all select 'snapshot key', k, count(*) from product_sheets, jsonb_object_keys(coalesce(sync_snapshot,'{}')) k group by 2
union all select 'water hist key', k, count(*) from water_settings_history, jsonb_object_keys(data) k group by 2
union all select 'recipes.max_updated_at', max(updated_at)::text, count(*) from recipes
order by 1, 2;
