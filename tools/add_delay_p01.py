#!/usr/bin/env python3
"""AD-P01: automatic held-position buy inventory and eight frozen hypotheses.

Read-only v37 C/D data, no strategy replay or fitted threshold search. The
DecisionBase ADD flag is capital admission, so actual qty is checked separately.
Future S is deliberately unknown after suppressing an addition.
"""
from pathlib import Path
from datetime import datetime, timedelta, timezone
import collections as C
import csv
import hashlib
import json
import math
import sqlite3
import subprocess
import time

R = Path(__file__).resolve().parents[1]
O = R / 'exports/add-delay-p01-20261002'
RULE = '7ba8447fbf207484ab305cad0c6beca216da8c93'
STRATEGY = 's49-sell-delay-f03-r1-20261001'
M = R / 'exports/market-data/taiex/snapshots/taiex-market-mt1-20260722-a00beac8d4af'
MP = R / 'exports/market-data/taiex/research/mkt-pp-p1-taiex-price-path-f712b360c322/market-price-path.csv'
WINDOWS = [('browse.store',20170722,20200722), ('period-20200722.store',20200722,20230722), ('period-20230722.store',20230722,20260722)]
HASH = {}

def sha(p):
    h = hashlib.sha256()
    with p.open('rb') as f:
        for block in iter(lambda: f.read(1024*1024), b''): h.update(block)
    return h.hexdigest()

def source(p):
    p = Path(p)
    HASH.setdefault(str(p.relative_to(R)), sha(p))
    return p

def read(p): return json.loads(source(p).read_text())

def save(n, x):
    p = O/n
    tmp = p.with_suffix(p.suffix+'.tmp')
    tmp.write_text(json.dumps(x, ensure_ascii=False, indent=2, allow_nan=False)+'\n')
    tmp.replace(p)

def db(p):
    source(p)
    for suffix in ('-wal','-shm'):
        q = Path(str(p)+suffix)
        if q.exists():
            source(q)
            if suffix == '-wal': assert q.stat().st_size == 0, ('nonempty WAL', p)
    c = sqlite3.connect(p.as_uri()+'?mode=ro&immutable=1',uri=True)
    c.row_factory = sqlite3.Row
    assert c.execute('pragma quick_check').fetchone()[0] == 'ok'
    return c

def day(n):
    return int((datetime(2001,1,1,tzinfo=timezone.utc)+timedelta(seconds=n,hours=8)).strftime('%Y%m%d'))

def finite(x): return isinstance(x,(int,float)) and math.isfinite(x)

def same(a,b): assert math.isclose(a,b,rel_tol=1e-10,abs_tol=1e-6),(a,b)

def rnd(v): return math.floor(v+.5)

def features(r,n,d,market,path,e=None,fit=None):
    m = market.get(d,{}); p = path.get(d,{})
    mature = n+1 >= 250
    market_ready = int(m.get('price_observation_count',0)) >= 250
    active = bool(e and fit and e['grade'] != 0 and fit['grade_activation_passed'] and fit['is_finite'])
    return dict(kd_j=r['ZTKDJ'] if mature and finite(r['ZTKDJ']) else None,
                osc=r['ZTOSC'] if mature and finite(r['ZTOSC']) else None,
                market_osc=float(m['market_osc']) if market_ready and m.get('market_osc') not in ('',None) else None,
                market_phase=int(p['phase_raw']) if p and int(p['phase_raw'])!=0 else None,
                unit_roi_before=e['unit_roi_before'] if e and e['inventory_before']>0 else None,
                grade=e['grade'] if active else None,
                prior_fit_trend=fit['fit_trend'] if active and fit['fit_observation_count']>=125 and finite(fit['fit_trend']) else None)

def terms(spec): return spec['terms'] if spec['op']=='all' else [t for branch in spec['terms'] for t in branch]

def evaluate(spec,f):
    # Frozen conservative contract: all underlying inputs finite, even for OR.
    if not all(finite(f.get(t[0])) for t in terms(spec)): return None
    def term(t):
        v=f[t[0]]
        return v<t[2] if t[1]=='lt' else v in t[2]
    if spec['op']=='all': return all(term(t) for t in spec['terms'])
    return any(all(term(t) for t in branch) for branch in spec['terms'])

