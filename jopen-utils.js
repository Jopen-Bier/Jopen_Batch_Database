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

if (typeof module !== 'undefined' && module.exports) {
  module.exports = { escapeHtml, fetchAllRows, formatDate, toggleDropdownPanel };
}
