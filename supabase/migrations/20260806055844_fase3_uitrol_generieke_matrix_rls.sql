-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

do $$
declare
  t record;
  p record;
  standaard_tabellen text[][] := array[
    -- [tabelnaam, module_key]
    ['recipes','recipes'], ['recipe_specificaties','recipes'], ['recipe_fermentatie','recipes'],
    ['recipe_brouwspecificaties','recipes'], ['recipe_processtappen','recipes'], ['recipe_ingredients','recipes'],
    ['recipe_maisch_stappen','recipes'], ['recipe_water','recipes'], ['recipe_verpakking','recipes'],
    ['recipe_kosten','recipes'], ['recipe_comments','recipes'], ['recipe_revisies','recipes'],
    ['ingredients','ingredients'],
    ['batch_afvul_metingen','batches'], ['batch_afvul_regels','batches'], ['batch_afvul_sessies','batches'],
    ['batch_afvullijnen','batches'], ['batch_brouwsels','batches'], ['batch_gistkaart_metingen','batches'],
    ['batch_hbt_eindwaarden','batches'], ['batch_hbt_vullingen','batches'], ['batch_ingredient_lotnummers','batches'],
    ['batch_jaar_teller','batches'], ['batch_processtappen_uitvoering','batches'], ['batch_verbruik_materialen','batches'],
    ['batch_verwerking_sessies','batches'],
    ['brew_planning','brewing_planning'], ['brew_capacity','brewing_planning'],
    ['eenheden','settings'], ['ingredient_categories','settings'], ['hop_utilisatie_curve','settings'],
    ['verpakkingsartikelen','settings'], ['verpakkingsmaterialen','settings']
  ];
begin
  for i in 1 .. array_length(standaard_tabellen, 1) loop
    -- alle bestaande policies op deze tabel weg, ongeacht hoe ze ooit heetten
    for p in select policyname from pg_policies where schemaname='public' and tablename = standaard_tabellen[i][1] loop
      execute format('drop policy if exists %I on %I', p.policyname, standaard_tabellen[i][1]);
    end loop;

    execute format('create policy %I on %I for select using (mag_bekijken(%L))',
      standaard_tabellen[i][1] || '_select', standaard_tabellen[i][1], standaard_tabellen[i][2]);
    execute format('create policy %I on %I for insert with check (mag_bewerken(%L))',
      standaard_tabellen[i][1] || '_insert', standaard_tabellen[i][1], standaard_tabellen[i][2]);
    execute format('create policy %I on %I for update using (mag_bewerken(%L)) with check (mag_bewerken(%L))',
      standaard_tabellen[i][1] || '_update', standaard_tabellen[i][1], standaard_tabellen[i][2], standaard_tabellen[i][2]);
    execute format('create policy %I on %I for delete using (mag_verwijderen(%L))',
      standaard_tabellen[i][1] || '_delete', standaard_tabellen[i][1], standaard_tabellen[i][2]);
  end loop;
end $$;

-- Uitzonderingen met een ander policy-vorm dan de standaard 4:

-- ingredient_revisies: alleen select + insert (revisies worden nooit bewerkt/verwijderd,
-- verwijderen loopt via de CASCADE op ingredients zelf)
drop policy if exists ingredient_revisies_insert_editor_of_hoger on ingredient_revisies;
drop policy if exists ingredient_revisies_select_authenticated on ingredient_revisies;
create policy ingredient_revisies_select on ingredient_revisies for select using (mag_bekijken('ingredients'));
create policy ingredient_revisies_insert on ingredient_revisies for insert with check (mag_bewerken('ingredients'));

-- brew_planning_geschiedenis: alleen-lezen audit-trail (schrijven loopt via trigger)
drop policy if exists brew_planning_geschiedenis_select_authenticated on brew_planning_geschiedenis;
create policy brew_planning_geschiedenis_select on brew_planning_geschiedenis for select using (mag_bekijken('brewing_planning'));
