// supabase/functions/auth-email/index.ts
//
// Supabase Auth "Send Email Hook": Supabase Auth calls this function instead
// of sending its own e-mail (Dashboard > Authentication > Hooks > Send Email,
// type HTTPS, pointing at this function). The mail goes out from
// database@jopenbier.nl through Microsoft Graph and is logged in email_log.
//
// Handled:
// - recovery: "Forgot password" on login.html (resetPasswordForEmail);
// - invite:   an invite from the Supabase Dashboard or inviteUserByEmail.
//             (The Users page does not come through here: generate-invite-link
//             sends its own mail.)
// The app uses no other Auth e-mails (sign-up, magic link, e-mail change);
// those are refused with a clear error rather than sent as a wrong mail.
//
// Deployed with verify_jwt = false: Supabase Auth does not send a user JWT.
// Instead every request is signed (Standard Webhooks); the secret Supabase
// shows when the hook is created goes into the Edge Function secret
// SEND_EMAIL_HOOK_SECRET (format "v1,whsec_...").

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { Webhook } from "https://esm.sh/standardwebhooks@1.0.0";
import { sendLoggedMail } from "../_shared/graph-mail.ts";
import { acceptLink, inviteEmail, passwordResetEmail } from "../_shared/email-templates.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const HOOK_SECRET = (Deno.env.get("SEND_EMAIL_HOOK_SECRET") ?? "").replace("v1,whsec_", "");

type HookPayload = {
  user: { id: string; email: string; user_metadata?: Record<string, unknown> };
  email_data: { token_hash: string; email_action_type: string; redirect_to?: string };
};

serve(async (req) => {
  if (req.method !== "POST") return hookError(405, "Method not allowed");
  if (!HOOK_SECRET) return hookError(500, "Send Email Hook secret is not configured");

  let payload: HookPayload;
  try {
    const raw = await req.text();
    payload = new Webhook(HOOK_SECRET).verify(raw, Object.fromEntries(req.headers)) as HookPayload;
  } catch (_) {
    return hookError(401, "Invalid hook signature");
  }

  const { user, email_data: data } = payload;
  const adminClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  // Name as on the Users page; a brand-new invite has it only in the metadata.
  const { data: row } = await adminClient.from("users").select("name").eq("id", user.id).maybeSingle();
  const name = row?.name ?? (user.user_metadata?.name as string | undefined) ?? null;

  let mail: { subject: string; html: string };
  let type: "invite" | "password_reset";
  switch (data.email_action_type) {
    case "recovery":
      mail = passwordResetEmail(acceptLink(data.token_hash, "recovery"), name);
      type = "password_reset";
      break;
    case "invite":
      mail = inviteEmail(acceptLink(data.token_hash, "invite"), name ?? "there", "An administrator at Jopen Brouwerij");
      type = "invite";
      break;
    default:
      console.error("Unsupported auth e-mail type", data.email_action_type);
      return hookError(400, `E-mail type "${data.email_action_type}" is not used by this app`);
  }

  try {
    await sendLoggedMail(adminClient, { to: [{ email: user.email, name }], ...mail }, { type, sentBy: null });
  } catch (err) {
    return hookError(500, (err as Error).message);
  }
  return new Response(JSON.stringify({}), { status: 200, headers: { "Content-Type": "application/json" } });
});

// Error shape Supabase Auth expects from a hook; it is passed on to the client.
function hookError(status: number, message: string) {
  return new Response(JSON.stringify({ error: { http_code: status, message } }), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
