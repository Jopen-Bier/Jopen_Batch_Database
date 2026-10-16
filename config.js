// ============================================================================
// config.js — gedeelde Supabase-config en auth-helpers
//
// Laden op ELKE pagina, ná de supabase-js CDN-script-tag, en VÓÓR nav.js:
//
//   <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
//   <script src="config.js"></script>
//   <script src="nav.js"></script>
//
// LET OP: vul hieronder je eigen Supabase-project-URL en publishable/anon-key
// in (dezelfde die nu al hardcoded in receptoverzicht.html staan).
// ============================================================================

// TESTFASE: hardcoded credentials, net als voorheen in receptoverzicht.html.
// Verwijder dit zodra dit breder dan alleen jijzelf gebruikt wordt, of zet in
// elk geval RLS-policies aan in Supabase (staat nu nog overal uit).
const SUPABASE_URL = 'https://nrouqtxkeeoayqudkiud.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_ftz3c-3AVlRiYve4Y1V6fQ_hg_BdAm-';

const supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

/**
 * The logged-in user with role information, or `null` when nobody is logged
 * in. Shape: { id, name, roleId, roleName, isActive, isAdmin }.
 */
async function getCurrentUser() {
  const { data: { session } } = await supabaseClient.auth.getSession();
  if (!session) return null;

  const { data, error } = await supabaseClient
    .from('users')
    .select('id, name, is_active, role_id, roles(name)')
    .eq('id', session.user.id)
    .single();

  if (error) {
    console.error('Could not load the current user from the users table:', error);
    // Fall back on session data so the app does not get stuck when the row
    // is missing (e.g. right after an invite). No rights in that case.
    return { id: session.user.id, name: session.user.email, roleId: null, roleName: null, isActive: true, isAdmin: false };
  }
  const roleName = data.roles ? data.roles.name : null;
  return {
    id: data.id,
    name: data.name,
    roleId: data.role_id,
    roleName,
    isActive: data.is_active,
    isAdmin: roleName === 'admin' && data.is_active === true,
  };
}

/** Roept `callback(session)` aan bij inloggen/uitloggen/token-refresh. */
function onAuthChange(callback) {
  supabaseClient.auth.onAuthStateChange((_event, session) => {
    callback(session);
  });
}

async function uitloggen() {
  await supabaseClient.auth.signOut();
  window.location.href = 'index.html';
}
