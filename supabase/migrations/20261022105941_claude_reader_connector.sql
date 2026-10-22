-- Run directly on production on 22-10 (Jaap's Claude connector, not from this
-- repo) and registered in supabase_migrations.schema_migrations as
-- 20261022105941 claude_reader_connector. Copied here as it was run, so the
-- GitHub integration accepts new migrations again (supabase/migrations/README.md).
-- It is not executed again.

create role claude_reader nologin bypassrls;
grant claude_reader to postgres with inherit false, set true;

grant usage on schema public to claude_reader;
grant select on all tables in schema public to claude_reader;
alter default privileges for role postgres in schema public grant select on tables to claude_reader;

create schema if not exists claude_connector;
revoke all on schema claude_connector from public, anon, authenticated;

create table claude_connector.access_tokens (
  id            bigint generated always as identity primary key,
  label         text not null,
  token_sha256  text not null unique,
  created_at    timestamptz not null default now(),
  revoked_at    timestamptz
);

create table claude_connector.query_log (
  id           bigint generated always as identity primary key,
  at           timestamptz not null default now(),
  token_id     bigint references claude_connector.access_tokens(id),
  tool         text not null,
  arguments    jsonb,
  row_count    integer,
  duration_ms  integer,
  error        text
);
create index on claude_connector.query_log (at desc);

alter table claude_connector.access_tokens enable row level security;
alter table claude_connector.query_log enable row level security;
