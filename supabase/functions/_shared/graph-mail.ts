// supabase/functions/_shared/graph-mail.ts
//
// Sends e-mail from the company mailbox through Microsoft Graph and records
// every attempt in public.email_log. Used by generate-invite-link, auth-email
// (Supabase Auth "Send Email Hook") and send-report-email.
//
// Microsoft 365 app registration (Entra ID) with the application permission
// Mail.Send; app-only token via the client-credentials flow. Edge Function
// secrets (Supabase Dashboard > Edge Functions > Secrets), never in the repo:
//   MS_TENANT_ID, MS_CLIENT_ID, MS_CLIENT_SECRET, MAIL_SENDER

// Trimmed: a space or newline pasted along with a secret breaks the sign-in.
const secret = (name: string) => Deno.env.get(name)?.trim() || undefined;
const TENANT_ID = secret("MS_TENANT_ID");
const CLIENT_ID = secret("MS_CLIENT_ID");
const CLIENT_SECRET = secret("MS_CLIENT_SECRET");
export const MAIL_SENDER = secret("MAIL_SENDER") ?? "database@jopenbier.nl";

export type Recipient = { email: string; name?: string | null };
export type EmailType = "invite" | "password_reset" | "processing_report";

export type Mail = {
  to: Recipient[];
  subject: string;
  html: string;
};

export type LogInfo = {
  type: EmailType;
  sentBy?: string | null; // public.users.id of whoever triggered it; null for self-service
  batchId?: number | null;
};

// The token is valid for about an hour; reuse it while the function instance lives.
let cachedToken: { value: string; expiresAt: number } | null = null;

async function graphToken(): Promise<string> {
  if (!TENANT_ID || !CLIENT_ID || !CLIENT_SECRET) {
    throw new Error("E-mail is not configured on the server (missing Microsoft secrets)");
  }
  if (cachedToken && cachedToken.expiresAt > Date.now() + 60_000) return cachedToken.value;

  const res = await fetch(`https://login.microsoftonline.com/${TENANT_ID}/oauth2/v2.0/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: CLIENT_ID,
      client_secret: CLIENT_SECRET,
      scope: "https://graph.microsoft.com/.default",
      grant_type: "client_credentials",
    }),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok || !data.access_token) {
    console.error("Microsoft token request failed", res.status, data?.error, data?.error_description);
    // Shape of the configured values only (never the secret itself), to tell a
    // Secret ID (a GUID, 36 characters) from a secret Value (about 40, with ~).
    const guid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    console.error("Microsoft settings check", JSON.stringify({
      secretLength: CLIENT_SECRET.length, secretLooksLikeSecretId: guid.test(CLIENT_SECRET),
      secretHasTilde: CLIENT_SECRET.includes("~"), clientIdIsGuid: guid.test(CLIENT_ID), tenantIdIsGuid: guid.test(TENANT_ID),
    }));
    throw new Error(`Could not sign in to Microsoft (${data?.error ?? res.status})`);
  }
  cachedToken = { value: data.access_token, expiresAt: Date.now() + Number(data.expires_in ?? 3600) * 1000 };
  return cachedToken.value;
}

async function graphSend(mail: Mail): Promise<void> {
  const token = await graphToken();
  const res = await fetch(`https://graph.microsoft.com/v1.0/users/${encodeURIComponent(MAIL_SENDER)}/sendMail`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      message: {
        subject: mail.subject,
        body: { contentType: "HTML", content: mail.html },
        toRecipients: mail.to.map((r) => ({ emailAddress: { address: r.email, name: r.name || undefined } })),
      },
      saveToSentItems: true,
    }),
  });
  if (!res.ok) {
    const detail = await res.text().catch(() => "");
    console.error("Graph sendMail failed", res.status, detail);
    throw new Error(`Microsoft refused the message (${res.status})`);
  }
}

// Sends the mail and logs the attempt (sent or failed). Throws when sending
// fails, after logging. `adminClient` is a service-role Supabase client:
// email_log has no insert policy for logged-in users.
// deno-lint-ignore no-explicit-any
export async function sendLoggedMail(adminClient: any, mail: Mail, log: LogInfo): Promise<void> {
  let failure: Error | null = null;
  try {
    if (!mail.to.length) throw new Error("No recipients");
    await graphSend(mail);
  } catch (err) {
    failure = err as Error;
  }
  const { error: logErr } = await adminClient.from("email_log").insert({
    email_type: log.type,
    recipients: mail.to.map((r) => r.email),
    subject: mail.subject,
    status: failure ? "failed" : "sent",
    error_message: failure ? failure.message : null,
    sent_by: log.sentBy ?? null,
    batch_id: log.batchId ?? null,
  });
  // A missing log row must not turn a sent mail into an error for the user.
  if (logErr) console.error("email_log insert failed", logErr.message);
  if (failure) throw failure;
}
