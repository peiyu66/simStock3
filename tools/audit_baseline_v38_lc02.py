"""Compare adopted L-C02 removal with the independently audited frozen candidate."""
import importlib.util
import json
import sqlite3
import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = ROOT / 'exports/retained-rules-retest-20261006/lc02-abcde'


def lc02_audit(sample, base_dir, fixed_dir):
    old = EVIDENCE / 'runs' / f'rr-lc02-abcde-{sample.lower()}-remove-t3s61-fixed3y-600w-20261006'
    before, after = [json.loads((p / 'baseline.json').read_text()) for p in (old, fixed_dir)]
    for field in ('stocks', 'periods', 'groups', 'combinedScore'):
        assert before[field] == after[field], (sample, field, 'frozen LC02 result')
    assert (old / 'periods.csv').read_bytes() == (fixed_dir / 'periods.csv').read_bytes()
    checks = []
    for name in ('browse.store', 'period-20200722.store', 'period-20230722.store'):
        paths = []
        for directory, version in ((old, 'T3/S61'), (fixed_dir, 'T3/S62')):
            with sqlite3.connect(f'file:{directory/name}?mode=ro', uri=True) as db:
                cols = [r[1] for r in db.execute('PRAGMA table_info(ZTRADE)') if r[1].startswith(('ZT', 'ZV', 'ZPRICE', 'ZSIM', 'ZROLL'))]
                assert len(cols) == 108
                wi = cols.index('ZSIMANNUALWARNINGDATA') + 2
                rows = []
                for row in db.execute('SELECT s.ZSID,t.ZDATETIME,' + ','.join('t.'+c for c in cols) + ' FROM ZTRADE t JOIN ZSTOCK s ON s.Z_PK=t.ZSTOCK ORDER BY s.ZSID,t.ZDATETIME'):
                    row = list(row)
                    if row[wi] is not None:
                        warning = json.loads(row[wi]); assert warning['dataRules'] == version
                        warning['dataRules'] = 'version-only'; row[wi] = warning
                    rows.append(row)
                paths.append(rows)
        assert paths[0] == paths[1], (sample, name, 'persistent LC02 path')
        checks.append(dict(store=name, rows=len(paths[0]), columns=108, exactExceptWarningVersion=True))
    sys.path.insert(0, str(EVIDENCE))
    import audit_helpers as ah
    def connect(p):
        db = sqlite3.connect(f'file:{p}?mode=ro', uri=True); db.row_factory = sqlite3.Row; return db
    ah.connect = connect; ah.read = lambda p: json.loads(p.read_text())
    identity = json.loads((EVIDENCE/'identities.json').read_text())[sample]
    previous = ROOT / identity['decisionBase']
    delta = Path('/tmp/rr-lc02-abcde-20261006/exports/backtest-decision-deltas') / previous.name / 'RR-LC02-RM'
    _, expected, _ = ah.events(previous, delta)
    with connect(base_dir/'decisions.sqlite') as db:
        actual = {}; ids = {}
        for e in db.execute('SELECT e.*,s.stock_id,w.start_date,w.end_date FROM decision_events e JOIN stocks s USING(stock_key) JOIN windows w USING(window_id)'):
            k=tuple(e[n] for n in ('start_date','end_date','stock_id','trade_date','phase'));actual[k]=dict(e,votes={},gates=set());ids[e['event_id']]=k
        for v in db.execute('SELECT * FROM event_vote_lookup'):actual[ids[v['event_id']]]['votes'][v['rule_id']]=v['contribution']
        for g in db.execute('SELECT * FROM event_gate_lookup'):actual[ids[g['event_id']]]['gates'].add(g['rule_id'])
        assert set(actual)==set(expected), (sample,'event coverage')
        from sp08_sp09_market_extrema_decision_study import FIELDS
        for k,e in expected.items():
            a=actual[k]
            for f,_,_ in FIELDS: assert a[f]==e[f], (sample,k,f,a[f],e[f])
            # The retired rule key is absent; its candidate contribution was zero.
            assert e['votes'].get('L-C02',0)==0
            votes={r:v for r,v in e['votes'].items() if r!='L-C02'}
            assert a['votes']==votes and a['gates']==e['gates'], (sample,k,'votes/gates')
    return dict(frozenCandidateExact=True, stores=checks, eventsExact=len(actual), retiredZeroRuleOmitted='L-C02')
