// ============================================================================
// nav.js — gedeelde navigatiebalk
//
// Vereist op de pagina:
//   1. supabase-js + config.js al geladen (zie config.js voor volgorde)
//   2. Een leeg element ergens in de <body>:  <div id="jopen-nav"></div>
//
// Nieuwe module toevoegen? Voeg 'm hieronder toe aan JOPEN_MODULES — hij
// verschijnt dan automatisch in de navigatiebalk van elke pagina.
// ============================================================================

// Pagina's die iedereen (ook uitgelogd) moet kunnen bereiken -- anders kan
// niemand ooit meer inloggen of een uitnodiging accepteren.
const JOPEN_PUBLIEKE_PAGINAS = ['login.html', 'accept-invite.html'];

// Meteen (synchroon, dus vóór er ook maar iets van de rest van de pagina
// zichtbaar wordt) een overlay tonen die de hele pagina afdekt, op de
// publieke pagina's na. Wordt pas weer weggehaald zodra vereisIngelogd()
// bevestigt dat er een sessie is -- bij geen sessie blijft de overlay
// gewoon staan terwijl de pagina naar login.html doorstuurt.
if (!JOPEN_PUBLIEKE_PAGINAS.includes(window.location.pathname.split('/').pop())) {
  const overlay = document.createElement('div');
  overlay.id = 'jopen-auth-overlay';
  overlay.style.cssText = 'position:fixed; inset:0; background:#f4f4f2; z-index:99999;';
  document.documentElement.appendChild(overlay);
}

// Zelfde indeling als de homepage-tegels (index.html), zodat de navigatiebalk
// niet blijft groeien met losse links naarmate er modules bijkomen. Nieuwe
// module toevoegen? Voeg 'm toe aan de juiste groep hieronder (of maak een
// nieuwe groep als het ergens anders bij hoort) -- verschijnt dan automatisch
// als item in de bijbehorende dropdown.
// moduleKey koppelt een nav-item aan een rij in permission_modules, zodat
// renderNav() 'm kan verbergen als de rol van de gebruiker geen "can_view"
// heeft voor die module. Items zonder moduleKey worden nooit verborgen.
const JOPEN_MODULE_GROEPEN = [
  { naam: 'Batches', items: [
      { naam: 'Batch Creation', href: 'batchcreation.html', moduleKey: 'batches' },
  ]},
  { naam: 'Planning', items: [
      { naam: 'Brewing planning', href: 'brouwplanning.html', moduleKey: 'brewing_planning' },
      { naam: 'Consumption forecast', href: 'verbruiksprognose.html', moduleKey: 'brewing_planning' },
  ]},
  { naam: 'Databases', items: [
      { naam: 'Recipes', href: 'receptoverzicht.html', moduleKey: 'recipes' },
      { naam: 'Ingredients', href: 'ingredienten.html', moduleKey: 'ingredients' },
  ]},
  { naam: 'Inventory', items: [
      { naam: 'Inventory', href: 'voorraad.html', moduleKey: 'inventory' },
  ]},
  { naam: 'Configuration', items: [
      { naam: 'Settings', href: 'settings.html', moduleKey: 'settings' },
  ]},
];

// Users, User Roles en Status blijven hardcoded admin-only (account-achtig
// van aard / beheert de rechten zelf, dus bewust GEEN permission_modules-rij
// die instelbaar is -- zie ook rollen.html, dat User Management en Role
// Management zelf ook altijd als vergrendeld toont).
const JOPEN_ADMIN_PAGINAS = [
  { naam: 'Users', href: 'gebruikers.html' },
  { naam: 'User Roles', href: 'rollen.html' },
  { naam: 'Status', href: 'status.html' },
];

// Interne (snake_case) rolnaam -> leesbaar label, zelfde principe als
// statusLabel()/locatieLabel() elders in de app.
const JOPEN_ROL_LABELS = { admin: 'Admin', head_brewer: 'Head brewer', brewer: 'Brewer', planner: 'Planner', qa: 'QA', viewer: 'Viewer' };
function rolLabel(rol) { return JOPEN_ROL_LABELS[rol] || rol; }

