-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

-- Houdt rol (tekst, huidige UI) en role_id (stabiele FK, nieuwe RLS) altijd
-- automatisch in sync, in beide richtingen. Validatie loopt voortaan dynamisch
-- tegen de roles-tabel i.p.v. een hardcoded array — dus een nieuwe rol
-- toevoegen aan `roles` maakt hem meteen bruikbaar, geen migratie meer nodig.
create or replace function gebruikers_sync_rol_role_id()
returns trigger
language plpgsql
as $$
declare
  v_naam text;
  v_role_id integer;
begin
  if tg_op = 'INSERT' or new.role_id is distinct from old.role_id then
    select naam into v_naam from roles where id = new.role_id;
    if new.role_id is not null and v_naam is null then
      raise exception 'Onbekend role_id: %', new.role_id;
    end if;
    if v_naam is not null then
      new.rol := v_naam;
    end if;
  elsif new.rol is distinct from old.rol then
    select id into v_role_id from roles where naam = new.rol;
    if v_role_id is null then
      raise exception 'Onbekende rol: % (bestaat niet in de roles-tabel)', new.rol;
    end if;
    new.role_id := v_role_id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_gebruikers_sync_rol_role_id on gebruikers;
create trigger trg_gebruikers_sync_rol_role_id
  before insert or update on gebruikers
  for each row execute function gebruikers_sync_rol_role_id();

-- Oude hardcoded lijst vervalt: validatie loopt nu via de trigger + roles-tabel.
alter table gebruikers drop constraint if exists gebruikers_rol_check;
