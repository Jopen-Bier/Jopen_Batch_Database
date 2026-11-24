# Two-factor authentication (MFA)

Security phase 5 (24-11-2026). Users can protect their account with a
6-digit code from an authenticator app (TOTP: Microsoft Authenticator,
Google Authenticator, 1Password, ...).

## How it works

- **Per role:** User Roles page, column *Two-factor* → "Required". Always on
  for **admin** (the database refuses to switch it off).
- **Voluntary:** anyone can turn it on via their name menu → *Two-factor
  authentication* (`mfa.html`). Once set up, the code is always asked, also
  in a role that does not require it.
- **Enforced in the database**, not only in the app: `public.mfa_satisfied()`
  is false until the session has entered its code (JWT `aal = aal2`) when
  the user has an authenticator or their role requires one.
  `current_role_id()` and `is_admin()` check it, so every policy and the
  admin Edge Functions (`delete-user`, `generate-invite-link`, which ask
  `is_admin()` with the caller's session) deny until the code is entered.
- **In the app:** `nav.js` sends such users to `mfa.html` (set up, or enter
  the code) before any other page.
- **Password changes** (`accept-invite.html`) refuse passwords from known data
  breaches (Have I Been Pwned range API, only a 5-character hash prefix
  leaves the browser) and ask for the code first when the account has MFA.

## Prerequisite (Supabase dashboard)

Authentication → Multi-Factor (or Sign In / Providers → MFA): **TOTP
enabled** (enroll and verify). Without it, setting up fails and users of a
role that requires MFA cannot get in.

## Someone lost their phone

An admin cannot see or remove another person's authenticator in the app.
In the Supabase dashboard → **SQL Editor**:

```sql
delete from auth.mfa_factors
where user_id = (select id from auth.users where email = 'colleague@jopenbier.nl');
```

The colleague logs in again with their password; if their role requires
MFA they are asked to set up a new authenticator straight away.

**The only admin lost their phone:** same query for your own e-mail address.
The Supabase dashboard has its own login, so this always works.

## Emergency rollback

`docs/security/phase5-rollback.sql` restores `current_role_id()` and
`is_admin()` without the MFA check (everyone gets their rights back with a
password only). Fix forward with a new migration afterwards.
