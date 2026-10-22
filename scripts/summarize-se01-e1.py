#!/usr/bin/env python3
"""Read-only E1 summary; same effective dates on both arms, no strategy fitting."""
import argparse
from collections import Counter
import json
from pathlib import Path
import runpy
import statistics

ROOT = Path(__file__).resolve().parents[1]
A = runpy.run_path(str(ROOT / 'scripts/summarize-update-cycle-matrix.py'))
C = runpy.run_path(str(ROOT / 'scripts/compare-update-cycle-diagnostics.py'))


def state(row):
    if row is None:
        return None
    result = {}
    for key, value in row.items():
        if key.startswith(('ZSIM', 'ZROLL')):
            result[key] = json.loads(value) if key == 'ZSIMANNUALWARNINGDATA' and value else value
    return result


def summarize(folder):
    audit_path = folder / 'audit.json'
    audit = json.loads(audit_path.read_text())
    assert audit['status'] == 'passed'
    for path, digest in audit['sources'].items():
        assert A['sha'](Path(path)) == digest, ('changed audited source', path)
    report = folder / 'report'
    baseline = json.loads((report / 'baseline.json').read_text())
    sample, mode = baseline['sampleID'], audit['mode']
    full = len(baseline['periodStarts']) == 1
    reference_name = ('p5-maturity-a-fixed-03' if sample == 'A' and not full
                      else f'p5-{sample.lower()}-{"full" if full else "fixed"}-01')
    reference = ROOT / 'exports/update-cycle-p5' / reference_name / 'report'
    old = json.loads((reference / 'baseline.json').read_text())
    events = json.loads((report / 'se01-events.json').read_text())
    mechanism, differences, first_effects = Counter(), Counter(), []
    for item in baseline['stocks']:
        sid, start, end = item['id'], item['periodStart'], item['periodEnd']
        previous_item = next(x for x in old['stocks'] if x['id'] == sid and x['periodStart'] == start)
        effective = item['effectiveSimulationStart']
        assert effective == previous_item['effectiveSimulationStart']
        filename = ('browse.store' if start == baseline['periodStarts'][0]
                    else 'period-' + start.replace('/', '') + '.store')
        previous, rows = A['read_rows'](report / filename, sid, effective, end)
        prior, old_rows = A['read_rows'](reference / filename, sid, effective, end)
        own_events = {e['date']: e for e in events if e['stock'] == sid and e['period'] == start}
        first_recorded = False
        for row, before in zip(rows, old_rows):
            day = A['day'](row['ZDATETIME'])
            assert row['ZDATETIME'] == before['ZDATETIME']
            # P5's v40 comparator intentionally has different start dates. E1 does not.
            differences['gradeDays'] += C['grade'](row, C['date'](effective)) != C['grade'](before, C['date'](effective))
            differences['gradeTrendDays'] += any(row[k] != before[k] for k in C['TREND'])
            differences['warningDays'] += C['snapshot'](row) != C['snapshot'](before)
            trade_changed = any(row[k] != before[k] for k in ['ZSIMQTYBUY', 'ZSIMQTYSELL'])
            differences['tradeDays'] += trade_changed
            e = own_events.get(day)
            equal_prestate = state(previous) == state(prior)
            if e and e['suppressed'] != e['controlSuppressed']:
                if equal_prestate:
                    # Frozen raw/T + identical previous S make this an isolated same-day gate comparison.
                    assert not row['ZSIMREVERSED'] and not before['ZSIMREVERSED']
                    if row['ZSIMQTYSELL'] == before['ZSIMQTYSELL'] == 0:
                        mechanism['sameStateOtherSellGateAbsorbed'] += 1
                    elif row['ZSIMQTYSELL'] == 0:
                        mechanism['sameStateCandidateAddedWait'] += 1
                    elif before['ZSIMQTYSELL'] == 0:
                        mechanism['sameStateCandidateRemovedWait'] += 1
                    else:
                        raise AssertionError('Opposite suppression cannot both sell from equal prestate')
                else:
                    mechanism['differentPrestateGateDifferences'] += 1
            if trade_changed and not first_recorded:
                first_effects.append(dict(stock=sid, name=item['name'], period=start, date=day,
                    identicalPreviousState=equal_prestate, event=e,
                    beforeBuy=before['ZSIMQTYBUY'], afterBuy=row['ZSIMQTYBUY'],
                    beforeSell=before['ZSIMQTYSELL'], afterSell=row['ZSIMQTYSELL']))
                first_recorded = True
            previous, prior = row, before
    if mode == 'control':
        assert not any(differences.values()) and not first_effects
    risks = {}
    for key in ['buys', 'sells', 'negativeSettlementDays', 'occupiedCostTradingDays', 'lossTradingDays']:
        new_value = sum(s['risk'][key] for s in audit['stocks'])
        old_value = sum(s['referenceRisk'][key] for s in audit['stocks'])
        risks[key] = dict(reference=old_value, candidate=new_value, difference=new_value-old_value)
    episodes = audit['episodes']
    waits = [e['waitTradingDays'] for e in episodes]
    episode_summary = dict(count=len(episodes), censored=sum(e['censored'] for e in episodes),
        higherExit=sum(e['closeChange'] > 0 and not e['censored'] for e in episodes),
        lowerExit=sum(e['closeChange'] < 0 and not e['censored'] for e in episodes),
        unchangedExit=sum(e['closeChange'] == 0 and not e['censored'] for e in episodes),
        medianWait=statistics.median(waits) if waits else None, maxWait=max(waits, default=0),
        worstLowChange=min((e['minimumLowChange'] for e in episodes), default=0),
        addedCapital=sum(e['addedCapital'] for e in episodes))
    periods = []
    for p in baseline['periods']:
        prior_period = next(o for o in old['periods'] if (o['group'],o['periodStart']) == (p['group'],p['periodStart']))
        periods.append(dict(period=p['periodStart'],group=p['group'],score=p['score'],
            difference=p['score']-prior_period['score'],roiDelta=p['averageROI']-prior_period['averageROI'],
            holdingDaysDelta=p['averageDays']-prior_period['averageDays']))
    return dict(run=folder.name,mode=mode,sample=sample,window='fullstress' if full else 'fixed3y',
        score=audit['score'],suppressedDays=audit['suppressedDays'],eventCount=audit['eventCount'],
        samePathGateDifferences=audit['samePathGateDifferences'],simulationDays=audit['simulationDays'],
        differences=dict(differences),mechanisms=dict(mechanism),risk=risks,
        episodeSummary=episode_summary,episodes=episodes,periods=periods,stocks=audit['stocks'],firstEffects=first_effects,
        auditSHA256=A['sha'](audit_path))


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--completed-only',action='store_true')
    parser.add_argument('--previous',type=Path)
    args=parser.parse_args()
    cached={}
    if args.previous:
        cached={r['run']:r for r in json.loads(args.previous.read_text())['rows']}
    rows=[]
    for folder in sorted((ROOT/'exports/update-cycle-e1').glob('e1-*-??*')):
        audit=folder/'audit.json'
        if not audit.is_file(): continue
        if folder.name in cached:
            assert cached[folder.name]['auditSHA256']==A['sha'](audit)
            saved=json.loads(audit.read_text())
            assert all(A['sha'](Path(p))==h for p,h in saved['sources'].items())
            result=cached[folder.name]
        else: result=summarize(folder)
        rows.append(result)
        print(json.dumps({k:result[k] for k in ['run','score','differences','mechanisms','episodeSummary']},ensure_ascii=False),flush=True)
    if not args.completed_only:
        assert len(rows)==22 and len([r for r in rows if r['mode']=='control'])==2
    output=dict(status='partial' if args.completed_only else 'passed',rows=rows,
        limitations=[
            'Uses identical effective simulation starts for both E1 arms. Do not use v40 compatibility comparator grade/preparation counters embedded in raw audit periods as E1 effects.',
            'Same-state gate absorption follows technical.swift: S-E02 is the only later sell suppressor in these automatic, no-manual-operation fixtures.',
            'Episodes are observed paths, not isolated treatment effects; next exit may use other rules and censored waits remain explicit.',
            'N is frozen P5. Actual zero-difference E1 wiring controls are C and D fixed windows. No thresholds adopted.'
        ])
    with args.output.open('x') as f: json.dump(output,f,ensure_ascii=False,indent=2)
