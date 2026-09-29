"""Formal S46/S58 baseline identity, frozen inputs, persisted state and v33 risk comparison."""
import contextlib
import json
import math
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from sp08_sp09_market_extrema_decision_study import connect, read

COMMIT = (ROOT / 'exports/baseline-v34-rule-commit.txt').read_text().strip()
RULE = 's46-h-entry-f1-20260929'
assert subprocess.check_output(['git', 'rev-parse', '--verify', COMMIT + '^{commit}'], cwd=ROOT, text=True).strip() == COMMIT


def run_id(sample, version, window):
    suffix,day = ('s46-h-entry-f1-t3s58','20260929') if version == 34 else ('s45-market-same-day-t3s57','20260918')
    return f'baseline-{sample.lower()}-v{version}-{suffix}-9y-{window}-600w-{day}'


def technical_rows(path):
    with contextlib.closing(connect(path)) as db:
        # Fixed OHLC/volume and every persisted technical statistic, not sim state.
        cols = [r['name'] for r in db.execute('PRAGMA table_info(ZTRADE)')
                if r['name'].startswith(('ZT', 'ZV', 'ZPRICE')) and r['name'] not in ('ZTRADE',)]
        return [tuple(r) for r in db.execute('SELECT s.ZSID,t.ZDATETIME,' + ','.join('t.' + c for c in cols)
                    + ' FROM ZTRADE t JOIN ZSTOCK s ON s.Z_PK=t.ZSTOCK ORDER BY s.ZSID,t.ZDATETIME')]


