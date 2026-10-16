select 'recipes.max_gewijzigd_op' k, max(gewijzigd_op)::text v, count(*) n from recipes
union all select 'ps.in_sync', in_sync::text, count(*) from product_sheet_status group by 2
union all select 'naam_sw filled', '', count(*) from recipe_brouwspecificaties where nullif(recept_naam_software,'') is not null;
