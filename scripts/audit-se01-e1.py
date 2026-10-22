#!/usr/bin/env python3
"""Read-only E1 gate/feature, complete-path, and accounting audit."""
import argparse
from collections import Counter
import csv
import json
import math
from pathlib import Path
import runpy
import sqlite3

ROOT = Path(__file__).resolve().parents[1]
C = runpy.run_path(str(ROOT / 'scripts/compare-update-cycle-diagnostics.py'))
A = runpy.run_path(str(ROOT / 'scripts/summarize-update-cycle-matrix.py'))


def z(values):
    total = 0.0
    for v in values: total += v
    mean = total / len(values)
    total = 0.0
    for v in values: total += (v-mean)*(v-mean)
    sd = math.sqrt(total/len(values))
    return 0.0 if sd == 0 else (values[-1]-mean)/sd


def market_features(path):
    raw = list(csv.DictReader(path.open()))
    highs, small, large, result = [], [], [], {}
    for i, row in enumerate(raw):
        high, close = float(row['high']), float(row['close'])
        highs.append(high)
        small.append(0.0 if i == 0 else 100*(close-max(highs[-125:]))/max(highs[-125:]))
        large.append(0.0 if i == 0 else 100*(close-max(highs[-250:]))/max(highs[-250:]))
        result[row['date'].replace('-', '/')] = (z(small[-125:]), z(large[-250:]), i+1)
    return result


