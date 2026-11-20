-- Security phase 4 (security review 19-11-2026, P1.4 and P2.4): Claude Reader.
--
-- 1. People data out of reach. claude_reader (the role the company-Claude
--    connector queries as, with BYPASSRLS) loses SELECT on users,
--    batch_audit_log and the view brew_planning_history_detailed (who changed
--    the planning). Everything else stays readable. Decision Jaap, 20-11-2026.
--
-- 2. Dedicated login. The connector connected as postgres (the built-in
--    SUPABASE_DB_URL of Edge Functions) and switched to claude_reader per
--    query. claude_reader_login can only: read the token table, insert into
--    the query log, and SET ROLE claude_reader (NOINHERIT, so it has no data
--    rights of its own). It is created WITHOUT a password, so nobody can log
--    in with it until Jaap sets one; the Edge Function secret READER_DB_URL
--    then points at it.
--
-- 3. Token expiry. access_tokens gets expires_at; the function rejects
--    expired tokens. claude_connector.issue_token() creates a token valid for
--    1 year (decision Jaap) and returns it once; only its SHA-256 is stored.
--    The existing token, which is also visible in the function logs, gets a
--    14-day grace period so the connector keeps working while it is replaced.
--
-- Idempotent. Rollback: docs/security/phase4-rollback.sql.

begin;

-- 1. People data ----------------------------------------------------------
revoke select on public.users                          from claude_reader;
revoke select on public.batch_audit_log                from claude_reader;
revoke select on public.brew_planning_history_detailed from claude_reader;

-- 3. Token expiry (before the grants below, which name the column) ---------
alter table claude_connector.access_tokens add column if not exists expires_at timestamptz;
update claude_connector.access_tokens
   set expires_at = now() + interval '14 days'
 where expires_at is null and revoked_at is null;

create or replace function claude_connector.issue_token(p_label text, p_valid_for interval default interval '1 year')
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_token text := encode(extensions.gen_random_bytes(32), 'hex');
begin
  if coalesce(trim(p_label), '') = '' then
    raise exception 'issue_token: a label is required';
  end if;
  insert into claude_connector.access_tokens (label, token_sha256, expires_at)
  values (p_label, encode(extensions.digest(v_token, 'sha256'), 'hex'), now() + p_valid_for);
  return v_token;  -- shown once; store it only in the connector URL
end;
$$;
revoke execute on function claude_connector.issue_token(text, interval) from public, anon, authenticated;

-- 2. Dedicated login ------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'claude_reader_login') then
    create role claude_reader_login login noinherit nosuperuser nocreatedb nocreaterole nobypassrls;
  end if;
end $$;
alter role claude_reader_login connection limit 10;

grant claude_reader to claude_reader_login with inherit false, set true;

grant usage on schema claude_connector to claude_reader_login;
grant select (id, token_sha256, revoked_at, expires_at) on claude_connector.access_tokens to claude_reader_login;
grant insert (token_id, tool, arguments, row_count, duration_ms, error) on claude_connector.query_log to claude_reader_login;

-- Both tables have RLS on and no policies (only the owner could use them).
drop policy if exists access_tokens_reader_login_select on claude_connector.access_tokens;
create policy access_tokens_reader_login_select on claude_connector.access_tokens
  for select to claude_reader_login using (true);
drop policy if exists query_log_reader_login_insert on claude_connector.query_log;
create policy query_log_reader_login_insert on claude_connector.query_log
  for insert to claude_reader_login with check (true);

commit;
