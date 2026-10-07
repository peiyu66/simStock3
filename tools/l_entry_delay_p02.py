#!/usr/bin/env python3
"""LD-P02 causal data and coarse atoms only; no real composite search/replay."""
import bisect, collections as C, copy, csv, json, math, statistics, subprocess
from pathlib import Path
import numpy as np
import l_entry_delay_p01 as p1
import l_entry_delay_features as fx
import h_entry_composite as h
import h_entry_composite_p02 as prior
import h_entry_composite_search as gen
import market_technical as mt

R=p1.R
P=R/'exports/l-entry-delay-p01-20261001'
O=R/'exports/l-entry-delay-p02-20261001'
NAN=float('nan')
HASH={}

def save(name,value):
    p=O/name;t=p.with_suffix(p.suffix+'.tmp')
    t.write_text(json.dumps(value,ensure_ascii=False,indent=2,allow_nan=False)+'\n');t.replace(p)

def read(path):return json.loads(Path(path).read_text())

def protect(path):
    path=Path(path);assert path.is_file(),path
    HASH[str(path.relative_to(R))]=p1.sha(path)

def warning_valid(blob,stock):
    if not blob:return False
    r=json.loads(blob)
    assert r['formatVersion']==5 and r['dataRules']=='T3/S61'
    assert r['configuration']==dict(start=stock['ZDATESTART'],budget=stock['ZSIMMONEYBASE'],additions=stock['ZSIMINVESTAUTO'])
    s=r['snapshot'];floor=r.get('continuationFloor');high=r.get('continuationPriceHigh')
    assert (p1.finite(floor) and p1.finite(high) and high>0) if floor is not None else (high is None and not r['locallyReleased'])
    assert r['locallyReleased']==(s.get('localReleaseReason')is not None)
    fail=s.get('prewarningFailureDays')
    if fail is not None:assert fail in (0,1,2) and s['status']in ('normal','released') and s.get('prewarningReason')is not None
    else:assert s.get('prewarningReason')is None
    assert s['status']in ('unavailable','normal','caution','recovering','released')
    return True

def opportunity(anchor,dates,prices):
    assert len(dates)==len(prices)<=10 and all(p1.finite(x)and x>0 for x in [anchor,*prices])
    changes=[100*(x/anchor-1)for x in prices];lower=[i for i,x in enumerate(prices)if x<anchor]
    low=min(prices)if prices else None;high=max(prices)if prices else None
    lows=[i for i,x in enumerate(prices)if x==low];segments=[];signs=[]
    for i in lower:
        if segments and segments[-1][-1]==i-1:segments[-1].append(i)
        else:segments.append([i])
    for x in prices:
        sign='lower'if x<anchor else 'higher'if x>anchor else 'equal'
        if sign!='equal'and(not signs or signs[-1]!=sign):signs.append(sign)
    return dict(completeTen=len(prices)==10,observedLower=bool(lower),
        fullOpportunity=bool(lower)if len(prices)==10 else None,lowestClose=low,
        lowestDates=[dates[i]for i in lows],firstLowerDate=dates[lower[0]]if lower else None,
        lowerDays=len(lower),lowerSegments=[[dates[i]for i in seg]for seg in segments],
        minimumChangePct=min(changes)if changes else None,maximumChangePct=max(changes)if changes else None,
        firstLowestOffset=lows[0]+1 if lows else None,pathTransitions=signs,dailyChangePct=changes,
        maxRiseBeforeFirstLowPct=max([0,*changes[:lows[0]+1]])if lows else None,
        maxRiseAfterFirstLowPct=max(changes[lows[0]:])if lows else None)

