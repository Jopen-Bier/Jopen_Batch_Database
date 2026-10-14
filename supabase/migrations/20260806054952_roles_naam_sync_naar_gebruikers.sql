-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

-- Als een rol wordt hernoemd (roles.naam), moet gebruikers.rol (tekst) voor
-- iedereen met die rol automatisch meeveranderen -- anders raakt de
-- naam-gebaseerde lookup in nav.js (jopenHaalRechten) stil uit sync.
create or replace function roles_sync_naam_naar_gebruikers()
returns trigger
language plpgsql
as $$
begin
  if new.naam is distinct from old.naam then
    update gebruikers set rol = new.naam where role_id = new.id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_roles_sync_naam_naar_gebruikers on roles;
create trigger trg_roles_sync_naam_naar_gebruikers
  after update on roles
  for each row execute function roles_sync_naam_naar_gebruikers();
