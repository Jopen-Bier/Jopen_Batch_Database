-- Rollback for supabase/migrations/20261120130000_claude_reader_hardening.sql.
-- NOT a migration: run by hand in the SQL Editor only if phase 4 breaks the
-- connector, then fix forward. First point the Edge Function back at postgres
-- by deleting its secret READER_DB_URL (it then falls back to SUPABASE_DB_URL).

begin;

-- 1. People data readable again
grant select on public.users                          to claude_reader;
grant select on public.batch_audit_log                to claude_reader;
grant select on public.brew_planning_history_detailed to claude_reader;

-- 2. Dedicated login gone
drop policy if exists access_tokens_reader_login_select on claude_connector.access_tokens;
drop policy if exists query_log_reader_login_insert     on claude_connector.query_log;
revoke all on claude_connector.access_tokens from claude_reader_login;
revoke all on claude_connector.query_log     from claude_reader_login;
revoke usage on schema claude_connector      from claude_reader_login;
revoke claude_reader from claude_reader_login;
drop role if exists claude_reader_login;

-- 3. Expiry off (tokens without expires_at never expire). The column and
--    issue_token() can stay; drop them only if you really want to.
update claude_connector.access_tokens set expires_at = null where revoked_at is null;

commit;
