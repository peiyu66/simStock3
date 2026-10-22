#!/usr/bin/env python3
"""Freeze P5 evidence from immutable reports; no replay or parameter search."""
import argparse
from collections import Counter
from datetime import datetime, timedelta, timezone
import hashlib
import json
import math
from pathlib import Path
import sqlite3
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from audit_baseline_v33_risk import validate_settlement

RULE = '8932a9d78fb2c2e4376138e4dce1e2419603db50'
EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)
TAIPEI = timezone(timedelta(hours=8))


def stamp(value):
    return (datetime.strptime(value, '%Y/%m/%d').replace(tzinfo=TAIPEI) - EPOCH).total_seconds()


def day(value):
    return (EPOCH + timedelta(seconds=value)).astimezone(TAIPEI).strftime('%Y/%m/%d')


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def store_for(directory, baseline, start):
    return directory / ('browse.store' if start == baseline['periodStarts'][0]
                        else 'period-' + start.replace('/', '') + '.store')


def read_rows(path, stock, start, end):
    with sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True) as db:
        db.row_factory = sqlite3.Row
        rows = list(db.execute('SELECT t.* FROM ZTRADE t JOIN ZSTOCK s ON t.ZSTOCK=s.Z_PK '
                              'WHERE s.ZSID=? AND t.ZDATETIME<? ORDER BY t.ZDATETIME',
                              (stock, stamp(end))))
    before = [dict(r) for r in rows if r['ZDATETIME'] < stamp(start)]
    valid = [dict(r) for r in rows if r['ZDATETIME'] >= stamp(start)]
    return (before[-1] if before else None), valid


