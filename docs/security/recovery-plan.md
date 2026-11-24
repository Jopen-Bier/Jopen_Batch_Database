# Recovery plan — Jopen Batch Database

Security phase 6 (24-11-2026). What we can lose, how fast we are back, and
what to do first in each kind of incident. The step-by-step restore manual
is `.github/backup/RESTORE.md`; keep a copy of both outside the app (for
example in the company drive), because you need them when the app is down.

## Targets

| | Target | Why this is realistic |
|---|---|---|
| **Data loss (RPO)** | at most **24 hours** | database dump and Storage mirror every night (03:00 UTC). Supabase Free has no backups or point-in-time recovery of its own. |
| **Back up and running (RTO)** | **1 working day** for a full restore to a new Supabase project; **1 hour** to get back one batch, lot or file | the full restore is described step by step and rehearsed once a year (see *Drill*). |

## How we know the backups work

| Check | When | Fails when |
|---|---|---|
| Trial restore of the fresh dump + row counts + app smoke test | every night (Daily backup) | the dump cannot be restored, rows are missing, or the app would not work on it (rights, RLS, two-factor, views) |
| Restore test from the backup repo + app smoke test + Storage check | every Monday (Restore test) | as above, or a file in the Storage mirror is missing, truncated or not a real PDF/image, or a file older than 36 h is not in the mirror |
| Full restore drill | once a year, by hand | see *Drill* |

A red run e-mails the person who last changed the workflow; also glance at
the **Actions** tab now and then.

## First steps per incident

**Someone changed or deleted the wrong thing (by mistake or on purpose)**
1. Look it up in the audit log: `batch_audit_log` (batch and everything
   under it) or `inventory_audit_log` (lots, stock movements). They hold the
   old and new row, who and when.
2. Small: put the old values back from `old_data`. Larger: restore last
   night's dump in a throwaway database and copy the rows back
   (RESTORE.md, *Eén bestand of een oude versie terughalen*).

**An account is (possibly) taken over**
1. Supabase → Authentication → Users → the user → *Sign out* (ends every
   session) and reset the password; set `users.is_active = false` if needed.
2. Remove their authenticator if the phone is involved
   (`docs/security/mfa.md`).
3. Check the audit logs for what that account changed since the suspected
   moment.
4. An admin account: also rotate the secrets it could have seen (below).

**A secret leaked** — rotate it (table below), then check the logs.

**The Supabase project is lost or unusable** — full restore to a new
project: `.github/backup/RESTORE.md`, *Noodrestore*, then everything in
*Not in the backup* below.

**The GitHub repo or account is compromised** — revoke tokens and app
access (GitHub → Settings → Applications and Developer settings), check the
`protect-main` ruleset is still active, check recent commits on `main`
and the `production` environment secrets; rotate the secrets in it.

## Not in the backup (set again after a full restore)

| What | Where it lives | How to set it again |
|---|---|---|
| Edge Functions | `supabase/functions/` in this repo | deploy from the repo (`claude-reader-mcp` with verify_jwt off; `delete-user` and `generate-invite-link` on) |
| Edge Function secrets | Supabase → Edge Functions → Secrets | `READER_DB_URL` (new password for `claude_reader_login`), `MS_TENANT_ID`, `MS_CLIENT_ID`, `MS_CLIENT_SECRET`, `MAIL_SENDER` |
| Auth settings | Supabase → Authentication | Site URL + Redirect URLs (incl. `accept-invite.html`), **MFA → TOTP on**, Send Email hook (`auth-email`) |
| Two-factor authenticators | `auth.mfa_factors` (deliberately not backed up: holds the authenticator secrets) | everyone sets up their authenticator again; the app asks at the first login |
| Storage bucket limits | migration `20261124170000` (storage settings are not in the dump) | run the *Storage limits* part of that migration in the SQL Editor |
| Claude Reader connector token | `claude_connector.access_tokens` (restored) | issue a new one with `claude_connector.issue_token()` and update the connector URL |
| GitHub `production` secrets | GitHub → Settings → Environments → production | new `SUPABASE_DB_URL` (new project), new service role key |
| App config | `config.js` | new project URL and publishable key, via a pull request |

## Secret rotation

| Secret | Used by | Rotate |
|---|---|---|
| Database password (`postgres`) | `SUPABASE_DB_URL` in GitHub `production` | Supabase → Database → reset password; update the secret; run Daily backup by hand |
| `claude_reader_login` password | `READER_DB_URL` Edge Function secret | `alter role claude_reader_login password '…'`; update the secret |
| Service role / secret keys | `SUPABASE_SERVICE_ROLE_KEY` (GitHub), Edge Functions | Supabase → API Keys → new key, update, then revoke the old one |
| `BACKUP_REPO_PAT` | backup workflows | GitHub fine-grained token, **expires yearly** (Nov 2027): regenerate with expiry, update, run Daily backup |
| Claude Reader token | company Claude connector | `issue_token()`, update the connector, revoke the old one; **expires yearly** (Nov 2027) |
| Microsoft Graph client secret | e-mail (`MS_CLIENT_SECRET`) | Entra ID → app registration → new secret, update the Edge Function secret |

## Drill (once a year)

1. Create a temporary Supabase project (Free allows a second one).
2. Follow RESTORE.md *Noodrestore* with last night's backup, including
   Storage, against that project. Note the time it took.
3. Point a local copy of the app (`config.js`) at it, log in as admin (set
   up the authenticator), open a batch, a batch document and an ingredient
   document.
4. Delete the temporary project. Add a line below.

| Date | By | Duration | Result / what to improve |
|---|---|---|---|
| | | | |
