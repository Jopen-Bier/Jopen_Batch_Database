-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

create or replace function public.gebruikers_sync_rol_role_id()
returns trigger
language plpgsql
as $function$
declare
  v_naam text;
  v_role_id integer;
begin
  -- Als role_id expliciet is meegegeven/gewijzigd, is dat leidend: rol volgt eruit.
  if new.role_id is not null and (tg_op = 'INSERT' or new.role_id is distinct from old.role_id) then
    select naam into v_naam from roles where id = new.role_id;
    if v_naam is null then
      raise exception 'Onbekend role_id: %', new.role_id;
    end if;
    new.rol := v_naam;
  -- Anders, als er een rol-tekst is (insert met alleen rol gezet, of latere update van rol),
  -- wordt role_id daaruit afgeleid.
  elsif new.rol is not null then
    select id into v_role_id from roles where naam = new.rol;
    if v_role_id is null then
      raise exception 'Onbekende rol: % (bestaat niet in de roles-tabel)', new.rol;
    end if;
    new.role_id := v_role_id;
  end if;
  return new;
end;
$function$;
