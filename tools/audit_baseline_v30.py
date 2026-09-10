"""Formal H-N13 S49 audit against frozen R2-H01-KJ and v29 risk context."""
import contextlib
import io
import json
import math
from pathlib import Path
import runpy
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from sp08_sp09_market_extrema_decision_study import connect, read, FIELDS

COMMIT = (ROOT / 'exports/baseline-v30-rule-commit.txt').read_text().strip()
RULE = 's42-hn13-kj-hot-20260911'
assert subprocess.check_output(['git', 'rev-parse', '--verify', COMMIT + '^{commit}'], cwd=ROOT, text=True).strip() == COMMIT


def run_id(sample, version, window):
    suffix,day = ('s42-hn13-kj-hot-t3s49','20260911') if version == 30 else ('s41-hp03a-pullback-market-t3s48','20260910')
    return f'baseline-{sample.lower()}-v{version}-{suffix}-9y-{window}-600w-{day}'


def candidate_directory(sample, window):
    origin = 'source' if window == 'fixed3y' else 'fullstress-20260911/source'
    return ROOT / 'exports/r2-h-kj-execution-20260910' / origin / 'exports/backtest-candidate-runs' / f'r2-h01-kj-{sample.lower()}-v29-t3s48-{window}-600w-20260910'



def technical_rows(path):
    with contextlib.closing(connect(path)) as db:
        # Fixed OHLC/volume and every persisted technical statistic, not sim state.
        cols = [r['name'] for r in db.execute('PRAGMA table_info(ZTRADE)')
                if r['name'].startswith(('ZT', 'ZV', 'ZPRICE')) and r['name'] not in ('ZTRADE',)]
        return [tuple(r) for r in db.execute('SELECT s.ZSID,t.ZDATETIME,' + ','.join('t.' + c for c in cols)
                    + ' FROM ZTRADE t JOIN ZSTOCK s ON s.Z_PK=t.ZSTOCK ORDER BY s.ZSID,t.ZDATETIME')]


def simulation_rows(path):
    with contextlib.closing(connect(path)) as db:
        cols = [r['name'] for r in db.execute('PRAGMA table_info(ZTRADE)')
                if r['name'].startswith(('ZSIM', 'ZROLL'))]
        return [tuple(r) for r in db.execute('SELECT s.ZSID,t.ZDATETIME,' + ','.join('t.' + c for c in cols)
                    + ' FROM ZTRADE t JOIN ZSTOCK s ON s.Z_PK=t.ZSTOCK ORDER BY s.ZSID,t.ZDATETIME')]


