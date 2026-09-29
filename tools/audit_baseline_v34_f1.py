"""Formal F1 parity against the frozen, authorized A-E candidate paths."""
import json
import sqlite3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def f1_audit(sample, base_dir, fixed_dir):
    old = ROOT / 'exports/h-entry-composite-q1012-f1-20260929/source/exports/backtest-candidate-runs' / f'hc-q10-12-f1-{sample.lower()}-candidate-t3s57-fixed3y-600w-20260929'
    before, after = [json.loads((d / 'baseline.json').read_text()) for d in (old, fixed_dir)]
    for field in ('stocks', 'periods', 'groups', 'combinedScore'):
        assert before[field] == after[field], (sample, field, 'frozen candidate mismatch')
    checks = []
    for name in ('browse.store', 'period-20200722.store', 'period-20230722.store'):
        paths = []
        for directory in (old, fixed_dir):
            with sqlite3.connect(f'file:{directory/name}?mode=ro', uri=True) as db:
                columns = [r[1] for r in db.execute('PRAGMA table_info(ZTRADE)')
                           if r[1].startswith(('ZT', 'ZV', 'ZPRICE', 'ZSIM', 'ZROLL'))]
                assert len(columns) == 108
                rows = []
                for row in db.execute('SELECT s.ZSID,t.ZDATETIME,' + ','.join('t.' + c for c in columns) +
                                      ' FROM ZTRADE t JOIN ZSTOCK s ON s.Z_PK=t.ZSTOCK ORDER BY s.ZSID,t.ZDATETIME'):
                    row = list(row)
                    wi = columns.index('ZSIMANNUALWARNINGDATA') + 2
                    if row[wi] is not None:
                        warning = json.loads(row[wi])
                        assert warning['dataRules'] == ('T3/S57' if directory == old else 'T3/S58')
                        warning['dataRules'] = 'normalized-version-only'
                        row[wi] = warning
                    rows.append(row)
                paths.append(rows)
        assert paths[0] == paths[1], (sample, name, 'persistent path differs from F1')
        checks.append(dict(store=name, rows=len(paths[0]), columns=108, exactExceptWarningVersion=True))
    diagnostics = json.loads((old / 'hc-entry-diagnostics.json').read_text())['records']
    expected = {(int(r['windowStart'].replace('-', '')), r['stock'], int(r['date'].replace('-', '')))
                for r in diagnostics if r['suppressed']}
    with sqlite3.connect(f'file:{base_dir / "decisions.sqlite"}?mode=ro', uri=True) as db:
        actual = set(db.execute('''SELECT w.start_date,s.stock_id,e.trade_date FROM event_gate_lookup g
            JOIN decision_events e USING(event_id) JOIN windows w USING(window_id) JOIN stocks s USING(stock_key)
            WHERE g.rule_id='H-E01' AND e.phase=1 AND e.planned_action='NONE' '''))
        assert actual == expected, (sample, 'H-E01 activations', actual ^ expected)
        bad = db.execute('''SELECT COUNT(*) FROM decision_events e WHERE e.phase IN (1,2,3,4)
            AND abs(e.decision_score-coalesce((SELECT sum(v.contribution) FROM event_vote_lookup v
            WHERE v.event_id=e.event_id),0))>0.00000001''').fetchone()[0]
        assert bad == 0, (sample, 'vote sums')
    return dict(frozenCandidateExact=True, stores=checks, hEntryDelayCount=len(actual), votesUnchanged=True)