def main():
    assert not(O/'completion.json').exists(),'Never overwrite completed evidence'
    p=read(P/'completion.json');assert p['status']=='complete'and p['summary']['ruleCommit']==p1.RULE
    for path,digest in {**read(P/'source-hashes.json'),**p['artifacts']}.items():
        assert p1.sha(R/path)==digest,path
        protect(R/path)
    protect(P/'completion.json')
    for f in ['l_entry_delay_p02.py','l_entry_delay_features.py','h_entry_composite.py','h_entry_composite_p02.py',
              'h_entry_composite_search.py','fwd_v20_path_discovery.py','market_technical.py']:
        protect(R/'tools'/f)
    prop=R/'exports/h-entry-composite-p01-20260929/proposed-features.json';protect(prop)
    assert subprocess.check_output(['git','rev-parse',p1.RULE+'^{commit}'],cwd=R,text=True).strip()==p1.RULE
    cat=[dict(c)for c in read(P/'feature-catalog.json')if c['status']!='excluded-empty-position']
    assert len(cat)==284
    for c in cat:
        c.update(anchorRole='original L decision prestate'if c['group']=='S'else 'same-day causal fixed input',
                 futureRole='unknown candidate state, always masked after anchor'if c['group']=='S'else 'fixed causal input',
                 timing='no future outcomes; previous, preview and current sources kept distinct')
        if c['name']=='price_phase':c['source']='Trade.tPricePathPhaseRaw, current fixed T3'
        if c['name']=='market_phase':c['source']='market-price-path.csv phase_raw, same date'
    fx.CAT=cat;fx.NEW=read(prop)
    names=[c['name']for c in cat];scols=[j for j,c in enumerate(cat)if c['group']=='S']
    events=read(P/'entry-events.json');identities=read(P/'identities.json')
    anchors={(e['sample'],e['window'],e['stock'],e['date']):e for e in events}
    selected={(*k[:3],day)for k,e in anchors.items()for day in [e['date'],*e['futureDates']]}
    ms=prior.market_inputs();market_dates=sorted(ms[1]);cache={};info={};checks=C.Counter();errors=C.defaultdict(float)
    def same(a,b,label,tol=1e-8):
        assert a==b or (p1.finite(a)and p1.finite(b)and math.isclose(a,b,abs_tol=tol,rel_tol=1e-11)),(label,a,b)
        checks[label]+=1
        if p1.finite(a)and p1.finite(b):errors[label]=max(errors[label],abs(a-b))
    for sample in 'CD':
        ident=identities[sample]
        with p1.db(R/ident['decisionBase']/'decisions.sqlite')as db:
            ev={(r['window_id'],r['stock_id'],r['trade_date']):dict(r)for r in db.execute('select e.*,s.stock_id from decision_events e join stocks s using(stock_key) where phase=1')}
            le={(r['window_id'],r['stock_id'],r['trade_date']):dict(r)for r in db.execute('select e.*,s.stock_id from decision_events e join stocks s using(stock_key) where phase=2')}
            fit={(r['window_id'],r['stock_id'],r['trade_date']):dict(r)for r in db.execute('select o.*,s.stock_id from strategy_fit_observations o join stocks s using(stock_key)')}
            technical={r['event_id']:dict(r)for r in db.execute('select l.event_id,o.* from event_observations l join technical_observations o using(observation_id)')}
        for w,(filename,start,end)in h.WINDOWS.items():
            wanted={k for k in selected if k[0]==sample and k[1]==w}
            with p1.db(R/ident['report']/filename)as db:
                for st in db.execute('select * from ZSTOCK'):
                    stock=dict(st);sid=stock['ZSID'];needed={k[3]for k in wanted if k[2]==sid}
                    if not needed:continue
                    assert stock['ZTECHNICALSTATEVERSION']==3 and stock['ZSIMULATIONSTATEVERSION']==61
                    assert stock['ZTECHNICALDIRTYFROM']is None and stock['ZSIMULATIONDIRTYFROM']is None
                    raw=[dict(r)for r in db.execute('select * from ZTRADE where ZSTOCK=? order by ZDATETIME',(stock['Z_PK'],))]
                    dates=[h.dateof(r['ZDATETIME'])for r in raw];assert dates==sorted(set(dates))
                    context=prior.ctx();previous_f=None
                    for n,r in enumerate(raw):
                        day=dates[n]
                        if day>max(needed):break
                        key=(sample,w,sid,day);ekey=key[1:];e=ev.get(ekey);obs=fit.get(ekey)
                        before=copy.deepcopy(context)if key in anchors else None
                        f=fx.values(raw,n,stock,start,e,obs,ms,context,checks)
                        assert set(names)<=set(f),(key,set(names)-set(f))
                        if key in anchors:
                            actual=le[ekey]
                            for field in ['grade','inventory_before','unit_cost_before','unit_roi_before','holding_days_before','invest_times_before','balance_before','roll_roi_before','roll_days_before','roll_rounds_before']:
                                same(e[field],actual[field],'HPrestateEqualsLPrestate',0)
                            assert e['buy_rule_before']==actual['buy_rule_before']==''
                            # Replace all current post-state numbers and the future: no entry feature may change.
                            changed=dict(r)
                            for col in r:
                                if col.startswith(('ZSIM','ZROLL'))and isinstance(r[col],(int,float)):changed[col]=123456789.
                            alt=fx.values(raw[:n]+[changed,{'ZPRICECLOSE':-999}],n,stock,start,e,obs,ms,copy.deepcopy(before),C.Counter(),verify_post=False)
                            for name in names:
                                assert f[name]==alt[name]or(not p1.finite(f[name])and not p1.finite(alt[name])),(key,name,'poststate/future leak')
                            checks['poststateAndFuturePoisonControls']+=1
                            if actual['event_id']in technical:
                                t=technical[actual['event_id']]
                                direct={'high_diff':'ZTHIGHDIFF','low_diff':'ZTLOWDIFF','kd_k':'ZTKDK','kd_d':'ZTKDD','kd_j':'ZTKDJ','osc':'ZTOSC',
                                        'ma20_days':'ZTMA20DAYS','ma60_days':'ZTMA60DAYS','ma20_diff':'ZTMA20DIFF','ma60_diff':'ZTMA60DIFF'}
                                for col,target in direct.items():same(t[col],r[target],'entryTechnicalSourceChecks',0)
                                same(t['close_change_percent'],100*(r['ZPRICECLOSE']/raw[n-1]['ZPRICECLOSE']-1),'entryCloseChangeChecks')
                            else:
                                assert actual['decision_score']>6
                                checks['technicalRecorderGapFromT3']+=1
                        if key in selected:
                            assert start<=day<=end and r['ZPRICECLOSE']>0 and r['ZDATASOURCE']=='TWSE'
                            checks['selectedOfficialRows']+=1
                            if n and warning_valid(raw[n-1]['ZSIMANNUALWARNINGDATA'],stock):checks['validPriorWarningRecords']+=1
                            for name,col,_,_ in h.old.BASE_FEATURE_SPECS:
                                if p1.finite(f[name]):same(f[name],r[col],'directTChecks',0)
                            for name,col,ext,_,_ in h.old.EXTREME_FLAG_SPECS:
                                if p1.finite(f[name]):same(f[name],float(r[col]==r[ext]),'extremeFlagChecks',0)
                            for c in fx.NEW:
                                col='Z'+c['name'].upper()
                                if c['group']=='T'and col in r and p1.finite(f[c['name']]):same(f[c['name']],r[col],'addedTChecks',0)
                            for name in ['tMa20DiffMax9','tMa20DiffMin9','tMa60DiffMax9','tMa60DiffMin9','tKdKMax9','tKdKMin9','tOscMax9','tOscMin9']:
                                if p1.finite(f[name]):same(f[name],(max if 'Max9'in name else min)(q['Z'+name[:-4].upper()]for q in raw[max(0,n-8):n+1]),'nineDayExtremaChecks',0)
                            for period in [20,60]:
                                if p1.finite(f[f'tMa{period}']):same(f[f'tMa{period}'],sum(q['ZPRICECLOSE']for q in raw[max(0,n-period+1):n+1])/min(n+1,period),'movingAverageChecks')
                            for name in h.DELTAS:
                                if p1.finite(f['delta_'+name]):same(f['delta_'+name],f[name]-previous_f[name],'deltaChecks',0)
                            vals=[f[name]if p1.finite(f[name])else NAN for name in names]
                            if key not in anchors:
                                for j in scols:vals[j]=NAN
                            cache[key]=vals
                            gaps=market_dates[bisect.bisect_right(market_dates,dates[n-1]):bisect.bisect_left(market_dates,day)]if n else []
                            info[key]=dict(close=r['ZPRICECLOSE'],volume=r['ZVOLUMECLOSE'],source=r['ZDATASOURCE'],
                                priceObservations=n+1,volumeObservations=context['vol'],previousDate=dates[n-1]if n else None,
                                marketPresent=day in ms[1],calendarGapDates=gaps,
                                warningRecordPresent=bool(n and raw[n-1]['ZSIMANNUALWARNINGDATA']))
                        previous_f=f
            print(json.dumps(dict(progress=sample+str(w),selected=len(cache),poisonControls=checks['poststateAndFuturePoisonControls'])),flush=True)
    assert set(cache)==selected and len(selected)==652
    # Frozen raw market formulas; no internet, no App tUpdate/simUpdate.
    market_raw=list(csv.DictReader((h.MARKET/'market-daily.csv').open()));frozen=list(csv.DictReader((h.MARKET/'market-technical.csv').open()))
    calc=mt.calculate_market(market_raw);assert len(calc)==len(frozen)
    for a,b in zip(calc,frozen):
        assert a['date']==b['date']
        for name,value in a.items():
            if name=='date':continue
            if isinstance(value,bool):assert ('true'if value else 'false')==b[name];checks['marketMaturityChecks']+=1
            else:same(float(value),float(b[name]),'marketNumericChecks')
    allops=[];matrices={};anchor_data={};keys_by={}
    for label,windows in [('discovery',(1,2)),('later',(3,))]:
        keys=[];X=[];entry=[];ops=[]
        for event in events:
            if event['window']not in windows:continue
            entry.append(len(keys));indices=[]
            for offset,day in enumerate([event['date'],*event['futureDates']]):
                key=(event['sample'],event['window'],event['stock'],day);vals=list(cache[key])
                if offset:
                    for j in scols:vals[j]=NAN
                indices.append(len(keys));X.append(vals)
                keys.append(dict(sample=key[0],window=key[1],stock=key[2],date=day,anchor=event['date'],event=event['eventID'],offset=offset,**info[key]))
            op=opportunity(event['price'],event['futureDates'],[keys[i]['close']for i in indices[1:]])
            gaps=[dict(date=keys[i]['date'],missingStockDates=keys[i]['calendarGapDates'])for i in indices[1:]if keys[i]['calendarGapDates']]
            zero=[keys[i]['date']for i in indices if keys[i]['volume']<=0]
            op.update(sample=event['sample'],window=event['window'],stock=event['stock'],anchor=event['date'],event=event['eventID'],
                      originalClose=event['price'],grade=event['grade'],indices=indices,partition=label,calendarGaps=gaps,nonpositiveVolumeDates=zero,
                      qualifiedOpportunity=op['fullOpportunity']if op['completeTen']and not gaps and not zero else None,
                      qualityStatus='window-truncated'if not op['completeTen']else 'calendar-gap-unknown'if gaps else 'volume-execution-unknown'if zero else 'qualified-price-observation')
            assert op['lowestDates']==event['minimumDates']and op['observedLower']==event['hasLowerPrice']
            ops.append(op)
        X=np.array(X,dtype=np.float64);entries=np.array(entry,dtype=np.int64)
        assert np.isnan(X[np.array([k['offset']>0 for k in keys])][:,scols]).all()
        np.savez_compressed(O/f'{label}.npz',X=X,valid=np.isfinite(X),anchors=entries)
        save(label+'-keys.json',keys);save(label+'-opportunities.json',ops)
        matrices[label]=X;anchor_data[label]=X[entries];keys_by[label]=keys;allops+=ops
    assert len(allops)==60 and sum(len(X)for X in matrices.values())==652
    stats=[];contracts=[]
    for j,c in enumerate(cat):
        avail={l:dict(anchors=len(X),finite=int(np.isfinite(X[:,j]).sum()),distinct=len(np.unique(X[np.isfinite(X[:,j]),j])))for l,X in anchor_data.items()}
        stats.append(dict(name=c['name'],group=c['group'],**avail))
        contracts.append(dict(column=j,name=c['name'],group=c['group'],parent=c['parent'],kind=c['kind'],source=c['source'],
           formulaReference=c.get('formulaReference'),currentExtractor='tools/l_entry_delay_features.py:values (derived from SD-P02; warning identity S61)',
           maturity='S: active nonnone decision Grade; trend>=125 and structural availability. T:250; volume:250 TWSE including zero; path:valid phase. M:family-specific warmup, same date.',
           anchorRole=c['anchorRole'],futureRole=c['futureRole'],missingPolicy='NaN+valid mask; no zero fill; composite OR conservatively requires all referenced inputs valid',availability=avail))
    save('feature-catalog.json',cat);save('field-contract.json',contracts);save('availability.json',stats)
    # Numeric definitions only, W1/W2 original-entry X. No opportunity labels supplied.
    atoms=gen.make_atoms(anchor_data['discovery'],cat)
    save('atoms-no-outcome-ranking.json',[dict(id=a.id,name=a.name,parent=a.parent,group=a.group,op=a.op,value=a.value)for a in atoms])
    counts=C.Counter(a.group for a in atoms);parents=C.defaultdict(C.Counter)
    for a in atoms:parents[a.group][a.parent]+=1
    pairs={}
    for g,k in [('T','T'),('S','S'),('M','M'),('T','S'),('T','M'),('S','M')]:
        pairs[g+k]=counts[g]*counts[k]if g!=k else(counts[g]**2-sum(v*v for v in parents[g].values()))//2
    budget=dict(atomCount=len(atoms),atomFields=len({a.name for a in atoms}),atomsBySource=dict(counts),pairCounts=pairs,AND2=sum(pairs.values()),
       AND3Upper=200*len(atoms),AND4Upper=200*len(atoms),ORUpper=19900,initialUpper=sum(pairs.values())+400*len(atoms)+19900,
       thresholdSource='C/D W1/W2 original L anchors only; no future rows, outcomes or W3 used',realCompositeEvaluations=0,
       note='AND2 exact by parent constraints; higher orders are adaptive beam upper bounds. Reserve all seven source strata; no repair budget included.')
    budget['batchesAtTwoMillion']=math.ceil(budget['initialUpper']/2000000);save('search-budget.json',budget)
    atom_names={a.name for a in atoms}
    save('field-dispositions.json',[dict(name=c['name'],group=c['group'],disposition='coarse-atoms-available'if c['name']in atom_names else 'retained-no-nonconstant-atom-in-discovery',availability=stats[j])for j,c in enumerate(cat)])
    def summary(ops):
        usable=[o for o in ops if o['qualifiedOpportunity']is not None]
        return dict(events=len(ops),completeTen=sum(o['completeTen']for o in ops),usable=len(usable),
            lower=sum(o['qualifiedOpportunity']for o in usable),noLower=sum(not o['qualifiedOpportunity']for o in usable),unknown=len(ops)-len(usable))
    save('opportunity-summary.json',dict(all=summary(allops),cells={s+str(w):summary([o for o in allops if o['sample']==s and o['window']==w])for s in 'CD'for w in (1,2,3)},
          unknownEvents=[{k:o[k]for k in ['sample','window','stock','anchor','qualityStatus','calendarGaps','nonpositiveVolumeDates']}for o in allops if o['qualifiedOpportunity']is None],retrospectiveOnly=True,strategyPerformanceMeasured=False))
    save('numerical-audit.json',dict(passed=True,checks=dict(checks),maxAbsoluteErrors=dict(errors),marketRows=len(calc),
                                  futureS='All 43 S fields are NaN after each anchor; no candidate S inferred'))
    for path,digest in HASH.items():assert p1.sha(R/path)==digest,path
    save('source-hashes.json',HASH)
    save('summary.json',dict(status='extraction-complete-awaiting-tests',stage='LD-P02',fields=len(cat),events=60,rows=652,
        anchorCounts={l:len(X)for l,X in anchor_data.items()},sourcesUnchanged=len(HASH),realCompositeEvaluations=0,strategyReplays=0,builds=0,
        downloads=0,simulatorOperations=0,ABEEffectsRead=False,opportunities=summary(allops),searchBudget=budget))
    print(json.dumps(dict(result='extraction-complete',opportunity=summary(allops),budget=budget),ensure_ascii=False),flush=True)

if __name__=='__main__':main()