def audit_run(candidate, reference, raw_market):
    new = json.loads((candidate/'baseline.json').read_text())
    old = json.loads((reference/'baseline.json').read_text())
    mode = new['diagnostic']['e1Mode']
    assert new['diagnostic']['mode'] == 'se01-e1-research'
    assert old['ruleCommit'] == '8932a9d78fb2c2e4376138e4dce1e2419603db50'
    assert new['dataRuleVersion'] == old['dataRuleVersion'] == 'T4/S65'
    assert all(new[k] == old[k] for k in ['sampleID','periodStarts','through','moneyBaseWan','automaticInvestments'])
    source_hashes = C['sources'](reference) | C['sources'](candidate)
    source_hashes[str(raw_market.resolve())] = A['sha'](raw_market)
    feature = market_features(raw_market)
    events = json.loads((candidate/'se01-events.json').read_text())
    for e in events:
        nz, oz, count = feature[e['date']]
        assert count >= 250, 'S-E01 event lacks expected market maturity'
        # Independent float formulas, not a relaxed comparison of persisted T/S.
        assert abs(nz-e['newZ']) < 1e-10 and abs(oz-e['oldZ']) < 1e-10
        selected = e['oldZ'] if mode == 'legacy' else e['newZ']
        assert e['selectedZ'] == selected
        def match(low, high, value):
            return (e['mature'] and all(v is not None and math.isfinite(v) for v in [value,e['oscMax9'],e['stockDelta'],e['marketDelta']])
                    and low < value < high and e['oscMax9'] < 0
                    and (e['stockDelta'] < .22 or e['marketDelta'] > 0))
        context = (e['normalSell'] and not e['profitExit'] and e['recoveryExit']
                   and (e['grade'] >= 1 or (e['lowDiff'] is not None and e['lowDiff'] > -.53)))
        assert e['controlSuppressed'] == bool(context and match(-.97,.83,e['newZ']))
        assert e['suppressed'] == bool(context and match(-1 if mode=='unit' else -.97,1 if mode=='unit' else .83,selected))
    periods, stocks, episodes = [], [], []
    for index, start in enumerate(new['periodStarts']):
        stock_entries = [s for s in new['stocks'] if s['periodStart'] == start]
        end = stock_entries[0]['periodEnd']
        file = 'browse.store' if index == 0 else 'period-'+start.replace('/','')+'.store'
        comparison = C['compare'](reference/file,candidate/file,C['date'](start),C['date'](end))
        assert not comparison['fieldDifferences'], 'Frozen P5 T changed'
        periods.append(comparison)
        for stock in stock_entries:
            assert stock['targetValidity'] == 'target-period-valid'
            previous, rows = A['read_rows'](candidate/file,stock['id'],stock['effectiveSimulationStart'],end)
            before, old_rows = A['read_rows'](reference/file,stock['id'],stock['effectiveSimulationStart'],end)
            assert len(rows) == len(old_rows)
            risk = A['audit'](rows,previous,new['moneyBaseWan']*10000)
            old_risk = A['audit'](old_rows,before,new['moneyBaseWan']*10000)
            changes = []
            for a,b in zip(old_rows,rows):
                assert a['ZDATETIME']==b['ZDATETIME']
                if any(a[k]!=b[k] for k in ['ZSIMQTYBUY','ZSIMQTYSELL']):
                    changes.append(dict(date=A['day'](a['ZDATETIME']),beforeBuy=a['ZSIMQTYBUY'],afterBuy=b['ZSIMQTYBUY'],beforeSell=a['ZSIMQTYSELL'],afterSell=b['ZSIMQTYSELL']))
                if mode == 'control':
                    for key in a:
                        if key.startswith(('ZT','ZV','ZSIM','ZROLL','ZPRICE')):
                            av,bv=a[key],b[key]
                            if key=='ZSIMANNUALWARNINGDATA':
                                av=json.loads(av) if av else None; bv=json.loads(bv) if bv else None
                            assert av==bv,(stock['id'],A['day'](a['ZDATETIME']),key,av,bv)
            stock_events = {e['date']:e for e in events if e['stock']==stock['id'] and e['period']==start}
            inside_episode = False
            for i,row in enumerate(rows):
                date = A['day'](row['ZDATETIME']);e=stock_events.get(date)
                if not inside_episode and e and e['suppressed']:
                    j=next((k for k in range(i,len(rows)) if rows[k]['ZSIMQTYSELL']>0),None)
                    finish=j if j is not None else len(rows)-1
                    segment=rows[i:finish+1]
                    episodes.append(dict(stock=stock['id'],period=start,start=date,end=A['day'](rows[finish]['ZDATETIME']),
                        censored=j is None,waitTradingDays=finish-i,startClose=row['ZPRICECLOSE'],endClose=rows[finish]['ZPRICECLOSE'],
                        closeChange=100*(rows[finish]['ZPRICECLOSE']/row['ZPRICECLOSE']-1),
                        minimumLowChange=100*(min(r['ZPRICELOW'] for r in segment)/row['ZPRICECLOSE']-1),
                        buyDays=sum(r['ZSIMQTYBUY']>0 for r in segment),addedCapital=sum(max(0,r['ZSIMINVESTADDED']) for r in segment)*new['moneyBaseWan']*10000))
                    inside_episode=True
                if row['ZSIMQTYSELL']>0: inside_episode=False
            prior=next(s for s in old['stocks'] if s['id']==stock['id'] and s['periodStart']==start)
            stocks.append(dict(id=stock['id'],name=stock['name'],period=start,roiDelta=stock['roi']-prior['roi'],
                holdingDaysDelta=stock['averageDays']-prior['averageDays'],gradeBefore=prior['grade'],gradeAfter=stock['grade'],
                changes=changes,risk=risk,referenceRisk=old_risk))
    if mode=='control': assert new['combinedScore']==old['combinedScore'] and new['periods']==old['periods']
    assert all(A['sha'](Path(path))==digest for path,digest in source_hashes.items())
    return dict(status='passed',mode=mode,sample=new['sampleID'],ruleCommit=new['ruleCommit'],baseRuleCommit=old['ruleCommit'],
        sources=source_hashes,score=dict(reference=old['combinedScore'],candidate=new['combinedScore'],difference=new['combinedScore']-old['combinedScore']),
        eventCount=len(events),suppressedDays=sum(e['suppressed'] for e in events),
        samePathGateDifferences=sum(e['suppressed']!=e['controlSuppressed'] for e in events),
        simulationDays=sum(s['risk']['days'] for s in stocks),periods=periods,stocks=stocks,episodes=episodes,
        limitations=['Same-path gate comparisons use each replay own state, not a full counterfactual.',
                     'Episode starts are actual suppressed recovery exits; next actual sale may use a different exit. Censored waits remain explicit.',
                     'Independent feature arithmetic tolerance is 1e-10; persisted control business fields and decisions must be exactly equal.'])


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    for name in ['candidate','reference','market','output']:p.add_argument('--'+name,type=Path,required=True)
    args=p.parse_args();result=audit_run(args.candidate,args.reference,args.market)
    with args.output.open('x') as f:json.dump(result,f,ensure_ascii=False,indent=2)
    print(json.dumps({k:result[k] for k in ['status','mode','sample','score','eventCount','suppressedDays','samePathGateDifferences','simulationDays']},ensure_ascii=False))