def audit(sample):
    profile = 'abcde9-v3' if sample == 'E' else 'abcd9-v3'
    bid = f'{sample.lower()}-{profile}-{RULE}-t3-s49-{COMMIT[:12]}-fixed3y-20260722-v16'
    base_dir = ROOT / 'exports/backtest-decision-bases' / bid
    for name in ('.complete', '.p4b-complete'):
        assert (base_dir / name).read_text().strip() == bid
    bm = read(base_dir / 'manifest.json')
    assert bm['decisionBaseID'] == bid and bm['formatVersion'] == 6
    assert bm['ruleCommit'] == COMMIT and bm['dataRuleVersion'] == 'T3/S49'
    assert bm['ruleVersion'] == RULE and bm['sampleID'] == sample
    assert bm['windowCount'] == 3 and bm['outcomeCount'] == 30 and bm['stockCount'] == 10
    assert bm['moneyBaseWan'] == 600 and bm['automaticInvestments'] == 2
    assert bm['through'] == '2026/07/22'
    for name in bm['files']:
        assert (base_dir / name).is_file()
    windows = {}
    for window in ('fixed3y', 'fullstress'):
        rid = run_id(sample, 30, window)
        directory = ROOT / 'exports/backtest-reports' / rid
        previous = ROOT / 'exports/backtest-reports' / run_id(sample, 29, window)
        m, b, old = read(directory / 'manifest.json'), read(directory / 'baseline.json'), read(previous / 'baseline.json')
        assert (directory / '.complete').read_text().strip() == rid
        for payload in (m, b):
            assert payload['runID'] == rid and payload['sampleID'] == sample
            assert payload['ruleCommit'] == COMMIT and payload['dataRuleVersion'] == 'T3/S49'
            assert payload['ruleVersion'] == RULE
            for field in ('historyStart', 'through', 'moneyBaseWan', 'automaticInvestments', 'periodStarts'):
                assert payload[field] == old[field], (rid, field)
            assert payload['marketInput']['dailySHA256'] == '558883f85355b49c1c4402b4346d9a4939411bea69d405275c2b42aa55bb8da4'
            assert payload['marketInput']['extremaSHA256'] == '6d5519a63bba5dfabab243d7ce35d37a8a8c007ecd0b0ac3703b2fa14922861e'
            assert payload['marketInput']['pricePathSHA256'] == 'f9e1f41c8ba74dd94b970460a148983d7763b108985be55b11cfba64fc03d17f'
            assert payload['marketInput']['alignment'] == 'strictly-before-decision-calendar-date'
        html = (directory / 'report.html').read_text()
        assert all(value in html for value in (COMMIT, 'T3/S49', RULE, run_id(sample, 29, window)))
        assert m['invalidValueCount'] == m['excludedNoTransactionCount'] == 0
        for name in (*m['reportFiles'], 'browse.store'):
            assert (directory / name).is_file()
        assert not any(s['moneyLacked'] for s in b['stocks'])
        from candidate_fullstress_summary import negative_balances
        assert negative_balances(directory / 'browse.store') == []
        assert all(s['status'] == '正常' for s in b['stocks'])
        assert all(math.isfinite(s[k]) for s in b['stocks'] for k in ('roi', 'averageDays'))
        assert technical_rows(directory / 'browse.store') == technical_rows(previous / 'browse.store')
        with contextlib.closing(connect(directory / 'browse.store')) as db:
            assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
            versions = [tuple(r) for r in db.execute('SELECT DISTINCT ZTECHNICALSTATEVERSION,ZSIMULATIONSTATEVERSION,ZTECHNICALDIRTYFROM,ZSIMULATIONDIRTYFROM FROM ZSTOCK')]
            assert versions == [(3, 49, None, None)], (rid, versions)
        old_groups = {g['group']: g for g in old['groups']}
        stock_key = lambda s: (s['id'], s['periodStart'], s['periodEnd'])
        old_stocks = {stock_key(s): s for s in old['stocks']}
        stock_deltas = []
        for stock in b['stocks']:
            prior = old_stocks[stock_key(stock)]
            changes = {k: stock[k] - prior[k] for k in ('roi', 'averageDays', 'rounds')}
            if any(changes.values()):
                stock_deltas.append(dict(id=stock['id'], name=stock['name'], group=stock['group'],
                    start=stock['periodStart'], before={k: prior[k] for k in changes}, after={k: stock[k] for k in changes}, delta=changes))
        windows[window] = dict(score=b['combinedScore'], previousScore=old['combinedScore'],
            delta=b['combinedScore'] - old['combinedScore'], groups=[dict(g, delta=g['mainScore']-old_groups[g['group']]['mainScore']) for g in b['groups']],
            stockDeltas=stock_deltas, technicalZeroDifference=True, versions=versions)
    # Apply frozen KJ delta to its immutable v29 DecisionBase.
    old_bid = f'{sample.lower()}-{profile}-s41-hp03a-pullback-market-20260910-t3-s48-937221c36d17-fixed3y-20260722-v15'
    old_dir = ROOT / 'exports/backtest-decision-bases' / old_bid
    delta_dir = ROOT / 'exports/r2-h-kj-execution-20260910/source/exports/backtest-decision-deltas' / old_bid / 'R2-H01-KJ'
    expected, ids = {}, {}
    with contextlib.closing(connect(old_dir / 'decisions.sqlite')) as db:
        for r in db.execute('SELECT e.*,w.start_date,w.end_date,s.stock_id FROM decision_events e JOIN windows w USING(window_id) JOIN stocks s USING(stock_key)'):
            key = tuple(r[n] for n in ('start_date','end_date','stock_id','trade_date','phase'))
            expected[key] = dict(r, votes={})
            ids[r['event_id']] = key
        for r in db.execute('SELECT * FROM event_vote_lookup'):
            expected[ids[r['event_id']]]['votes'][r['rule_id']] = r['contribution']
    with contextlib.closing(connect(delta_dir / 'decision-delta.sqlite')) as dd:
        delta_keys = {}
        for d in dd.execute('SELECT * FROM event_deltas'):
            key = tuple(d[n] for n in ('window_start','window_end','stock_id','trade_date','phase'))
            if d['kind'] == 3:
                del expected[key]
                continue
            delta_keys[d['delta_id']] = key
            if d['kind'] == 2: expected[key] = dict(votes={})
            for field,suffix,bit in FIELDS:
                if d['changed_fields'] & (1 << bit): expected[key][field] = d['candidate_' + suffix]
        for v in dd.execute('SELECT * FROM vote_deltas'):
            if v['delta_id'] not in delta_keys: continue
            votes = expected[delta_keys[v['delta_id']]]['votes']
            if v['candidate_contribution'] is None: votes.pop(v['rule_id'], None)
            else: votes[v['rule_id']] = v['candidate_contribution']
    for window in ('fixed3y', 'fullstress'):
        fixed_dir = ROOT / 'exports/backtest-reports' / run_id(sample, 30, window)
        candidate_dir = candidate_directory(sample, window)
        assert (fixed_dir / 'periods.csv').read_bytes() == (candidate_dir / 'periods.csv').read_bytes()
        names = ['browse.store'] + (['period-20200722.store', 'period-20230722.store'] if window == 'fixed3y' else [])
        for name in names:
            assert simulation_rows(fixed_dir / name) == simulation_rows(candidate_dir / name), (sample, window, name, 'persisted simulation')
            assert technical_rows(fixed_dir / name) == technical_rows(candidate_dir / name), (sample, window, name, 'technical')
            with contextlib.closing(connect(fixed_dir / name)) as store:
                assert not store.execute('SELECT 1 FROM ZTRADE WHERE ZSIMAMTBALANCE < -0.01 LIMIT 1').fetchall()
                assert [tuple(r) for r in store.execute('SELECT DISTINCT ZTECHNICALSTATEVERSION,ZSIMULATIONSTATEVERSION,ZTECHNICALDIRTYFROM,ZSIMULATIONDIRTYFROM FROM ZSTOCK')] == [(3,49,None,None)]
    # Candidate implements the extra vote as gate +1. Normalize only its exact
    # flat wow H gate to formal score -1 / original gate 0, adding the H-N13 vote.
    normalized = 0
    for key, event in expected.items():
        if key[-1] == 1 and event['grade'] == 3 and event['inventory_before'] == 0 and event['decision_threshold'] == 1:
            event['decision_score'] -= 1
            event['decision_threshold'] = 0
            event['votes']['H-N13'] = -1
            normalized += 1
    with contextlib.closing(connect(base_dir / 'decisions.sqlite')) as db:
        assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
        metadata = dict(db.execute('SELECT key,value FROM metadata'))
        for key in ('decisionBaseID', 'ruleCommit', 'dataRuleVersion', 'ruleVersion', 'sampleID'):
            assert metadata[key] == bm[key]
        formal = {}
        ids = {}
        for row in db.execute('SELECT e.*,w.start_date,w.end_date,s.stock_id FROM decision_events e JOIN windows w USING(window_id) JOIN stocks s USING(stock_key)'):
            key = tuple(row[n] for n in ('start_date', 'end_date', 'stock_id', 'trade_date', 'phase'))
            formal[key] = dict(row, votes={})
            ids[row['event_id']] = key
        assert formal.keys() == expected.keys()
        for row in db.execute('SELECT * FROM event_vote_lookup'):
            formal[ids[row['event_id']]]['votes'][row['rule_id']] = row['contribution']
        for key, row in formal.items():
            ref = expected[key]
            assert all(row[field] == ref[field] for field, _, _ in FIELDS), (sample, key, [(field,row[field],ref[field]) for field,_,_ in FIELDS if row[field] != ref[field]])
            votes = ref['votes']
            assert row['votes'] == votes, (sample, key, 'votes')
        count = db.execute('SELECT COUNT(*) FROM rules').fetchone()[0]
        assert count == 95, count
    return dict(sample=sample, ruleCommit=COMMIT, decisionBaseID=bid, verified=True,
                eventCount=len(expected), ruleCount=count, normalizedCandidateEvents=normalized, candidateDecisionAndVoteEquivalent=True,
                windows=windows)


if __name__ == '__main__':
    samples = sys.argv[1:] or list('ABCDE')
    assert all(s in 'ABCDE' and len(s) == 1 for s in samples)
    result = [audit(s) for s in samples]
    output = ROOT / ('exports/baseline-v30-verification-' + ''.join(samples) + '.json')
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps([dict(sample=r['sample'], events=r['eventCount'], windows={k: dict(score=v['score'], delta=v['delta'], stocks=v['stockDeltas']) for k,v in r['windows'].items()}) for r in result], ensure_ascii=False, indent=2))
