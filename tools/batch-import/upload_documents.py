# Upload the 2026 batch documents (PDFs) from the batch-reports repo into the
# app: private bucket 'batch-documents' + table batch_documents, the same as an
# upload on the Filling report tab (docs/batch-report/import-2026.md).
# Run by the workflow "Upload documents" in Jopen-Bier/batch-reports-2026:
#   python3 -I upload_documents.py <folder> [--run] [--batches 26001,26002] [--by JL]
# Without --run it is a dry run: it only reports what would go where.
# Env: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (a repo secret; never printed).
#
# Names (Jaap, 21-10), batch number anywhere in the file name:
#   ...ProductieBon...  -> production_order
#   ...AfvulOrderBon... -> filling_order
#   av_<batch>...       -> filling_report
#   anything else       -> other
# A batch gets one file per fixed type: a type that already has a file in the
# app is skipped, and two files of one fixed type for a batch are both held
# (reported, not uploaded). An "other" file with the same name is skipped.
import sys, os, re, json, time, argparse, urllib.request, urllib.parse, urllib.error

BUCKET = 'batch-documents'
MAX_BYTES = 20 * 1024 * 1024          # the app's limit (batch-filling-report.html)
EXTENSIONS = {'.pdf': 'application/pdf', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png'}
LABELS = {'production_order': 'Production order', 'filling_order': 'Filling order',
          'filling_report': 'Filling report', 'other': 'Other'}


def classify(name):
    """(batch number, document type) from a file name; batch None if not found."""
    base = os.path.basename(name)
    low = base.lower()
    m = re.search(r'(?<!\d)(2\d{4})(?!\d)', base)
    batch = m.group(1) if m else None
    if 'productiebon' in low:
        kind = 'production_order'
    elif 'afvulorderbon' in low:
        kind = 'filling_order'
    elif low.startswith('av_') or low.startswith('av-') or low.startswith('av '):
        kind = 'filling_report'
    else:
        kind = 'other'
    return batch, kind


def plan(files, batches, existing, only=None):
    """Decide per file: upload / skip / hold, with the reason."""
    rows, by_key = [], {}
    for path, size in files:
        name = os.path.basename(path)
        batch, kind = classify(name)
        row = {'file': path, 'name': name, 'batch': batch, 'type': kind, 'size': size}
        if only and batch not in only:
            continue
        if batch is None:
            row.update(action='hold', reason='no batch number in the file name')
        elif batch not in batches:
            row.update(action='hold', reason=f'batch {batch} is not in the app')
        elif size > MAX_BYTES:
            row.update(action='hold', reason=f'larger than 20 MB ({size / 1048576:.1f} MB)')
        elif kind != 'other' and (batch, kind) in existing['types']:
            row.update(action='skip', reason=f'{LABELS[kind]} already in the app')
        elif kind == 'other' and (batch, name) in existing['names']:
            row.update(action='skip', reason='same file already in the app')
        else:
            row.update(action='upload', reason='')
        rows.append(row)
        if row['action'] == 'upload' and kind != 'other':
            by_key.setdefault((batch, kind), []).append(row)
    for (batch, kind), group in by_key.items():
        if len(group) > 1:
            for row in group:
                row.update(action='hold', reason=f'{len(group)} files for {LABELS[kind]} of {batch}: choose one')
    return rows


class Api:
    def __init__(self, url, key):
        self.url, self.key = url.rstrip('/'), key

    def call(self, method, path, body=None, headers=None, raw=None):
        h = {'apikey': self.key, 'Authorization': f'Bearer {self.key}'}
        h.update(headers or {})
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        if body is not None and raw is None:
            h['Content-Type'] = 'application/json'
        req = urllib.request.Request(self.url + path, data=data, method=method, headers=h)
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                txt = r.read().decode() or 'null'
                return json.loads(txt) if txt.strip().startswith(('[', '{', 'null')) else txt
        except urllib.error.HTTPError as e:
            raise RuntimeError(f'{method} {path.split("?")[0]}: {e.code} {e.read().decode()[:300]}') from None

    def rows(self, table, select, filt=''):
        out, start = [], 0
        while True:
            page = self.call('GET', f'/rest/v1/{table}?select={select}{filt}',
                             headers={'Range-Unit': 'items', 'Range': f'{start}-{start + 999}'})
            out += page
            if len(page) < 1000:
                return out
            start += 1000


def safe(name):
    return re.sub(r'[^a-zA-Z0-9._-]', '_', name)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('folder')
    ap.add_argument('--run', action='store_true', help='upload (default: dry run)')
    ap.add_argument('--batches', default='', help='comma-separated batch numbers (default: all)')
    ap.add_argument('--by', default='', help='initials of the user recorded as uploaded by')
    a = ap.parse_args()
    api = Api(os.environ['SUPABASE_URL'], os.environ['SUPABASE_SERVICE_ROLE_KEY'])

    files = []
    for root, dirs, names in os.walk(a.folder):
        dirs[:] = [d for d in dirs if d not in ('.git', '_app')]  # _app: the checked-out tools
        for n in names:
            if os.path.splitext(n)[1].lower() in EXTENSIONS:
                p = os.path.join(root, n)
                files.append((os.path.relpath(p, a.folder), os.path.getsize(p)))
    files.sort()
    batches = {b['batch_number']: b['id'] for b in api.rows('batches', 'id,batch_number', '&batch_number=like.26*')}
    ids = {v: k for k, v in batches.items()}
    docs = api.rows('batch_documents', 'batch_id,document_type,file_name')
    existing = {'types': {(ids.get(d['batch_id']), d['document_type']) for d in docs if d['document_type'] != 'other'},
                'names': {(ids.get(d['batch_id']), d['file_name']) for d in docs}}
    by = None
    if a.by:
        u = api.rows('users', 'id,initials', f'&initials=eq.{urllib.parse.quote(a.by.upper())}')
        by = u[0]['id'] if u else None
    only = {x.strip() for x in a.batches.split(',') if x.strip()} or None
    rows = plan(files, batches, existing, only)

    done = failed = 0
    if a.run:
        for r in rows:
            if r['action'] != 'upload':
                continue
            bid = batches[r['batch']]
            path = f'{bid}/{r["type"]}/{int(time.time() * 1000)}_{safe(r["name"])}'
            ctype = EXTENSIONS[os.path.splitext(r['name'])[1].lower()]
            try:
                with open(os.path.join(a.folder, r['file']), 'rb') as f:
                    api.call('POST', f'/storage/v1/object/{BUCKET}/{urllib.parse.quote(path)}', raw=f.read(),
                             headers={'Content-Type': ctype, 'x-upsert': 'false'})
                try:
                    api.call('POST', '/rest/v1/batch_documents', body={
                        'batch_id': bid, 'document_type': r['type'], 'file_name': r['name'], 'storage_path': path,
                        'size_bytes': r['size'], 'uploaded_by': by, 'created_by': by, 'updated_by': by},
                        headers={'Prefer': 'return=minimal'})
                except Exception:
                    # no file without a record (as the app does)
                    api.call('DELETE', f'/storage/v1/object/{BUCKET}', body={'prefixes': [path]})
                    raise
                r['action'], done = 'uploaded', done + 1
            except Exception as e:
                r['action'], r['reason'], failed = 'failed', str(e), failed + 1

    # Report (stdout and the GitHub step summary).
    count = {}
    for r in rows:
        count[(r['action'], r['type'])] = count.get((r['action'], r['type']), 0) + 1
    lines = [f'# Documents: {"RUN" if a.run else "DRY RUN (nothing uploaded)"}', '',
             f'{len(files)} files found, {len(rows)} in scope.', '',
             '| Action | ' + ' | '.join(LABELS.values()) + ' |', '|---|' + '---|' * len(LABELS)]
    for act in ('upload', 'uploaded', 'skip', 'hold', 'failed'):
        if any(k[0] == act for k in count):
            lines.append(f'| {act} | ' + ' | '.join(str(count.get((act, t), 0)) for t in LABELS) + ' |')
    attention = [r for r in rows if r['action'] in ('hold', 'failed')]
    if attention:
        lines += ['', '## Needs attention', '', '| File | Batch | Type | Reason |', '|---|---|---|---|']
        lines += [f'| {r["file"]} | {r["batch"] or "-"} | {LABELS[r["type"]]} | {r["reason"]} |' for r in attention]
    missing = sorted({b for b in batches if not (b, 'filling_report') in existing['types']}
                     - {r['batch'] for r in rows if r['type'] == 'filling_report' and r['action'] in ('upload', 'uploaded')})
    lines += ['', f'Batches without a filling report afterwards: {len(missing)}']
    report = '\n'.join(lines) + '\n'
    print(report)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as f:
            f.write(report)
    with open('documents_plan.json', 'w') as f:
        json.dump(rows, f, indent=1)
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
