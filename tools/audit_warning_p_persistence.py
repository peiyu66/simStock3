"""Compare formal S63 persisted warning snapshots/continuations with frozen P research."""
from pathlib import Path
import contextlib
import gzip
import json
from sp08_sp09_market_extrema_decision_study import connect

ROOT = Path(__file__).resolve().parents[1]

def audit(sample):
    research = ROOT / 'exports/warning-lifecycle-20261008'
    total = paths = 0
    for p in map(json.loads, (research / 'paths.jsonl').read_text().splitlines()):
        if p['group'] != sample or not p['source'].startswith('exports/backtest-reports/baseline-'):
            continue
        destination = ROOT / p['source'].replace('v38-s50-lc02-removed-t3s62', 'v39-s50-warning-p-t3s63').replace('600w-20261007', '600w-20261008')
        with contextlib.closing(connect(destination)) as db:
            records = {r['ZDATETIME']: json.loads(r['ZSIMANNUALWARNINGDATA']) for r in db.execute(
                'SELECT t.ZDATETIME,t.ZSIMANNUALWARNINGDATA FROM ZTRADE t JOIN ZSTOCK s ON s.Z_PK=t.ZSTOCK WHERE s.ZSID=? AND t.ZSIMANNUALWARNINGDATA IS NOT NULL', (p['sid'],))}
        with gzip.open(Path(p['inputRoot']) / p['file'], 'rt') as inputs, gzip.open(research / (p['id'] + '.jsonl.gz'), 'rt') as expected:
            for a,b in zip(inputs, expected, strict=True):
                row = json.loads(a); want = json.loads(b)['modes'][2]; got = records[row['input'][0]]
                assert got['dataRules'] == 'T3/S63' and got['formatVersion'] == 6
                snapshot = got['snapshot'].copy()
                level = snapshot.pop('breakoutReference', None); age = snapshot.pop('breakoutConfirmationDays', None)
                failures = snapshot.pop('anchorFailureDays')
                assert snapshot == want['s'], (p['id'], row['i'], 'snapshot', snapshot, want['s'])
                assert [got.get('continuationFloor'),got.get('continuationPriceHigh'),got['locallyReleased']] == [want['f'],want['h'],want['l']]
                state = got['continuation']
                assert state.get('setup') == want['setup'] and state.get('anchor') == want['anchor'], (p['id'],row['i'],'anchor/setup')
                expected_failure = 0 if want['event'] or not want['flags'] else want['flags']['failn']
                assert state['failureDays'] == failures == expected_failure
                if snapshot['status'] != 'unavailable':
                    active = want['setup'] or want['anchor']
                    assert level == (active['level'] if active else None)
                    assert age == (want['setup']['age'] if want['setup'] else None)
                total += 1
        paths += 1
    assert paths == 40, (sample, paths)
    return dict(paths=paths, rows=total, exactSnapshotsAndContinuations=True)
