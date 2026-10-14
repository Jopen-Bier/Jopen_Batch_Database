-- Overgenomen uit supabase_migrations.schema_migrations (was rechtstreeks
-- uitgevoerd, niet via deze map). Al op productie; wordt niet opnieuw gedraaid.

-- "Last login" in gebruikers.html las tot nu toe gebruikers.laatst_ingelogd,
-- een kolom die alleen bijgewerkt wordt via de zet_laatst_ingelogd()-RPC die
-- login.html aanroept ná een geslaagde signInWithPassword(). Dat vangt alleen
-- het moment dat iemand daadwerkelijk het loginformulier invult -- maar
-- Supabase-sessies blijven met een refresh token vaak wekenlang geldig, dus
-- de meeste gebruikers komen na hun allereerste keer nooit meer langs dat
-- codepad en laatst_ingelogd blijft voor hen voor altijd leeg, ook al loggen
-- ze via een onthouden sessie gewoon actief in. auth.users.last_sign_in_at
-- houdt dit al correct bij (Supabase's eigen, betrouwbare bron), maar het
-- auth-schema is niet rechtstreeks via de client bevraagbaar. Deze functie
-- ontsluit die kolom, alleen voor admins.
create or replace function public.admin_haal_laatste_logins()
returns table(id uuid, laatst_ingelogd timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Not authorized';
  end if;
  return query select au.id, au.last_sign_in_at from auth.users au;
end;
$$;

grant execute on function public.admin_haal_laatste_logins() to authenticated;