def stats(events):
    full=[e for e in events if e['futureCount']==10]
    return dict(events=len(events),stocks=len({e['stock'] for e in events}),dates=len({e['date'] for e in events}),
                completeTen=len(full),censored=len(events)-len(full),lowerOpportunity=sum(e['hasLower'] for e in full),
                noLower=sum(not e['hasLower'] for e in full),observedLowerCensored=sum(e['hasLower'] for e in events if e['futureCount']<10),
                originalExitWithinTen=sum(e['originalExitOffset'] is not None for e in events),
                nextOriginalAddWithinTen=sum(e['nextOriginalAddOffset'] is not None for e in events),
                gateTypes=dict(C.Counter(e['gateType'] for e in events)),
                ae04=sum(e['unit_roi_before'] < -50 for e in events),
                ae02Eligible=sum(e['unit_roi_before'] < -45 and e['decisionGrade']>=1 for e in events),
                originalEntryTypes=dict(C.Counter(e['buy_rule_before'] for e in events)))

def main():
    t0=time.monotonic()
    assert not (O/'completion.json').exists(), 'Completed evidence is immutable'
    protocol=read(O/'protocol.json'); specs=read(O/'candidate-specs.json')
    assert sha(O/'candidate-specs.json') == protocol['candidateSpecSha256']
    assert subprocess.check_output(['git','rev-parse',RULE+'^{commit}'],cwd=R,text=True).strip()==RULE
    for fn in ('technical.swift','dataModel.swift','RollingContext.swift','InternalBacktestDecisionBase.swift'):
        p=source(R/'simStock3'/fn)
        assert p.read_bytes()==subprocess.check_output(['git','show',RULE+':simStock3/'+fn],cwd=R)
    market={};path={}
    for p,target in [(M/'market-technical.csv',market),(MP,path)]:
        with source(p).open() as f: target.update({int(row['date'].replace('-','')):row for row in csv.DictReader(f)})
    source(M/'market-daily.csv')
    events=[]; identities={};counts=C.Counter();qualified_no_purchase=[];cell=[]
    for sample in 'CD':
        report=R/'exports/backtest-reports'/f'baseline-{sample.lower()}-v37-s49-sell-delay-f03-r1-t3s61-9y-fixed3y-600w-20261001'
        base=R/'exports/backtest-decision-bases'/f'{sample.lower()}-abcd9-v3-{STRATEGY}-t3-s61-7ba8447fbf20-fixed3y-20260722-v23'
        manifests=[]
        for folder in (report,base):
            m=read(folder/'manifest.json')
            for k,v in dict(ruleCommit=RULE,ruleVersion=STRATEGY,dataRuleVersion='T3/S61',sampleID=sample,through='2026/07/22',moneyBaseWan=600,automaticInvestments=2,stockCount=10).items(): assert m[k]==v,(k,m[k])
            assert source(folder/'.complete').read_text().strip()==m.get('runID',m.get('decisionBaseID'))
            manifests.append(m)
        rm,bm=manifests; baseline=read(report/'baseline.json');source(report/'periods.csv')
        for k in ('ruleCommit','ruleVersion','dataRuleVersion','sampleID','runID','through'):assert baseline[k]==rm[k]
        assert bm['formatVersion']==6
        assert rm['marketInput']['dailySHA256']==sha(M/'market-daily.csv')
        assert rm['marketInput']['pricePathSHA256']==sha(MP)
        assert rm['marketInput']['marketTechnicalVersion']=='6'
        with db(base/'decisions.sqlite') as c:
            meta=dict(c.execute('select key,value from metadata'))
            for k in ('ruleCommit','ruleVersion','dataRuleVersion','sampleID','through','decisionBaseID'): assert meta[k]==bm[k]
            assert meta['formatVersion']=='6'
            for table,key in [('decision_events','eventCount'),('event_votes','voteCount'),('event_gates','gateCount'),('strategy_fit_observations','strategyFitObservationCount')]:assert c.execute('select count(*) from '+table).fetchone()[0]==bm[key]
            adds=[dict(e) for e in c.execute('select e.*,s.stock_id,s.name,s.group_name from decision_events e join stocks s using(stock_key) where phase=4')]
            fits={(e['window_id'],e['stock_id'],e['trade_date']):dict(e) for e in c.execute('select o.*,s.stock_id from strategy_fit_observations o join stocks s using(stock_key)')}
            gates=C.defaultdict(set)
            for x in c.execute('select g.event_id,r.rule_id from event_gates g join rules r using(rule_key)'):gates[x[0]].add(x[1])
            votes=C.defaultdict(float)
            for x in c.execute('select event_id,contribution from event_votes'):votes[x[0]]+=x[1]
        identities[sample]=dict(report=str(report.relative_to(R)),decisionBase=str(base.relative_to(R)),metadata=meta,combinedScore=baseline['combinedScore'])
        for w,(file,start,end) in enumerate(WINDOWS,1):
            before=len(events)
            with db(report/file) as c:
                stocks=list(c.execute('select * from ZSTOCK'));assert len(stocks)==10
                for st in stocks:
                    assert st['ZTECHNICALSTATEVERSION']==3 and st['ZSIMULATIONSTATEVERSION']==61
                    assert st['ZTECHNICALDIRTYFROM'] is None and st['ZSIMULATIONDIRTYFROM'] is None
                    raw=[dict(r) for r in c.execute('select * from ZTRADE where ZSTOCK=? order by ZDATETIME',(st['Z_PK'],))]
                    dates=[day(r['ZDATETIME']) for r in raw];idx={d:i for i,d in enumerate(dates)};assert len(idx)==len(raw)
                    ae=[e for e in adds if e['window_id']==w and e['stock_id']==st['ZSID']]
                    counts['addDecisionRows']+=len(ae);counts['plannedADD']+=sum(e['planned_action']=='ADD' for e in ae)
                    expected=set();actual=set()
                    for n,r in enumerate(raw):
                        if n and start<=dates[n]<=end and raw[n-1]['ZSIMQTYINVENTORY']>0 and r['ZSIMQTYBUY']>0 and not r['ZSIMREVERSED'] and not r['ZSIMINVESTBYUSER']:
                            assert r['ZSIMINVESTADDED']==1;actual.add(dates[n])
                    for e in ae:
                        n=idx[e['trade_date']];r=raw[n];prev=raw[n-1];g=gates[e['event_id']]
                        same(votes[e['event_id']],e['decision_score']);counts['addVoteSumsVerified']+=1
                        if e['executed_action']!='ADD':continue
                        counts['capitalADD']+=1
                        assert e['planned_action']=='ADD' and 'A-E' in g and r['ZSIMINVESTADDED']==1
                        assert e['inventory_before']>0 and r['ZSIMQTYSELL']==0
                        if r['ZSIMREVERSED'] or r['ZSIMINVESTBYUSER']:
                            counts['manualExcluded']+=1;continue
                        if r['ZSIMQTYBUY']<=0:
                            qualified_no_purchase.append(dict(sample=sample,window=w,stock=st['ZSID'],date=e['trade_date'],balance=e['balance_before']))
                            continue
                        expected.add(e['trade_date'])
                        same(e['inventory_before'],prev['ZSIMQTYINVENTORY']);same(e['unit_cost_before'],prev['ZSIMUNITCOST'])
                        same(e['unit_roi_before'],100*(r['ZPRICECLOSE']-prev['ZSIMUNITCOST'])/prev['ZSIMUNITCOST'])
                        same(e['invest_times_before'],prev['ZSIMINVESTTIMES']);same(e['balance_before'],prev['ZSIMAMTBALANCE'])
                        aroi=e['decision_score']>=3 and (e['unit_roi_before']<(-32.5 if e['grade']>=0 else -30) or (e['unit_roi_before']< -25 and (e['holding_days_before']<180 or e['holding_days_before']>360)))
                        alow=-10<e['unit_roi_before']<1 and r['ZSIMRULE']=='L' and e['decision_score']>=(2 if e['grade']<=-2 else 3) and e['holding_days_before']<60
                        assert aroi==('A-T01' in g) and alow==('A-T02' in g) and (aroi or alow)
                        # Same-day injection, fees and actual inventory independently reconcile.
                        cost=rnd(r['ZPRICECLOSE']*r['ZSIMQTYBUY']*1000)+max(20,rnd(r['ZPRICECLOSE']*r['ZSIMQTYBUY']*1000*.001425))
                        same(r['ZSIMAMTBALANCE'],e['balance_before']+6000000-cost)
                        same(r['ZSIMQTYINVENTORY'],e['inventory_before']+r['ZSIMQTYBUY'])
                        same(r['ZSIMAMTCOST'],prev['ZSIMAMTCOST']+cost)
                        same(r['ZSIMINVESTTIMES'],e['invest_times_before']+1)
                        future=[j for j in range(n+1,min(len(raw),n+11)) if dates[j]<=end]
                        assert all(raw[j]['ZDATASOURCE']=='TWSE' for j in [n,*future])
                        prices=[raw[j]['ZPRICECLOSE'] for j in future];anchor=r['ZPRICECLOSE']
                        fit=fits.get((w,st['ZSID'],e['trade_date']))
                        if fit and finite(fit['fit_trend']): same(fit['fit_trend'],prev['ZSIMFITTREND'])
                        f=features(r,n,e['trade_date'],market,path,e,fit)
                        # Future and current POST state cannot change these pre-decision inputs.
                        poison={k:(999999 if k.startswith(('ZSIM','ZROLL')) else v) for k,v in r.items()}
                        assert features(poison,n,e['trade_date'],market,path,e,fit)==f
                        fut=[dict(offset=k,date=dates[j],price=raw[j]['ZPRICECLOSE'],changePct=100*(raw[j]['ZPRICECLOSE']/anchor-1),
                                  features=features(raw[j],j,dates[j],market,path),baselineSold=raw[j]['ZSIMQTYSELL']>0,
                                  baselineAdded=raw[j]['ZSIMINVESTADDED']>0) for k,j in enumerate(future,1)]
                        low=min(prices) if prices else None
                        events.append(dict(sample=sample,window=w,stock=st['ZSID'],name=st['ZSNAME'],group=e['group_name'],date=e['trade_date'],
                            price=anchor,qty=r['ZSIMQTYBUY'],eventID=e['event_id'],decisionGrade=e['grade'],gateType='A-T01' if aroi else 'A-T02',
                            originalRule=r['ZSIMRULE'],buy_rule_before=e['buy_rule_before'],unit_roi_before=e['unit_roi_before'],holdingDays=e['holding_days_before'],
                            investTimesBefore=e['invest_times_before'],features=f,future=fut,futureCount=len(future),
                            hasLower=any(p<anchor for p in prices),minimumClose=low,minimumDates=[dates[j] for j in future if raw[j]['ZPRICECLOSE']==low],
                            firstLower=next((k for k,p in enumerate(prices,1) if p<anchor),None),
                            originalExitOffset=next((x['offset'] for x in fut if x['baselineSold']),None),
                            nextOriginalAddOffset=next((x['offset'] for x in fut if x['baselineAdded']),None)))
                        counts['actualPurchasePrestateAndAccountingChecks']+=1
                    assert actual==expected,(sample,w,st['ZSID'],actual^expected)
                    counts['stockWindowsChecked']+=1
            cell.append(dict(sample=sample,window=w,**stats(events[before:])))
            save('progress.json',dict(stage='event-extraction',sample=sample,window=w,events=len(events)))
            print(sample,w,'events',len(events)-before,flush=True)
    save('events.json',events);save('identities.json',identities)
    save('inventory.json',dict(counts=dict(counts),summary=stats(events),cells=cell,noPurchase=qualified_no_purchase,
        byGate={g:stats([e for e in events if e['gateType']==g]) for g in ('A-T01','A-T02')}))
    rows=[];evaluations=0
    for spec in specs:
        has_s=bool({t[0] for t in terms(spec)} & {'grade','prior_fit_trend','unit_roi_before'})
        for e in events:
            match=evaluate(spec,e['features']);evaluations+=1
            row={k:e[k] for k in ('sample','window','stock','date','gateType','hasLower','futureCount')}
            row.update(candidate=spec['id'],matched=match,release='not-triggered',releaseOffset=None,releaseChangePct=None)
            if match:
                if has_s:row['release']='unknown-own-S'
                else:
                    row['release']='censored' if e['futureCount']<10 else 'no-release-within-ten'
                    for x in e['future']:
                        v=evaluate(spec,x['features']);evaluations+=1
                        if v is None:
                            row['release']='unknown-input';break
                        if not v:
                            row.update(release='lower' if x['price']<e['price'] else 'higher' if x['price']>e['price'] else 'equal',
                                       releaseOffset=x['offset'],releaseChangePct=x['changePct']);break
            rows.append(row)
    assert evaluations<=protocol['maxFormulaRows']
    save('candidate-events.json',rows)
    summaries=[]
    for spec in specs:
        group=[r for r in rows if r['candidate']==spec['id']]
        out=dict(id=spec['id'],source=spec['source'],hypothesis=spec['hypothesis'],formula=spec)
        for label,ws in [('discovery',(1,2)),('laterWindow',(3,)),('all',(1,2,3))]:
            rs=[r for r in group if r['window'] in ws];hits=[r for r in rs if r['matched']]
            out[label]=dict(hits=len(hits),unknown=sum(r['matched'] is None for r in rs),stocks=len({r['stock'] for r in hits}),dates=len({r['date'] for r in hits}),
                completeLower=sum(r['hasLower'] and r['futureCount']==10 for r in hits),completeNoLower=sum(not r['hasLower'] and r['futureCount']==10 for r in hits),
                censored=sum(r['futureCount']<10 for r in hits),release=dict(C.Counter(r['release'] for r in hits)),gateTypes=dict(C.Counter(r['gateType'] for r in hits)))
        summaries.append(out)
    save('candidate-summary.json',summaries)
    save('analysis-counts.json',dict(formulaRows=evaluations,candidates=len(specs),generatedNewThresholds=0,strategyReplays=0,seconds=time.monotonic()-t0))
    save('source-hashes.json',HASH)
    for p,h in HASH.items():assert sha(R/p)==h,p
    print(json.dumps(dict(inventory=stats(events),formulaRows=evaluations,sourceFiles=len(HASH)),ensure_ascii=False))

if __name__=='__main__': main()
