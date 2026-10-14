-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

do $$
declare
  tabel text;
begin
  foreach tabel in array array['eenheden','ingredient_categories','hop_utilisatie_curve','verpakkingsartikelen','verpakkingsmaterialen'] loop
    execute format('drop policy if exists %I on %I', tabel || '_select', tabel);
    execute format('create policy %I on %I for select using (true)', tabel || '_select', tabel);
  end loop;
end $$;