def audit(sample):
    profile = 'abcde9-v3' if sample == 'E' else 'abcd9-v3'
    bid = f'{sample.lower()}-{profile}-{RULE}-t3-s58-{COMMIT[:12]}-fixed3y-20260722-v20'
    base_dir = ROOT / 'exports/backtest-decision-bases' / bid
    for name in ('.complete', '.p4b-complete'):
        assert (base_dir / name).read_text().strip() == bid
    bm = read(base_dir / 'manifest.json')
    assert bm['decisionBaseID'] == bid and bm['formatVersion'] == 6
    assert bm['ruleCommit'] == COMMIT and bm['dataRuleVersion'] == 'T3/S58'
    assert bm['ruleVersion'] == RULE and bm['sampleID'] == sample
    assert bm['windowCount'] == 3 and bm['outcomeCount'] == 30 and bm['stockCount'] == 10
    assert bm['moneyBaseWan'] == 600 and bm['automaticInvestments'] == 2
    assert bm['through'] == '2026/07/22'
    for name in bm['files']:
        assert (base_dir / name).is_file()
    windows = {}
    for window in ('fixed3y', 'fullstress'):
        rid = run_id(sample, 34, window)
        directory = ROOT / 'exports/backtest-reports' / rid
        previous = ROOT / 'exports/backtest-reports' / run_id(sample, 33, window)
        m, b, old = read(directory / 'manifest.json'), read(directory / 'baseline.json'), read(previous / 'baseline.json')
        assert (directory / '.complete').read_text().strip() == rid
        for payload in (m, b):
            assert payload['runID'] == rid and payload['sampleID'] == sample
            assert payload['ruleCommit'] == COMMIT and payload['dataRuleVersion'] == 'T3/S58'
            assert payload['ruleVersion'] == RULE
            for field in ('historyStart', 'through', 'moneyBaseWan', 'automaticInvestments', 'periodStarts'):
                assert payload[field] == old[field], (rid, field)
            assert payload['marketInput']['dailySHA256'] == '558883f85355b49c1c4402b4346d9a4939411bea69d405275c2b42aa55bb8da4'
            assert payload['marketInput']['extremaSHA256'] == '6d5519a63bba5dfabab243d7ce35d37a8a8c007ecd0b0ac3703b2fa14922861e'
            assert payload['marketInput']['pricePathSHA256'] == 'f9e1f41c8ba74dd94b970460a148983d7763b108985be55b11cfba64fc03d17f'
            assert payload['marketInput']['alignment'] == 'same-decision-calendar-date'
        html = (directory / 'report.html').read_text()
        assert all(value in html for value in (COMMIT, 'T3/S58', RULE, run_id(sample, 33, window)))
        if sample == 'B':
            a = read(ROOT / 'exports/backtest-reports' / run_id('A', 34, window) / 'baseline.json')
            assert a['ruleCommit'] == COMMIT and a['ruleVersion'] == RULE
            assert '與同版 Baseline A 的比較解讀' in html
            assert f"合計 {b['combinedScore'] - a['combinedScore']:+.2f}" in html
        assert m['invalidValueCount'] == m['excludedNoTransactionCount'] == 0
        for name in (*m['reportFiles'], 'browse.store'):
            assert (directory / name).is_file()

        assert all(math.isfinite(s[k]) for s in b['stocks'] for k in ('roi', 'averageDays'))
        assert technical_rows(directory / 'browse.store') == technical_rows(previous / 'browse.store')
        with contextlib.closing(connect(directory / 'browse.store')) as db:
            assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
            versions = [tuple(r) for r in db.execute('SELECT DISTINCT ZTECHNICALSTATEVERSION,ZSIMULATIONSTATEVERSION,ZTECHNICALDIRTYFROM,ZSIMULATIONDIRTYFROM FROM ZSTOCK')]
            assert versions == [(3, 58, None, None)], (rid, versions)
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
    store_checks = []
    for window in ('fixed3y', 'fullstress'):
        directory = ROOT / 'exports/backtest-reports' / run_id(sample, 34, window)
        previous = ROOT / 'exports/backtest-reports' / run_id(sample, 33, window)
        names = ['browse.store'] + (['period-20200722.store', 'period-20230722.store'] if window == 'fixed3y' else [])
        for name in names:
            assert technical_rows(directory / name) == technical_rows(previous / name), (sample, window, name, 'technical')
            with contextlib.closing(connect(directory / name)) as db:
                assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
                assert [tuple(r) for r in db.execute('SELECT DISTINCT ZTECHNICALSTATEVERSION,ZSIMULATIONSTATEVERSION,ZTECHNICALDIRTYFROM,ZSIMULATIONDIRTYFROM FROM ZSTOCK')] == [(3,58,None,None)]
                count = db.execute('SELECT COUNT(*) FROM ZTRADE').fetchone()[0]
                from audit_baseline_v33_risk import audit_store
                end = 20260722 if window == 'fullstress' or name == 'period-20230722.store' else (20200722 if name == 'browse.store' else 20230722)
                risk = audit_store(directory / name, end, expected_data_rules='T3/S58')
                old_risk = audit_store(previous / name, end)
                store_checks.append(dict(window=window, store=name, rows=count, risk=risk, previousRisk=old_risk))
    with contextlib.closing(connect(base_dir / 'decisions.sqlite')) as db:
        assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
        metadata = dict(db.execute('SELECT key,value FROM metadata'))
        for key in ('decisionBaseID', 'ruleCommit', 'dataRuleVersion', 'ruleVersion', 'sampleID'):
            assert metadata[key] == bm[key]
        count = db.execute('SELECT COUNT(*) FROM rules').fetchone()[0]
        assert count == 97, count
        events = db.execute('SELECT COUNT(*) FROM decision_events').fetchone()[0]
        assert events > 0
    from audit_baseline_v33_market import market_audit
    market = market_audit(base_dir, ROOT / 'exports/backtest-reports' / run_id(sample, 34, 'fixed3y'))
    from audit_baseline_v34_f1 import f1_audit
    f1 = f1_audit(sample, base_dir, ROOT / 'exports/backtest-reports' / run_id(sample, 34, 'fixed3y'))
    return dict(f1=f1, marketVotes=market, sample=sample, ruleCommit=COMMIT, decisionBaseID=bid, verified=True,
                eventCount=events, ruleCount=count, stores=store_checks, windows=windows)

if __name__ == '__main__':
    samples = sys.argv[1:] or list('ABCDE')
    assert all(s in 'ABCDE' and len(s) == 1 for s in samples)
    result = [audit(s) for s in samples]
    output = ROOT / ('exports/baseline-v34-verification-' + ''.join(samples) + '.json')
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps([dict(sample=r['sample'], events=r['eventCount'], windows={k: dict(score=v['score'], delta=v['delta']) for k,v in r['windows'].items()}) for r in result], ensure_ascii=False, indent=2))
