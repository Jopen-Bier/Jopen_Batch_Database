# Test of reader.py on the sample workbooks (26260, 26292, 26293).
# The workbooks are not in this repo: python3 -I tools/batch-import/test_reader.py <dir with workbooks> <ref.json>
# Without arguments the test is skipped.
import sys, os, glob
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import json
import reader


def find(d, n):
    hits = glob.glob(os.path.join(d, f'{n}*.xlsx'))
    return hits[0] if hits else None


def main():
    if len(sys.argv) < 3:
        print('test_reader: skipped (no workbook dir / ref.json given)')
        return
    d, ref = sys.argv[1], json.load(open(sys.argv[2]))
    ok = 0

    def eq(a, b, what):
        nonlocal ok
        assert a == b, f'{what}: {a!r} != {b!r}'
        ok += 1

    p = find(d, '26292')
    if p:
        x = reader.read_workbook(p, ref)
        eq(x['batch_number'], '26292', 'batch number')
        eq(x['batch']['glt_tank'], 'GLT62', 'GLT from Brewing I5')
        eq(len(x['brews']), 8, 'brews')
        eq((x['brews'][3]['brewer'], x['brews'][3]['brewer_end']), ('FH', 'SB'), 'brew 4 brewer start / end')
        eq(x['brews'][0]['mash_in_started_at'], '2026-09-07T04:30:00+02:00', 'mash-in local time')
        eq(x['fermentation_log'][0]['tags'], ['24h_purge'], 'first log tag')
        eq(x['fermentation_log'][0]['measured_at'], '2026-09-09T07:00:00+02:00', 'log date + hour')
        eq(len(x['processing_sessions']), 3, 'processing sessions')
        eq([h['tank'] for h in x['hbts']], ['HBT16', 'HBT17', 'HBT16'], 'HBT fills in order (refill)')
        eq([h['end_level_hl'] for h in x['hbts']], [120.0, 50.1, 108.8], 'end values per fill')
        eq([s.get('hbt_index') for s in x['filling_sessions']], [0, 1, 2, 2], 'filling session -> fill')
        eq([s.get('is_hbt_finished', False) for s in x['filling_sessions']], [True, True, False, True], 'HBT finished')
        eq([s.get('package_format') for s in x['filling_sessions']], ['can', 'can', 'keg', 'keg'], 'package from articles')
        eq(x['filling_sessions'][0]['articles'], [{'code': 'box_24x33_can', 'quantity': 1428.0}], 'articles')
        eq(x['filling_sessions'][1]['filled_by'], 'TW', 'filled by')
        eq(x['batch']['tasting_result'], 'go', 'tasting result')
        eq({(h.get('avg_pu'), h.get('avg_turbidity_ebc')) for h in x['hbts']}, {(25.0, 9.83)}, 'averages on every HBT')
        eq(sum('Spoelwater' in c['comment'] for c in x['brew_comments']), 8, 'Mashing "Spoelwater" kept as brew comment')
    p = find(d, '26260')
    if p:
        x = reader.read_workbook(p, ref)
        eq((x['batch']['glt_tank'], x['batch']['lt_tank']), ('GLT21', 'LT54'), 'GLT / LT')
        eq(x['hbts'][0].get('processing_session_number'), 1, 'one session: readings linked')
        eq(x['batch']['yeast_pitched_by'], 'EVL', 'yeast pitched by')
    p = find(d, '26293')
    if p:
        x = reader.read_workbook(p, ref)
        eq(len(x['processing_sessions']), 0, 'not processed: no sessions from template defaults')
        eq([(t['to_batch_number'], t['volume_hl'], t['from_tank']) for t in x['transfers']],
           [('26321', 104.4, 'LT56')], 'transfer from "End value" without HBT')
        eq(x['transfers'][0]['transferred_at'], '2026-09-29T12:00:00+02:00', 'transfer date from the log')
        eq(x['transfers'][0]['source'], 'Verwerking!E58 + Afvulverslag!D45', 'transfer found on both forms')
    print(f'test_reader: {ok} checks passed')


if __name__ == '__main__':
    main()