// Rechten van de huidige gebruiker, per module_key: {view, edit, delete}.
// Admin krijgt dit hardcoded (nooit via de tabel) zodat een fout in
// role_permissions een admin nooit buiten zijn eigen systeem kan sluiten.
let _jopenRechtenCache = null;
async function jopenHaalRechten() {
  if (_jopenRechtenCache) return _jopenRechtenCache;
  const gebruiker = await getHuidigeGebruiker();
  if (!gebruiker) { _jopenRechtenCache = {}; return _jopenRechtenCache; }

  if (gebruiker.rol === 'admin') {
    const { data: modules } = await supabaseClient.from('permission_modules').select('module_key');
    const alles = {};
    (modules || []).forEach(m => { alles[m.module_key] = { view: true, edit: true, delete: true }; });
    _jopenRechtenCache = alles;
    return _jopenRechtenCache;
  }

  const { data: rolRij } = await supabaseClient.from('roles').select('id').eq('naam', gebruiker.rol).maybeSingle();
  if (!rolRij) { _jopenRechtenCache = {}; return _jopenRechtenCache; }

  const { data } = await supabaseClient
    .from('role_permissions')
    .select('module_key, can_view, can_edit, can_delete')
    .eq('role_id', rolRij.id);

  const rechten = {};
  (data || []).forEach(r => { rechten[r.module_key] = { view: r.can_view, edit: r.can_edit, delete: r.can_delete }; });
  _jopenRechtenCache = rechten;
  return _jopenRechtenCache;
}

// Cache leegmaken bij het (opnieuw) inloggen, zodat een andere gebruiker op
// hetzelfde apparaat niet de rechten van de vorige gebruiker meekrijgt.
function jopenWisRechtenCache() { _jopenRechtenCache = null; }

async function magBekijkenModule(moduleKey) { const r = await jopenHaalRechten(); return !!(r[moduleKey] && r[moduleKey].view); }
async function magBewerkenModule(moduleKey) { const r = await jopenHaalRechten(); return !!(r[moduleKey] && r[moduleKey].edit); }
async function magVerwijderenModule(moduleKey) { const r = await jopenHaalRechten(); return !!(r[moduleKey] && r[moduleKey].delete); }

/**
 * Stuurt direct door naar login.html als er geen ingelogde gebruiker is,
 * behalve op de paar pagina's die per definitie ook zonder login bereikbaar
 * moeten zijn. Haalt anders de overlay hierboven weer weg.
 *
 * Let op: dit is een UX-maatregel, geen beveiligingsgrens op zich -- de
 * daadwerkelijke bescherming van gegevens loopt via RLS-policies in
 * Supabase. Deze check voorkomt alleen dat de pagina's/navigatie zichtbaar
 * zijn zonder in te loggen.
 */
async function vereisIngelogd() {
  const huidigePagina = window.location.pathname.split('/').pop();
  if (JOPEN_PUBLIEKE_PAGINAS.includes(huidigePagina)) return true;

  const gebruiker = await getHuidigeGebruiker();
  if (!gebruiker) {
    const terugNaar = encodeURIComponent(huidigePagina + window.location.search);
    window.location.replace(`login.html?redirect=${terugNaar}`);
    return false;
  }
  const overlay = document.getElementById('jopen-auth-overlay');
  if (overlay) overlay.remove();
  return true;
}

