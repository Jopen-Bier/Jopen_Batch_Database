// ============================================================================
// jopen-utils.js — shared generic helpers.
//
// Load on EVERY page, after config.js and before nav.js:
//
//   <script src="config.js"></script>
//   <script src="jopen-utils.js"></script>
//   <script src="nav.js"></script>
//
// Rule (see CLAUDE.md / ARCHITECTURE.md): a generic helper that a second page
// needs lives here — never copy it into a page. Domain calculations get their
// own module with a test (like waterzouten.js), not this file.
// ============================================================================

/**
 * Escape a value for safe use in HTML text AND in attribute values
 * (value="…", data-x="…"). null/undefined become an empty string.
 */
function escapeHtml(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

/**
 * Fetch all rows of a Supabase query, past the 1000-row limit per request.
 * Pass the query WITHOUT .range(); returns { data, error } like Supabase.
 *
 *   const { data, error } = await fetchAllRows(
 *     supabaseClient.from('recipes').select('id, naam:name').order('id'));
 *
 * Give the query a stable .order(), otherwise pages can overlap or skip rows.
 */
async function fetchAllRows(query, pageSize = 1000) {
  let from = 0;
  let rows = [];
  while (true) {
    const { data, error } = await query.range(from, from + pageSize - 1);
    if (error) return { data: null, error };
    rows = rows.concat(data || []);
    if (!data || data.length < pageSize) break;
    from += pageSize;
  }
  return { data: rows, error: null };
}

/** Date for display, e.g. "16 Oct 2026". Empty value → "—". */
function formatDate(value) {
  if (!value) return '—';
  return new Date(value).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' });
}

/**
 * Open/close a filter dropdown with id `dd-<prefix>-panel` and its button
 * `dd-<prefix>-btn`. Opening one closes all other `.dd-filter-panel`s.
 */
function toggleDropdownPanel(prefix) {
  const panel = document.getElementById(`dd-${prefix}-panel`);
  const wasOpen = panel.style.display !== 'none';
  document.querySelectorAll('.dd-filter-panel').forEach((p) => { p.style.display = 'none'; });
  document.querySelectorAll('.dd-filter-btn').forEach((b) => b.classList.remove('actief-menu'));
  if (!wasOpen) {
    panel.style.display = 'block';
    document.getElementById(`dd-${prefix}-btn`).classList.add('actief-menu');
  }
}

/**
 * Copies formatted text (with a plain-text fallback) to the clipboard, for
 * pasting into an e-mail. Resolves true when it worked.
 */
async function copyRichText(html, text) {
  try {
    await navigator.clipboard.write([new ClipboardItem({
      'text/html': new Blob([html], { type: 'text/html' }),
      'text/plain': new Blob([text], { type: 'text/plain' }),
    })]);
    return true;
  } catch (e) {
    return false;
  }
}

/**
 * Code for a new row from its label, for the `code` columns of reference
 * tables (check '^[a-z0-9_]+$'): 'Dry hop @2 °C' -> 'dry_hop_2_c'.
 * Empty when the label has no letters or digits.
 */
function codeFromLabel(label) {
  return String(label ?? '').toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '')
    .replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '');
}

/**
 * True when the password appears in a known data breach (Have I Been Pwned,
 * k-anonymity range API: only the first 5 characters of the SHA-1 hash leave
 * the browser, never the password). Free stand-in for Supabase's leaked-
 * password protection, which needs a paid plan (security phase 5).
 * Returns false when the check cannot be done (offline, API down): the
 * password is then judged on the other rules only.
 */
async function isPasswordPwned(password, fetchFn = (typeof fetch !== 'undefined' ? fetch : null)) {
  try {
    if (!password || !fetchFn) return false;
    const bytes = await crypto.subtle.digest('SHA-1', new TextEncoder().encode(password));
    const hash = Array.from(new Uint8Array(bytes)).map(b => b.toString(16).padStart(2, '0')).join('').toUpperCase();
    const res = await fetchFn(`https://api.pwnedpasswords.com/range/${hash.slice(0, 5)}`, { headers: { 'Add-Padding': 'true' } });
    if (!res.ok) return false;
    const suffix = hash.slice(5);
    return (await res.text()).split('\n').some(line => {
      const [rest, count] = line.trim().split(':');
      return rest === suffix && Number(count) > 0;
    });
  } catch (e) {
    return false;
  }
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = { escapeHtml, fetchAllRows, formatDate, toggleDropdownPanel, copyRichText, codeFromLabel, isPasswordPwned };
}
