#!/usr/bin/env python3
"""Vergelijkt rij-tellingen (uitvoer van tel_rijen.sql) en schrijft/controleert
het backup-manifest.

Twee manieren van gebruik:

1) Nachtelijke backup: controleer dat de teruggezette kopie overeenkomt met
   productie, en schrijf het manifest.

     vergelijk_tellingen.py nacht --voor voor.json --na na.json \
         --hersteld hersteld.json --manifest manifest.json --datum 2026-10-02

   Productie wordt vlak vóór én vlak ná de dump geteld. Voor een tabel die in
   die tussentijd niet veranderd is, MOET de teruggezette kopie exact
   hetzelfde aantal rijen hebben. Is een tabel tijdens de dump wel gewijzigd
   (iemand werkt om 05:00), dan is alleen een waarschuwing mogelijk: de dump
   is een momentopname daar ergens tussenin.

2) Wekelijkse restore-test: controleer een teruggezette backup tegen het
   manifest dat bij die backup hoort. Hier moet alles exact kloppen.

     vergelijk_tellingen.py test --manifest manifest.json --hersteld hersteld.json

Exit-code 1 bij een echte afwijking, zodat de workflow rood wordt.
"""
import argparse
import datetime as dt
import json
import os
import sys


def lees(pad):
    with open(pad, encoding="utf-8") as f:
        tekst = f.read().strip()
    if not tekst:
        raise SystemExit(f"Leeg tellingenbestand: {pad}")
    return json.loads(tekst)


def samenvatting(regels, titel):
    pad = os.environ.get("GITHUB_STEP_SUMMARY")
    tekst = [f"### {titel}", "", "| Tabel | Verwacht | Teruggezet | Status |",
             "|---|---:|---:|---|"]
    tekst += [f"| {t} | {v} | {h} | {s} |" for t, v, h, s in regels]
    tekst.append("")
    if pad:
        with open(pad, "a", encoding="utf-8") as f:
            f.write("\n".join(tekst) + "\n")
    else:
        print("\n".join(tekst))


def nacht(args):
    voor, na, hersteld = lees(args.voor), lees(args.na), lees(args.hersteld)
    fouten, waarschuwingen, regels = [], [], []

    for tabel in sorted(set(voor) | set(na) | set(hersteld)):
        v, n, h = voor.get(tabel), na.get(tabel), hersteld.get(tabel)
        if h is None:
            fouten.append(f"{tabel}: ontbreekt in de teruggezette kopie")
            regels.append((tabel, v, "—", "❌ ontbreekt"))
        elif v is None or n is None:
            # Tabel bestond voor of na de dump niet: aangemaakt/verwijderd
            # tijdens de backup. Niet hard te controleren.
            waarschuwingen.append(f"{tabel}: bestond niet zowel vóór als ná de dump")
            regels.append((tabel, v if v is not None else n, h, "⚠️ schema gewijzigd tijdens dump"))
        elif v == n:
            if h == v:
                regels.append((tabel, v, h, "✅"))
            else:
                fouten.append(f"{tabel}: productie {v}, teruggezet {h}")
                regels.append((tabel, v, h, "❌ afwijking"))
        else:
            laag, hoog = min(v, n), max(v, n)
            status = "⚠️ gewijzigd tijdens dump"
            if not (laag <= h <= hoog):
                status += " (buiten bereik)"
            waarschuwingen.append(f"{tabel}: tijdens dump gewijzigd ({v} → {n}), teruggezet {h}")
            regels.append((tabel, f"{v}→{n}", h, status))

    samenvatting(regels, f"Controle backup {args.datum}")

    manifest = {
        "datum": args.datum,
        "gemaakt_op": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "bestanden": {
            "public": f"jopen_backup_{args.datum}.dump",
            "auth": f"jopen_auth_{args.datum}.dump",
        },
        "tellingen": hersteld,
        "waarschuwingen": waarschuwingen,
    }
    with open(args.manifest, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=False, sort_keys=False)
        f.write("\n")

    for w in waarschuwingen:
        print(f"::warning::{w}")
    for fout in fouten:
        print(f"::error::{fout}")
    if fouten:
        print(f"{len(fouten)} afwijking(en): deze backup is NIET betrouwbaar terug te zetten.")
        return 1
    print(f"Backup {args.datum} gecontroleerd: {len(hersteld)} tellingen kloppen"
          + (f", {len(waarschuwingen)} waarschuwing(en)." if waarschuwingen else "."))
    return 0


def test(args):
    manifest, hersteld = lees(args.manifest), lees(args.hersteld)
    verwacht = manifest["tellingen"]
    fouten, regels = [], []
    for tabel in sorted(set(verwacht) | set(hersteld)):
        v, h = verwacht.get(tabel), hersteld.get(tabel)
        if v == h:
            regels.append((tabel, v, h, "✅"))
        else:
            fouten.append(f"{tabel}: manifest {v}, teruggezet {h}")
            regels.append((tabel, v if v is not None else "—",
                           h if h is not None else "—", "❌"))
    samenvatting(regels, f"Restore-test backup {manifest.get('datum', '?')}")
    for fout in fouten:
        print(f"::error::{fout}")
    if fouten:
        return 1
    print(f"Restore-test geslaagd: alle {len(verwacht)} tellingen kloppen met het manifest.")
    return 0


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="modus", required=True)
    pn = sub.add_parser("nacht")
    pn.add_argument("--voor", required=True)
    pn.add_argument("--na", required=True)
    pn.add_argument("--hersteld", required=True)
    pn.add_argument("--manifest", required=True)
    pn.add_argument("--datum", required=True)
    pt = sub.add_parser("test")
    pt.add_argument("--manifest", required=True)
    pt.add_argument("--hersteld", required=True)
    args = p.parse_args()
    return nacht(args) if args.modus == "nacht" else test(args)


if __name__ == "__main__":
    sys.exit(main())
