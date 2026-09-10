// supabase/functions/generate-invite-link/index.ts
//
// Doel: dezelfde uitnodiging aanmaken als invite-user (nieuwe auth-user +
// rij in `gebruikers`), maar zonder dat Supabase zelf een e-mail verstuurt.
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
    const { email, naam, rol } = await req.json();
    if (!email || !naam || !rol) {
      return json({ error: "email, naam and rol are all required" }, 400);
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
    const { data: callerRow, error: roleErr } = await adminClient
      .from("gebruikers")
      .select("rol")
      .eq("id", callerData.user.id)
      .single();

    if (roleErr || callerRow?.rol !== "admin") {
      return json({ error: "Only admins can invite new colleagues" }, 403);
    }

    // 3. Uitnodigingslink genereren -- dit maakt de auth-user AL aan, maar
    // stuurt zelf GEEN e-mail (in tegenstelling tot inviteUserByEmail).
    const REDIRECT_TO = "https://jopen-bier.github.io/Jopen_Batch_Database/accept-invite.html";
    const { data: linkData, error: linkErr } = await adminClient.auth.admin.generateLink({
      type: "invite",
      email,
      options: {
        data: { naam, rol },
        redirectTo: REDIRECT_TO,
      },
    });

    if (linkErr || !linkData?.user) {
      return json({ error: `Could not generate invite link: ${linkErr?.message ?? "unknown error"}` }, 500);
    }

    // 4. Rij in `gebruikers` aanmaken, zelfde als invite-user zou doen.
    const { error: insertErr } = await adminClient
      .from("gebruikers")
      .insert({ id: linkData.user.id, naam, rol, actief: true });

    if (insertErr) {
      return json({ error: `Link generated, but could not create gebruikers row: ${insertErr.message}` }, 500);
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

function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
