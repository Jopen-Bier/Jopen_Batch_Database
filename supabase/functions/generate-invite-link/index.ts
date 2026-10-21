// supabase/functions/generate-invite-link/index.ts
//
// Doel: dezelfde uitnodiging aanmaken als invite-user (nieuwe auth-user +
// rij in `users`), maar zonder dat Supabase zelf een e-mail verstuurt.
// In plaats daarvan krijg je de kale uitnodigingslink terug, die je zelf
// via je eigen mailprogramma (Outlook e.d.) naar de collega kunt sturen --
// handig zolang er nog geen custom SMTP is en de gratis Supabase-mail-
// service tegen zijn rate limit aanloopt.
//
// Zelfde beveiligingspatroon als invite-user/delete-user: het JWT van de
// aanroeper wordt gecheckt, en pas als die zelf 'admin' is, mag de actie
// doorgaan. De service_role key blijft veilig binnen de function.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const body = await req.json();
    const email: string | undefined = body.email;
    const name: string | undefined = body.name ?? body.naam; // `naam`: pre-2026-10-16 page
    const resendUserId: string | undefined = body.user_id; // new link for an existing account
    // Initials as written on the floor; empty = generated from the name (trigger).
    const initials: string | null = typeof body.initials === "string" && body.initials.trim()
      ? body.initials.trim().toUpperCase().slice(0, 4) : null;
    if (!resendUserId && (!email || !name)) {
      return json({ error: "email and name are required" }, 400);
    }

    // 1. Wie roept dit aan?
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return json({ error: "Not logged in" }, 401);

    const callerClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: callerData, error: callerErr } = await callerClient.auth.getUser();
    if (callerErr || !callerData?.user) {
      return json({ error: "Could not determine logged-in user" }, 401);
    }

    // 2. Is de aanroeper admin?
    const adminClient = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    if (!(await isAdmin(adminClient, callerData.user.id))) {
      return json({ error: "Only admins can invite new colleagues" }, 403);
    }

    const REDIRECT_TO = "https://jopen-bier.github.io/Jopen_Batch_Database/accept-invite.html";

    // New invite link for an account that exists but has never logged in
    // (accounts made ahead, invite sent later: the first link has expired by
    // then). Same own-page link as below; see the note on prefetching there.
    if (resendUserId) {
      const { data: target, error: targetErr } = await adminClient.auth.admin.getUserById(resendUserId);
      if (targetErr || !target?.user?.email) return json({ error: "Unknown user" }, 404);
      if (target.user.last_sign_in_at) {
        return json({ error: "This colleague has already logged in; use \"Forgot password\" on the login page instead" }, 400);
      }
      // An invite link while the account is unconfirmed; once confirmed (an
      // earlier link was opened but no password set) only a recovery link
      // works. accept-invite.html handles both types.
      let type: "invite" | "recovery" = target.user.email_confirmed_at ? "recovery" : "invite";
      let { data: again, error: againErr } = await adminClient.auth.admin.generateLink({
        type, email: target.user.email, options: { redirectTo: REDIRECT_TO },
      });
      if (againErr && type === "invite") {
        type = "recovery";
        ({ data: again, error: againErr } = await adminClient.auth.admin.generateLink({
          type, email: target.user.email, options: { redirectTo: REDIRECT_TO },
        }));
      }
      if (againErr || !again?.properties?.hashed_token) {
        return json({ error: `Could not generate invite link: ${againErr?.message ?? "unknown error"}` }, 500);
      }
      const link = `${REDIRECT_TO}?token_hash=${encodeURIComponent(again.properties.hashed_token)}&type=${type}`;
      return json({ success: true, action_link: link, email: target.user.email }, 200);
    }

    // Role: role_id (current page) or a role name (pre-2026-10-16 page).
    let roleId: number | null = body.role_id ? Number(body.role_id) : null;
    if (!roleId && body.rol) {
      const { data: r } = await adminClient.from("roles").select("id").eq("name", body.rol).maybeSingle();
      roleId = r?.id ?? null;
    }
    if (!roleId) return json({ error: "A valid role is required" }, 400);
    const { data: roleRow } = await adminClient.from("roles").select("id, name").eq("id", roleId).maybeSingle();
    if (!roleRow) return json({ error: `Unknown role id ${roleId}` }, 400);

    // 3. Uitnodigingslink genereren -- dit maakt de auth-user AL aan, maar
    // stuurt zelf GEEN e-mail (in tegenstelling tot inviteUserByEmail).
    const { data: linkData, error: linkErr } = await adminClient.auth.admin.generateLink({
      type: "invite",
      email,
      options: {
        data: { name, role: roleRow.name },
        redirectTo: REDIRECT_TO,
      },
    });

    if (linkErr || !linkData?.user) {
      return json({ error: `Could not generate invite link: ${linkErr?.message ?? "unknown error"}` }, 500);
    }

    // 4. Rij in `users` aanmaken, zelfde als invite-user zou doen.
    const { error: insertErr } = await adminClient
      .from("users")
      .insert({ id: linkData.user.id, name, role_id: roleRow.id, is_active: true, initials: initials || null });

    if (insertErr) {
      return json({ error: `Link generated, but could not create users row: ${insertErr.message}` }, 500);
    }

    // BELANGRIJK: we sturen bewust NIET linkData.properties.action_link mee.
    // Die link wijst rechtstreeks naar Supabase's eigen `/auth/v1/verify`-
    // endpoint, en een kale GET daarop verbruikt de eenmalige token meteen --
    // ook als die GET niet van de echte ontvanger komt. Bedrijfsmail-scanners
    // (bv. Microsoft Defender Safe Links, Barracuda) doen precies dat: ze
    // "prefetchen" elke link uit een binnenkomende mail om 'm te scannen,
    // vóórdat de mens 'm ooit ziet. Vandaar dat de link voor de ontvanger
    // steevast al "verlopen" leek, terwijl hij bij de afzender (die de link
    // als eerste zelf opent/test) gewoon werkte. Dit is een door Supabase
    // zelf gedocumenteerde beperking, zie:
    // https://supabase.com/docs/guides/auth/auth-email-templates#email-prefetching
    //
    // Oplossing: we bouwen zelf een link naar ONZE eigen accept-invite.html
    // met de token_hash als query-param. Een scanner die alleen de pagina
    // ophaalt (geen JS uitvoert) verbruikt de token niet -- pas
    // accept-invite.html zelf wisselt 'm client-side in via verifyOtp().
    const eigenLink = `${REDIRECT_TO}?token_hash=${encodeURIComponent(linkData.properties.hashed_token)}&type=invite`;

    return json({ success: true, action_link: eigenLink }, 200);
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});

// True when the given auth user is an active user with the role 'admin'.
// deno-lint-ignore no-explicit-any
async function isAdmin(client: any, userId: string): Promise<boolean> {
  const { data, error } = await client
    .from("users")
    .select("is_active, roles(name)")
    .eq("id", userId)
    .single();
  return !error && data?.is_active === true && data?.roles?.name === "admin";
}

function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
