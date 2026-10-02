#!/usr/bin/env python3
"""Spiegelt alle Supabase Storage-buckets incrementeel naar een map (de
werkmap van de aparte backup-repo Jopen_Storage_Backup).

    storage_sync.py --lijst objecten.json --doel <map>

--lijst is de uitvoer van storage_lijst.sql (alle objecten uit
storage.objects, met grootte/eTag/updated_at). Die komt rechtstreeks uit de
database, dus er wordt niets gemist door paginering van de Storage API.

Werkwijze:
  * <doel>/manifest.json onthoudt per bestand (bucket/pad) de grootte, eTag
    en updated_at van de laatst gedownloade versie.
  * Alleen nieuwe of gewijzigde bestanden worden gedownload.
  * Zelfde pad = overschrijven. Er ontstaan dus nooit dubbele kopieën;
    eerdere versies blijven terug te halen via de git-historie.
  * Een bestand dat in de app verwijderd is, verdwijnt ook uit de spiegel
    (en blijft via de git-historie terug te halen).
  * Bestanden > 95 MB worden overgeslagen met een waarschuwing: GitHub
    weigert losse bestanden boven 100 MB.

Omgevingsvariabelen: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY.
Exit-code 1 als er downloads mislukt zijn (die worden de volgende nacht
opnieuw geprobeerd, de rest wordt gewoon bewaard).
"""
import argparse
import json
import os
import pathlib
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

MAX_BYTES = 95 * 1024 * 1024
WAARSCHUW_TOTAAL = 1024 * 1024 * 1024  # 1 GB


def veilig_pad(doel: pathlib.Path, bucket: str, naam: str) -> pathlib.Path:
    delen = [bucket] + naam.split("/")
    if any(d in ("", ".", "..") for d in delen):
        raise ValueError(f"Onveilig pad overgeslagen: {bucket}/{naam}")
    pad = doel.joinpath("bestanden", *delen)
    if pathlib.Path(os.path.commonpath([pad.resolve(), doel.resolve()])) != doel.resolve():
        raise ValueError(f"Pad buiten doelmap overgeslagen: {bucket}/{naam}")
    return pad


def download(url_basis, sleutel, bucket, naam, pad: pathlib.Path):
    quoted = "/".join(urllib.parse.quote(d, safe="") for d in [bucket] + naam.split("/"))
    req = urllib.request.Request(
        f"{url_basis}/storage/v1/object/authenticated/{quoted}",
        headers={"Authorization": f"Bearer {sleutel}", "apikey": sleutel},
    )
    pad.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=pad.parent, prefix=".download-")
    try:
        with urllib.request.urlopen(req, timeout=120) as resp, os.fdopen(fd, "wb") as f:
            while True:
                blok = resp.read(1024 * 1024)
                if not blok:
                    break
                f.write(blok)
        os.replace(tmp, pad)  # pas overschrijven als de download compleet is
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def ruim_lege_mappen_op(basis: pathlib.Path):
    if not basis.exists():
        return
    for map_ in sorted((p for p in basis.rglob("*") if p.is_dir()),
                       key=lambda p: len(p.parts), reverse=True):
        if not any(map_.iterdir()):
            map_.rmdir()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lijst", required=True)
    ap.add_argument("--doel", required=True)
    ap.add_argument("--samenvatting", help="bestand voor de commit-boodschap (buiten de repo)")
    args = ap.parse_args()

    url_basis = os.environ["SUPABASE_URL"].rstrip("/")
    sleutel = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
    doel = pathlib.Path(args.doel)
    manifest_pad = doel / "manifest.json"

    oud = json.loads(manifest_pad.read_text(encoding="utf-8")) if manifest_pad.exists() else {}
    oud_bestanden = oud.get("bestanden", {})

    tekst = pathlib.Path(args.lijst).read_text(encoding="utf-8").strip()
    objecten = json.loads(tekst) if tekst and tekst != "null" else []

    nieuw, toegevoegd, gewijzigd, overgeslagen, mislukt = {}, [], [], [], []
    for obj in objecten:
        sleutel_pad = f"{obj['bucket']}/{obj['name']}"
        info = {"grootte": obj.get("size"), "etag": obj.get("etag"),
                "bijgewerkt": obj.get("updated_at")}
        try:
            pad = veilig_pad(doel, obj["bucket"], obj["name"])
        except ValueError as e:
            print(f"::warning::{e}")
            continue

        if (info["grootte"] or 0) > MAX_BYTES:
            overgeslagen.append(sleutel_pad)
            print(f"::warning::Te groot voor git (>95 MB), overgeslagen: {sleutel_pad}")
            if sleutel_pad in oud_bestanden:
                nieuw[sleutel_pad] = oud_bestanden[sleutel_pad]
            continue

        vorige = oud_bestanden.get(sleutel_pad)
        if vorige == info and pad.exists():
            nieuw[sleutel_pad] = info
            continue

        try:
            download(url_basis, sleutel, obj["bucket"], obj["name"], pad)
            nieuw[sleutel_pad] = info
            (gewijzigd if vorige else toegevoegd).append(sleutel_pad)
        except (urllib.error.URLError, OSError) as e:
            mislukt.append(sleutel_pad)
            print(f"::error::Download mislukt voor {sleutel_pad}: {e}")
            if vorige and pad.exists():
                nieuw[sleutel_pad] = vorige  # oude versie blijft staan, volgende nacht opnieuw

    # Verwijderd in de app -> uit de spiegel (blijft in de git-historie)
    verwijderd = []
    for sleutel_pad in sorted(set(oud_bestanden) - set(nieuw)):
        bucket, _, naam = sleutel_pad.partition("/")
        if sleutel_pad in mislukt:
            continue
        try:
            pad = veilig_pad(doel, bucket, naam)
        except ValueError:
            continue
        if pad.exists():
            pad.unlink()
        verwijderd.append(sleutel_pad)
    ruim_lege_mappen_op(doel / "bestanden")

    totaal = sum((v.get("grootte") or 0) for v in nieuw.values())
    manifest = {"aantal_bestanden": len(nieuw), "totale_grootte_bytes": totaal,
                "bestanden": dict(sorted(nieuw.items()))}
    manifest_pad.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
                            encoding="utf-8")

    regel = (f"Storage-sync: {len(nieuw)} bestanden ({totaal / 1024 / 1024:.1f} MB) — "
             f"+{len(toegevoegd)} nieuw, ~{len(gewijzigd)} gewijzigd, -{len(verwijderd)} verwijderd"
             + (f", {len(mislukt)} mislukt" if mislukt else "")
             + (f", {len(overgeslagen)} te groot" if overgeslagen else ""))
    print(regel)
    if args.samenvatting:
        pathlib.Path(args.samenvatting).write_text(regel + "\n", encoding="utf-8")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as f:
            f.write(f"### Storage-backup\n\n{regel}\n\n")
            for titel, lijst in (("Nieuw", toegevoegd), ("Gewijzigd", gewijzigd),
                                 ("Verwijderd", verwijderd), ("Mislukt", mislukt)):
                if lijst:
                    f.write(f"**{titel}:** " + ", ".join(f"`{x}`" for x in lijst[:50])
                            + (" …" if len(lijst) > 50 else "") + "\n\n")
    if totaal > WAARSCHUW_TOTAAL:
        print(f"::warning::De storage-spiegel is groter dan 1 GB ({totaal / 1024**3:.2f} GB). "
              "Tijd om de opslag van de storage-backup te heroverwegen.")
    return 1 if mislukt else 0


if __name__ == "__main__":
    sys.exit(main())
