-- E-mail sent from database@jopenbier.nl (Microsoft Graph, Edge Functions
-- generate-invite-link, auth-email and later send-report-email). One row per
-- send attempt, sent or failed. Metadata only, no message body.
-- Written only by the Edge Functions (service role): no insert/update/delete
-- policies, so logged-in users cannot write or remove rows. Readable for
-- whoever may view user management.

create table if not exists public.email_log (
  id bigint generated always as identity primary key,
  email_type text not null
    constraint email_log_email_type_check check (email_type in ('invite', 'password_reset', 'processing_report')),
  recipients text[] not null,
  subject text not null,
  status text not null
    constraint email_log_status_check check (status in ('sent', 'failed')),
  error_message text,
  -- Who triggered it; null for self-service mail such as a password reset.
  sent_by uuid constraint email_log_sent_by_fkey references public.users(id) on delete set null,
  batch_id bigint constraint email_log_batch_id_fkey references public.batches(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists idx_email_log_created_at on public.email_log (created_at desc);
create index if not exists idx_email_log_sent_by on public.email_log (sent_by);
create index if not exists idx_email_log_batch_id on public.email_log (batch_id);

alter table public.email_log enable row level security;
drop policy if exists email_log_select on public.email_log;
create policy email_log_select on public.email_log for select to authenticated
  using ((select can_view('user_management')));