def audit(rows, previous, base):
    result = dict(days=0, buys=0, sells=0, negativeSettlementDays=0,
                  minimumSettlement=0, occupiedCostTradingDays=0, lossTradingDays=0,
                  maxInvestTimes=0, maxHoldingDays=0)
    for row in rows:
        assert row['ZSIMRULE'] != '_', 'Preparation row in claimed effective simulation range'
        assert previous is not None, 'Valid rolling simulation must have its preparation predecessor'
        qty, sold, price = row['ZSIMQTYBUY'], row['ZSIMQTYSELL'], row['ZPRICECLOSE']
        def rnd(x): return math.floor(x + 0.5)
        buy = 0 if qty == 0 else rnd(price * qty * 1000) + max(20, rnd(price * qty * 1000 * .001425))
        sell = 0 if sold == 0 else price * sold * 1000 - max(20, rnd(price * sold * 1000 * .001425)) - rnd(price * sold * 1000 * .003)
        invested = row['ZSIMINVESTADDED'] + row['ZSIMINVESTBYUSER']
        before = base if previous['ZSIMRULE'] == '_' else previous['ZSIMAMTBALANCE']
        expected = before + base * invested - buy + sell
        # Existing accounting audit precision: cent-rounded execution, not a T-value tolerance.
        assert abs(expected - row['ZSIMAMTBALANCE']) < .011, ('cash', day(row['ZDATETIME']), expected, row['ZSIMAMTBALANCE'])
        expected_qty = (0 if previous['ZSIMQTYSELL'] > 0 or previous['ZSIMRULE'] == '_' else previous['ZSIMQTYINVENTORY']) + qty - sold
        assert expected_qty == row['ZSIMQTYINVENTORY'], ('inventory', day(row['ZDATETIME']))
        negative = validate_settlement(row, previous, base, invested, buy)
        result['negativeSettlementDays'] += int(negative)
        result['minimumSettlement'] = min(result['minimumSettlement'], row['ZSIMAMTBALANCE'])
        result['buys'] += int(qty > 0)
        result['sells'] += int(sold > 0)
        if row['ZSIMQTYINVENTORY'] > 0:
            result['occupiedCostTradingDays'] += row['ZSIMAMTCOST']
            result['lossTradingDays'] += int(row['ZSIMAMTPROFIT'] < 0)
        result['maxInvestTimes'] = max(result['maxInvestTimes'], row['ZSIMINVESTTIMES'])
        result['maxHoldingDays'] = max(result['maxHoldingDays'], row['ZSIMDAYS'])
        result['days'] += 1
        previous = row
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--completed-only', action='store_true', help='Audit completed runs while the remaining matrix is running')
    parser.add_argument('--previous-audit', type=Path, help='Reuse verified completed rows after checking every protected source hash')
    args = parser.parse_args()
    matrix = ROOT / 'exports/update-cycle-p5'
    results, protected = [], {}
    cached = {}
    if args.previous_audit:
        prior = json.loads(args.previous_audit.read_text())
        assert prior['status'] in ['partial', 'passed'] and prior['ruleCommit'] == RULE
        assert prior['dataRules'] == 'T4/S65' and prior['marketVersion'] == 7
        assert prior['formalStrategyValidated'] is False
        assert all(sha(Path(path)) == digest for path, digest in prior['sources'].items()), 'Previous audit source changed'
        protected.update(prior['sources'])
        protected[str(args.previous_audit.resolve())] = sha(args.previous_audit)
        cached = {r['run']: r for r in prior['rows']}
        assert len(cached) == len(prior['rows'])

    def protect(path):
        protected[str(path.resolve())] = sha(path)

    for sample in 'ABCDE':
        for window, suffix in [('fixed3y', 'fixed'), ('fullstress', 'full')]:
            name = 'p5-maturity-a-fixed-03' if (sample, suffix) == ('A', 'fixed') else f'p5-{sample.lower()}-{suffix}-01'
            if name in cached:
                assert cached[name]['sample'] == sample and cached[name]['window'] == window
                expected_reference = args.reference_root / f'baseline-{sample.lower()}-v40-s50-resumable-update-t3s64-9y-{window}-600w-20261016/baseline.json'
                assert str(expected_reference.resolve()) in protected
                assert str((matrix / name / 'summary.json').resolve()) in protected
                results.append(cached[name])
                print(f'{sample} {window}: reused unchanged verified audit', flush=True)
                continue
            run = matrix / name
            summary_path = run / 'summary.json'
            if args.completed_only and not summary_path.exists():
                continue
            summary = json.loads(summary_path.read_text())
            assert summary['status'] == 'passed' and summary['ruleCommit'] == RULE
            assert summary['formalStrategyValidated'] is False
            candidate = run / 'report'
            reference = args.reference_root / f'baseline-{sample.lower()}-v40-s50-resumable-update-t3s64-9y-{window}-600w-20261016'
            new = json.loads((candidate / 'baseline.json').read_text())
            old = json.loads((reference / 'baseline.json').read_text())
            comparison = json.loads((run / 'v40-comparison.json').read_text())
            assert comparison['candidateCommit'] == RULE
            assert comparison['score']['candidate'] == summary['combinedScore'] == new['combinedScore']
            for directory in [candidate, reference]:
                for p in directory.iterdir():
                    if p.suffix == '.store' or p.name.endswith('.store-wal') or p.name in ['baseline.json', 'manifest.json']:
                        protect(p)
            protect(summary_path)
            protect(run / 'v40-comparison.json')
            assert all(new[k] == old[k] for k in ['sampleID', 'periodStarts', 'through', 'moneyBaseWan', 'automaticInvestments'])
            old_stocks = {(s['id'], s['periodStart']): s for s in old['stocks']}
            stocks = []
            for stock in new['stocks']:
                prior = old_stocks[(stock['id'], stock['periodStart'])]
                assert stock['targetValidity'] == 'target-period-valid'
                start, end = stock['effectiveSimulationStart'], stock['periodEnd']
                previous, rows = read_rows(store_for(candidate, new, stock['periodStart']), stock['id'], start, end)
                _, old_rows = read_rows(store_for(reference, old, stock['periodStart']), stock['id'], start, end)
                before = {r['ZDATETIME']: r for r in old_rows}
                assert set(before) == {r['ZDATETIME'] for r in rows}
                changes = []
                for row in rows:
                    prev_row = before[row['ZDATETIME']]
                    fields = ['ZSIMQTYBUY', 'ZSIMQTYSELL']
                    if any(prev_row[k] != row[k] for k in fields):
                        changes.append(dict(date=day(row['ZDATETIME']), reference={k: prev_row[k] for k in fields}, candidate={k: row[k] for k in fields}))
                risk = audit(rows, previous, new['moneyBaseWan'] * 10000)
                stocks.append(dict(id=stock['id'], name=stock['name'], group=stock['group'], periodStart=stock['periodStart'], effectiveStart=start,
                                   roiDelta=stock['roi'] - prior['roi'], holdingDaysDelta=stock['averageDays'] - prior['averageDays'],
                                   gradeBefore=prior['grade'], gradeAfter=stock['grade'], moneyLackedBefore=prior['moneyLacked'], moneyLackedAfter=stock['moneyLacked'],
                                   changedExecutionDays=len(changes), firstExecutionDifference=changes[0] if changes else None, risk=risk))
            old_periods = {(p['group'], p['periodStart']): p for p in old['periods']}
            periods = [dict(group=p['group'], start=p['periodStart'], scoreDelta=p['score']-old_periods[(p['group'], p['periodStart'])]['score'],
                            roiDelta=p['averageROI']-old_periods[(p['group'], p['periodStart'])]['averageROI'],
                            holdingDaysDelta=p['averageDays']-old_periods[(p['group'], p['periodStart'])]['averageDays']) for p in new['periods']]
            results.append(dict(sample=sample, window=window, run=name, score=comparison['score'], periods=periods, stocks=stocks,
                                aggregateChangedCounts=dict(sum((Counter(p['counts']) for p in comparison['periods']), Counter())),
                                seconds=summary['seconds'], peakRSSBytes=summary['peakRSSBytes']))
            print(f'{sample} {window}: audited {sum(s["risk"]["days"] for s in stocks)} valid simulation days', flush=True)
    assert all(sha(Path(path)) == digest for path, digest in protected.items()), 'Read-only source changed'
    result = dict(status='passed' if len(results) == 10 else 'partial', completedRuns=len(results), ruleCommit=RULE, dataRules='T4/S65', marketVersion=7, formalStrategyValidated=False,
                  auditScriptSHA256=sha(Path(__file__)),
                  totalSimulationDays=sum(s['risk']['days'] for r in results for s in r['stocks']),
                  accounting='daily cash/inventory conservation and no unfunded purchase; signed settled loss allowed by existing contract',
                  sources=protected, rows=results,
                  limitations=['Combined main-case changes; not single-feature causal attribution.', 'Effective simulation range only; out-of-target dirty remains intentionally pending.',
                               'S-E01 new feature with original thresholds: diagnostic only. No threshold adoption or formal baseline.'])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('x') as stream:
        json.dump(result, stream, ensure_ascii=False, indent=2)
    print(json.dumps({k: result[k] for k in ['status', 'totalSimulationDays', 'ruleCommit']}))


if __name__ == '__main__':
    main()