async function renderNav(huidigeGebruiker) {
  const container = document.getElementById('jopen-nav');
  if (!container) return;

  const huidigePagina = window.location.pathname.split('/').pop();
  const isAdmin = huidigeGebruiker?.rol === 'admin';
  const rechten = huidigeGebruiker ? await jopenHaalRechten() : {};

  // Groepen filteren op zichtbare items (can_view voor de moduleKey, of geen
  // moduleKey -- die worden nooit verborgen), en lege groepen weglaten.
  const zichtbareGroepen = JOPEN_MODULE_GROEPEN
    .map(groep => ({ ...groep, items: groep.items.filter(m => !m.moduleKey || (rechten[m.moduleKey] && rechten[m.moduleKey].view)) }))
    .filter(groep => groep.items.length > 0);

  const categorieenHtml = zichtbareGroepen.map((groep, i) => {
    const bevatActieve = groep.items.some(m => m.href === huidigePagina);
    const itemsHtml = groep.items.map(m => {
      const isActief = m.href === huidigePagina;
      return `<a href="${m.href}" class="jopen-nav-dropdown-item${isActief ? ' actief' : ''}">${m.naam}</a>`;
    }).join('');
    return `
      <div class="jopen-nav-categorie-wrap">
        <button type="button" class="jopen-nav-categorie-btn${bevatActieve ? ' actief' : ''}" data-categorie-idx="${i}">
          ${groep.naam} <span class="jopen-nav-categorie-caret">&#9662;</span>
        </button>
        <div class="jopen-nav-dropdown jopen-nav-categorie-menu" data-categorie-idx="${i}" style="display:none;">
          ${itemsHtml}
        </div>
      </div>`;
  }).join('');

  const adminLinksHtml = isAdmin
    ? JOPEN_ADMIN_PAGINAS.map(m => {
        const isActief = m.href === huidigePagina;
        return `<a href="${m.href}" class="jopen-nav-dropdown-item${isActief ? ' actief' : ''}">${m.naam}</a>`;
      }).join('')
    : '';

  const rechterkant = huidigeGebruiker
    ? `<div class="jopen-nav-gebruiker-wrap">
         <button id="jopen-gebruiker-btn" class="jopen-nav-gebruiker-btn">
           ${escapeHtmlNav(huidigeGebruiker.naam)} <span class="jopen-nav-rol">(${escapeHtmlNav(rolLabel(huidigeGebruiker.rol))})</span>
           <span class="jopen-nav-caret">&#9662;</span>
         </button>
         <div id="jopen-gebruiker-menu" class="jopen-nav-dropdown" style="display:none;">
           ${adminLinksHtml}
           ${adminLinksHtml ? '<div class="jopen-nav-dropdown-divider"></div>' : ''}
           <button id="jopen-uitloggen-btn" class="jopen-nav-dropdown-item">Log out</button>
         </div>
       </div>`
    : `<a href="login.html" class="jopen-nav-link">Log in</a>`;

  container.innerHTML = `
    <nav class="jopen-nav">
      <a href="index.html" class="jopen-nav-merk" style="text-decoration:none; color:inherit;">
        <span class="jopen-nav-logo-wrap"><img src="jopen-logo.png" alt="Jopen" class="jopen-nav-logo" /></span>
        Jopen
      </a>
      <div class="jopen-nav-links">${categorieenHtml}</div>
      <div class="jopen-nav-rechts">${rechterkant}</div>
    </nav>
  `;

  const uitlogBtn = document.getElementById('jopen-uitloggen-btn');
  if (uitlogBtn) uitlogBtn.addEventListener('click', uitloggen);

  // Alle open dropdowns (categorieën + gebruikersmenu) sluiten, op een
  // eventuele uitzondering na -- gebruikt bij het openen van een nieuwe.
  function sluitAlleMenus(exceptEl) {
    document.querySelectorAll('.jopen-nav-categorie-menu').forEach(menu => {
      if (menu !== exceptEl) menu.style.display = 'none';
    });
    const gebruikerMenu = document.getElementById('jopen-gebruiker-menu');
    if (gebruikerMenu && gebruikerMenu !== exceptEl) gebruikerMenu.style.display = 'none';
  }

  container.querySelectorAll('.jopen-nav-categorie-btn').forEach(btn => {
    const idx = btn.dataset.categorieIdx;
    const menu = container.querySelector(`.jopen-nav-categorie-menu[data-categorie-idx="${idx}"]`);
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      const wasOpen = menu.style.display !== 'none';
      sluitAlleMenus();
      menu.style.display = wasOpen ? 'none' : 'block';
    });
  });

  const gebruikerBtn = document.getElementById('jopen-gebruiker-btn');
  const gebruikerMenu = document.getElementById('jopen-gebruiker-menu');
  if (gebruikerBtn && gebruikerMenu) {
    gebruikerBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      const wasOpen = gebruikerMenu.style.display !== 'none';
      sluitAlleMenus();
      gebruikerMenu.style.display = wasOpen ? 'none' : 'block';
    });
  }

  document.addEventListener('click', () => sluitAlleMenus());
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') sluitAlleMenus();
  });
}

function escapeHtmlNav(str) {
  const div = document.createElement('div');
  div.textContent = str ?? '';
  return div.innerHTML;
}

async function initJopenNav() {
  const magDoorgaan = await vereisIngelogd();
  if (!magDoorgaan) return; // pagina stuurt door naar login.html, verder niets doen

  const gebruiker = await getHuidigeGebruiker();
  await renderNav(gebruiker);

  onAuthChange(async () => {
    jopenWisRechtenCache();
    const opnieuw = await getHuidigeGebruiker();
    await renderNav(opnieuw);
  });
}

document.addEventListener('DOMContentLoaded', initJopenNav);
