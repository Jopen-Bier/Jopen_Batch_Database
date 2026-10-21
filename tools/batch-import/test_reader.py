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
        eq([b.get('mash_rinse_water_hl') for b in x['brews']], [0.6, 0.7, 0.6, 0.9, 0.6, 0.6, 0.9, 0.8], 'Mashing "Spoelwater" = rinse water')
        eq(sum('Spoelwater' in c['comment'] for c in x['brew_comments']), 0, 'no Spoelwater comments')
    p = find(d, '26260')
    if p:
        x = reader.read_workbook(p, ref)
        eq((x['batch']['glt_tank'], x['batch']['lt_tank']), ('GLT21', 'LT54'), 'GLT / LT')
        eq(x['hbts'][0].get('processing_session_number'), 1, 'one session: readings linked')
        eq(x['batch']['yeast_pitched_by'], 'EVL', 'yeast pitched by')
    p = find(d, '26003')
    if p:
        # Old (not generated) report: 16000 columns wide, a session only on the filling report.
        x = reader.read_workbook(p, ref)
        eq([(s['filling_date'], s.get('hbt_tank'), s.get('volume_hl')) for s in x['filling_sessions']],
           [('2026-02-11', 11, 28.9), ('2026-02-12', 13, 14.0), ('2026-02-12', 13, 6.0)], 'session from the filling report only')
        eq([s.get('is_hbt_finished', False) for s in x['filling_sessions']], [True, False, True], 'HBT13 finished with 14 + 6 hl')
        eq([len(h['readings']) for h in x['hbts']], [3, 2], 'pre-filled HBT rows without values dropped')
        eq([c['comment'] for c in x['brew_comments'] if c['brew_number'] is None][-1],
           'Added 120ml zincsulfate to WP of brew A', 'remarks (Opmerkingen) as batch-wide brew comments')
    p = find(d, '26001')
    if p:
        eq(reader.read_workbook(p, ref)['batch']['yeast_strain'], 'Munich classic', 'trailing dash trimmed')
    p = find(d, '26293')
    if p:
        x = reader.read_workbook(p, ref)
        eq(len(x['processing_sessions']), 0, 'not processed: no sessions from template defaults')
        eq([(t['to_batch_number'], t['volume_hl'], t['from_tank']) for t in x['transfers']],
           [('26321', 104.4, 'LT56')], 'transfer from "End value" without HBT')
        eq(x['transfers'][0]['transferred_at'], '2026-09-29T12:00:00+02:00', 'transfer date from the log')
        eq(x['transfers'][0]['source'], 'Verwerking!E58 + Afvulverslag!D45', 'transfer found on both forms')
    p = find(d, '26058')
    if p:
        x = reader.read_workbook(p, ref)
        eq((x['type'], x['batch_number'], bool(x.get('hold'))), ('barrel_aging', '26058', True), 'barrel aging held, not guessed')
    p = find(d, '26093')
    if p:
        # Splits written on HBT end-value rows (10 + 30 hl = 4000 l on the filling report), and TT60.
        x = reader.read_workbook(p, ref)
        eq([(t['to_batch_number'], t['volume_hl'], t['from_tank']) for t in x['transfers']],
           [('26132', 10.0, 'HBT13'), ('26132', 30.0, 'HBT12'), ('26133', 28.2, 'HBT16')], 'splits from HBTs')
        eq(not any('Processing' in w and 'filling report' in w for w in x['warnings']), True, 'split volumes match the filling report')
        eq([(h['tank'], h['end_level_hl']) for h in x['hbts']][-1], ('TT60', 40.0), 'TT60 as a fill (tank beer)')
        eq([(s['package_format'], s['volume_hl'], s['articles']) for s in x['filling_sessions'] if s['package_format'] == 'tank'],
           [('tank', 40.0, [{'code': 'tank_jopenkerk', 'quantity': 40.0}])], 'tank beer filling session')
    p = find(d, '26028')
    if p:
        x = reader.read_workbook(p, ref)
        eq([(s['filling_date'], s['package_format'], s['volume_hl']) for s in x['filling_sessions'] if s['package_format'] == 'tank'],
           [('2026-03-20', 'tank', 32.0)], 'TT60 dated from the filling report, written twice there, counted once')
        eq(x.get('other_end_values'), None, 'nothing left for Jaap')
    p = find(d, '26020')
    if p:
        x = reader.read_workbook(p, ref)
        eq([(h['tank'], h['end_level_hl']) for h in x['hbts']], [('CKT2', 16.5)], 'one-off: filled from CKT2 (overrides.json)')
        eq([(s['package_format'], s.get('hbt_index'), s.get('is_hbt_finished')) for s in x['filling_sessions']], [('keg', 0, True)], 'one-off session')
    p = find(d, '26285')
    if p:
        x = reader.read_workbook(p, ref)
        eq([t['to_batch_number'] for t in x['transfers']], ['26339', '26340', '26350'], 'splits via LT11 / LT12 / LT56')
    p = find(d, '26028')
    if p:
        eq(reader.read_workbook(p, ref)['batch_number'], '26028', 'batch number when Brouwen N3 holds a date')
    print(f'test_reader: {ok} checks passed')


if __name__ == '__main__':
    main()
