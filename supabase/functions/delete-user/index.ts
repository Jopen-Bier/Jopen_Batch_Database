// supabase/functions/delete-user/index.ts
//
// Doel: een ADMIN kan een collega volledig verwijderen — zowel uit de eigen
// `users`-tabel als uit Supabase Auth zelf (anders kan iemand nog
// inloggen ook al staat hij niet meer in de rechten-tabel).
//
// Zelfde beveiligingspatroon als invite-user: het JWT van de aanroeper wordt
// gecheckt, en pas als die zelf 'admin' is, mag de actie doorgaan. De
// service_role key blijft veilig binnen de function.

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
    const { user_id } = await req.json();
    if (!user_id) {
      return json({ error: "user_id is required" }, 400);
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
    // Asked of the database with the caller's own session, so the same rules
    // apply as everywhere else: active admin AND two-factor code entered when
    // required (is_admin() / mfa_satisfied(), security phase 5).
    const { data: callerIsAdmin, error: adminErr } = await callerClient.rpc("is_admin");
    if (adminErr || callerIsAdmin !== true) {
      return json({ error: "Only admins can delete users (with their two-factor code entered)" }, 403);
    }

    // 3. Nooit jezelf kunnen verwijderen (voorkomt per ongeluk buitensluiten)
    if (user_id === callerData.user.id) {
      return json({ error: "You cannot delete your own account" }, 400);
    }

    // 4. Verwijder eerst de rij in users, dan de auth-user zelf.
    const { error: deleteRowErr } = await adminClient
      .from("users")
      .delete()
      .eq("id", user_id);

    if (deleteRowErr) {
      return json({ error: `Failed to remove from users table: ${deleteRowErr.message}` }, 500);
    }

    const { error: deleteAuthErr } = await adminClient.auth.admin.deleteUser(user_id);
    if (deleteAuthErr) {
      return json({ error: `Removed from table, but auth deletion failed: ${deleteAuthErr.message}` }, 500);
    }

    return json({ success: true }, 200);
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
