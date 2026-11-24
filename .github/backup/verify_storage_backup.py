#!/usr/bin/env python3
"""Check that the Storage mirror (Jopen_Storage_Backup) can really be restored.

Security phase 6. Run by the weekly Restore test after cloning the mirror:

  verify_storage_backup.py --mirror storage-repo [--live live.json]

Fails (exit 1) when:
  - a file listed in manifest.json is missing from bestanden/<bucket>/<path>
    or has a different size (the backup would restore a broken file);
  - a file does not start like its type (PDF, PNG, JPEG, Office), i.e. it
    was stored as an error page or truncated;
  - with --live (output of storage_lijst.sql against production): a file
    that exists in Storage and is older than 36 hours is not in the mirror
    (newer files may simply not have been synced yet).
Writes a summary to $GITHUB_STEP_SUMMARY when set.
"""
import argparse
import datetime as dt
import json
import os
import pathlib
import sys

SIGNATURES = {  # file extension -> accepted leading bytes
    ".pdf": [b"%PDF"],
    ".png": [b"\x89PNG"],
    ".jpg": [b"\xff\xd8\xff"], ".jpeg": [b"\xff\xd8\xff"],
    ".docx": [b"PK"], ".xlsx": [b"PK"],
    ".doc": [b"\xd0\xcf\x11\xe0"], ".xls": [b"\xd0\xcf\x11\xe0"],
}
LIVE_GRACE = dt.timedelta(hours=36)


def check(mirror: pathlib.Path, live_path: pathlib.Path | None, now: dt.datetime):
    problems, notes = [], []
    manifest = json.loads((mirror / "manifest.json").read_text(encoding="utf-8"))
    files = manifest.get("bestanden", {})
    checked = 0
    for key, info in files.items():
        bucket, _, name = key.partition("/")
        path = mirror.joinpath("bestanden", bucket, *name.split("/"))
        if not path.is_file():
            problems.append(f"missing in mirror: {key}")
            continue
        size = path.stat().st_size
        if info.get("grootte") is not None and size != info["grootte"]:
            problems.append(f"size differs: {key} (mirror {size}, manifest {info['grootte']})")
            continue
        sigs = SIGNATURES.get(path.suffix.lower())
        if sigs:
            with path.open("rb") as f:
                head = f.read(8)
            if not any(head.startswith(s) for s in sigs):
                problems.append(f"not a valid {path.suffix} file: {key}")
                continue
        checked += 1

    if live_path:
        live = json.loads(live_path.read_text(encoding="utf-8") or "[]") or []
        missing = []
        for obj in live:
            key = f"{obj['bucket']}/{obj['name']}"
            if key in files:
                continue
            updated = dt.datetime.fromisoformat(str(obj.get("updated_at")).replace("Z", "+00:00"))
            if updated.tzinfo is None:
                updated = updated.replace(tzinfo=dt.timezone.utc)
            if now - updated > LIVE_GRACE:
                missing.append(key)
            else:
                notes.append(f"recent, not yet in the mirror: {key}")
        problems += [f"in Storage but not in the mirror: {k}" for k in missing]
        notes.insert(0, f"live Storage objects: {len(live)}")

    total = manifest.get("totale_grootte_bytes") or 0
    summary = (f"Storage mirror: {checked} of {len(files)} files restorable "
               f"({total / 1024 / 1024:.1f} MB), {len(problems)} problem(s)")
    return summary, problems, notes


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mirror", required=True)
    ap.add_argument("--live")
    args = ap.parse_args()
    summary, problems, notes = check(pathlib.Path(args.mirror),
                                     pathlib.Path(args.live) if args.live else None,
                                     dt.datetime.now(dt.timezone.utc))
    print(summary)
    for n in notes:
        print("  " + n)
    for p in problems[:100]:
        print(f"::error::{p}")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as f:
            f.write(f"### Storage restore check\n\n{summary}\n\n")
            for p in problems[:50]:
                f.write(f"- {p}\n")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
