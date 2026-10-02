# Backup & restore — Jopen Batch Database

Supabase maakt op het **Free plan geen eigen backups**. Alles hieronder is
dus het enige vangnet. Bewaar deze handleiding ergens waar je ook bij kunt
als de app zelf onbereikbaar is.

## Wat wordt er gebackupt

| Wat | Waar | Hoe vaak | Bewaard |
|---|---|---|---|
| Onze tabellen (`public`) | `Jopen_Database_Backup` → `dumps/jopen_backup_<datum>.dump` | elke nacht | 30 dagen in de map, ouder via git-historie |
| Gebruikersaccounts (`auth.users`, `auth.identities`) | `Jopen_Database_Backup` → `dumps/jopen_auth_<datum>.dump` | elke nacht | idem |
| Rij-aantallen per tabel | `Jopen_Database_Backup` → `manifests/jopen_backup_<datum>.json` | elke nacht | idem |
| Storage-bestanden (alle buckets) | `Jopen_Storage_Backup` → `bestanden/<bucket>/<pad>` | elke nacht, alleen wijzigingen | huidige stand in de map, oude/verwijderde versies via git-historie |

**Niet** in de backup: Edge Functions (staan als code in deze repo onder
`supabase/functions/`), project-instellingen in het Dashboard (Auth-instellingen,
Redirect URLs, secrets van Edge Functions) en de inhoud van andere
Supabase-schema's (`storage`, `realtime`, …) die bij een nieuw project vanzelf
weer bestaan.

## Hoe weet ik dat het werkt

- **Elke nacht** wordt de dump direct proef-teruggezet in een wegwerp-Postgres
  en wordt het aantal rijen per tabel vergeleken met productie. Kan de backup
  niet worden teruggezet, dan wordt de run **rood** (de dump wordt dan wél
  bewaard).
- **Elke maandag** haalt de workflow *Restore test* de nieuwste backup op uit
  de backup-repo (zoals je dat in een noodsituatie ook zou doen), zet hem
  terug en vergelijkt met het manifest.
- Een mislukte geplande run levert een mail op aan degene die het laatst de
  `cron`-regel in de workflow heeft aangepast. Kijk anders af en toe in de
  **Actions**-tab.

## Noodrestore naar een nieuw Supabase-project

Getest tegen een nagebootst Supabase-project (oktober 2026). Doe dit nooit
tegen een project dat nog in gebruik is.

1. **Nieuw project aanmaken** in het Supabase Dashboard (regio eu-central-1).
   Noteer het databasewachtwoord.
2. **Backup ophalen.** Clone `Jopen_Database_Backup` en kies de datum
   (meestal de nieuwste). Je hebt `pg_restore` versie 17 nodig.
3. **Connectionstring** van het nieuwe project: Project Settings → Database →
   Connection string → *Session pooler*. Hieronder `$DB`.
4. **Gebruikers terugzetten — in deze volgorde** (de tabellen bestaan al in
   een nieuw project, dus `--data-only`; eerst `users`, dan `identities`,
   anders faalt de foreign key):

   ```bash
   pg_restore --data-only --no-owner --no-privileges --exit-on-error \
     -n auth -t users      -d "$DB" dumps/jopen_auth_<datum>.dump
   pg_restore --data-only --no-owner --no-privileges --exit-on-error \
     -n auth -t identities -d "$DB" dumps/jopen_auth_<datum>.dump
   ```

5. **Onze tabellen terugzetten** (de regel `SCHEMA - public` wordt eruit
   gefilterd, want dat schema bestaat al):

   ```bash
   pg_restore -l dumps/jopen_backup_<datum>.dump | grep -v ' SCHEMA - public ' > lijst.txt
   pg_restore --no-owner --no-privileges --exit-on-error \
     -L lijst.txt -d "$DB" dumps/jopen_backup_<datum>.dump
   ```

6. **Controleren**: draai `.github/backup/tel_rijen.sql` tegen het nieuwe
   project en vergelijk met `manifests/jopen_backup_<datum>.json`
   (of: `python3 .github/backup/vergelijk_tellingen.py test --manifest … --hersteld …`).
7. **Storage-bestanden terugzetten**: maak in het nieuwe project dezelfde
   buckets aan (`ingredient-documents` privé, `Jopen art` publiek) en upload
   de inhoud van `Jopen_Storage_Backup/bestanden/<bucket>/` met behoud van de
   mapstructuur (paden moeten gelijk blijven, de database verwijst ernaar).
8. **App omzetten**: nieuwe URL en anon key in `config.js`, Edge Functions
   opnieuw deployen, Auth → URL Configuration (Site URL + Redirect URLs
   inclusief `accept-invite.html`) opnieuw instellen, secrets van de
   workflows bijwerken.

Gebruikers kunnen daarna met hun bestaande wachtwoord inloggen (de hashes
zitten in de auth-dump).

## Eén bestand of een oude versie terughalen

- **Database**: zet de dump van de gewenste datum terug in een *los*
  testproject (of lokale Postgres) en kopieer alleen de benodigde rijen terug.
  Dumps ouder dan 30 dagen: `git log -- dumps/` in de backup-repo en het
  bestand uit die commit halen.
- **Storage-bestand**: in `Jopen_Storage_Backup` via de GitHub-historie van
  het bestand (*History* → oude versie → *Download raw*). Ook verwijderde
  bestanden zijn zo terug te vinden.

## Instellen (eenmalig)

Secrets in deze repo (Settings → Secrets and variables → Actions):

| Secret | Inhoud |
|---|---|
| `SUPABASE_DB_URL` | Session pooler connectionstring met wachtwoord |
| `BACKUP_REPO_PAT` | fine-grained PAT, *Contents: Read and write* op **beide** backup-repo's |
| `BACKUP_REPO` | `Jopen-Bier/Jopen_Database_Backup` |
| `STORAGE_BACKUP_REPO` | `Jopen-Bier/Jopen_Storage_Backup` |
| `SUPABASE_SERVICE_ROLE_KEY` | service_role key (Project Settings → API). Geheim houden: geeft volledige toegang. |

Zolang `STORAGE_BACKUP_REPO` of `SUPABASE_SERVICE_ROLE_KEY` ontbreekt, slaat de
storage-backup zichzelf over (melding in de run).

## Groei in de gaten houden

- Database-dumps: ~0,7 MB per dag. De git-historie bewaart alles, dus de
  backup-repo groeit met ~250 MB per jaar. Prima voor GitHub; boven ~1 GB
  is het tijd om de historie op te schonen of te archiveren.
- Storage: alleen écht gewijzigde bestanden kosten extra ruimte (dezelfde
  inhoud wordt door git maar één keer opgeslagen). De workflow waarschuwt
  boven 1 GB. Bestanden > 95 MB worden overgeslagen (GitHub-limiet) met een
  waarschuwing.
