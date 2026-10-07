#!/usr/bin/env python3
"""AD-P02: reuse audited S61 extraction for ADD prestate, never replay a strategy.

The LD catalogue's eight held-position exclusions are restored. All 51 S
columns are masked after each anchor, including dates that are other anchors.
Only coarse atom definitions and a search budget are produced, no ranking.
"""
import collections as C
import copy
import json
import math
import numpy as np
import add_delay_p01 as p
import l_entry_delay_features as fx
import l_entry_delay_p02 as old
import h_entry_composite as h
import h_entry_composite_p02 as prior
import h_entry_composite_search as gen

O=p.R/'exports/add-delay-p02-20261002'
NAN=float('nan')

def save(name,value):
    q=O/name;t=q.with_suffix(q.suffix+'.tmp')
    t.write_text(json.dumps(value,ensure_ascii=False,indent=2,allow_nan=False)+'\n');t.replace(q)

def extract(raw,n,stock,start,e,fit,ms,context,checks,verify_post=True):
    distance=context['invest_distance']
    f=fx.values(raw,n,stock,start,e,fit,ms,context,checks,verify_post=verify_post)
    holding=bool(e and e['inventory_before']>0 and n)
    for name in ('inventory_before','unit_cost_before','unit_roi_before','holding_days_before','invest_times_before'):
        f[name]=e[name] if holding else NAN
    f['buy_rule_before']={'H':1.,'L':2.}.get(e['buy_rule_before'],NAN) if holding else NAN
    f['holding_cost_before']=raw[n-1]['ZSIMAMTCOST'] if holding else NAN
    f['tradingDaysSinceLastInvestment']=distance if holding and distance is not None else NAN
    return f

def main():
    assert not (O/'completion.json').exists(),'Completed evidence is immutable'
    O.mkdir(parents=True,exist_ok=True)
    protocol=p.read(O/'protocol.json')
    for rel,digest in p.read(p.O/'source-hashes.json').items():assert p.sha(p.source(p.R/rel))==digest,rel
    assert p.read(p.O/'audit.json')['passed'] and p.read(p.O/'slope-completion.json')['passed']
    for name in ('add_delay_p02.py','add_delay_p01.py','l_entry_delay_p02.py','l_entry_delay_features.py',
                 'h_entry_composite.py','h_entry_composite_p02.py','h_entry_composite_search.py',
                 'fwd_v20_path_discovery.py','market_technical.py'):
        p.source(p.R/'tools'/name)
    cat=p.read(p.R/'exports/l-entry-delay-p01-20261001/feature-catalog.json')
    assert len(cat)==292
    for c in cat:
        c.update(status='AD-P02-extracted',searched=False,
                 anchorRole='original automatic ADD prestate' if c['group']=='S' else 'same-day causal input',
                 futureRole='unknown candidate S; always masked' if c['group']=='S' else 'fixed causal input')
        c.pop('reason',None)
        c['timing']='current/prior only; no post-ADD or future outcome in inputs'
        c['missingPolicy']='NaN plus valid mask; all referenced inputs required for OR'
        if c['name']=='buy_rule_before':c.update(values=[1,2],encoding={'H':1,'L':2})
        if c['name']=='holding_cost_before':c['source']='previous completed Trade.simAmtCost before ADD'
        if c['name'] in ('inventory_before','unit_cost_before','unit_roi_before','holding_days_before','invest_times_before','buy_rule_before','holding_cost_before','tradingDaysSinceLastInvestment'):
            c['maturity']='valid held inventory prestate; independent of Grade activation; future unknown'
        if c['name']=='price_phase':c['source']='Trade.tPricePathPhaseRaw, current fixed T3'
        if c['name']=='market_phase':c['source']='same-date market-price-path.csv phase_raw'
    fx.CAT=cat;fx.NEW=p.read(p.R/'exports/h-entry-composite-p01-20260929/proposed-features.json')
    names=[c['name'] for c in cat];scols=[j for j,c in enumerate(cat) if c['group']=='S']
    events=p.read(p.O/'events.json');ident=p.read(p.O/'identities.json')
    anchors={(e['sample'],e['window'],e['stock'],e['date']):e for e in events}
    selected={(*k[:3],d) for k,e in anchors.items() for d in [e['date'],*[r['date'] for r in e['future']]]}
    ms=prior.market_inputs();cache={};checks=C.Counter()
    for sample in 'CD':
        with p.db(p.R/ident[sample]['decisionBase']/'decisions.sqlite') as db:
            ev={(r['window_id'],r['stock_id'],r['trade_date']):dict(r) for r in db.execute('select e.*,s.stock_id from decision_events e join stocks s using(stock_key) where phase=1')}
            adds={(r['window_id'],r['stock_id'],r['trade_date']):dict(r) for r in db.execute('select e.*,s.stock_id from decision_events e join stocks s using(stock_key) where phase=4')}
            fits={(r['window_id'],r['stock_id'],r['trade_date']):dict(r) for r in db.execute('select o.*,s.stock_id from strategy_fit_observations o join stocks s using(stock_key)')}
        for w,(filename,start,end) in enumerate(p.WINDOWS,1):
            with p.db(p.R/ident[sample]['report']/filename) as db:
                for st in db.execute('select * from ZSTOCK'):
                    stock=dict(st);sid=stock['ZSID'];needed={k[3] for k in selected if k[:3]==(sample,w,sid)}
                    if not needed:continue
                    assert stock['ZTECHNICALSTATEVERSION']==3 and stock['ZSIMULATIONSTATEVERSION']==61
                    assert stock['ZTECHNICALDIRTYFROM'] is None and stock['ZSIMULATIONDIRTYFROM'] is None
                    raw=[dict(r) for r in db.execute('select * from ZTRADE where ZSTOCK=? order by ZDATETIME',(stock['Z_PK'],))]
                    dates=[p.day(r['ZDATETIME']) for r in raw];assert dates==sorted(set(dates))
                    context=prior.ctx();previous=None
                    for n,r in enumerate(raw):
                        day=dates[n]
                        if day>max(needed):break
                        key=(sample,w,sid,day);e=ev.get(key[1:]);fit=fits.get(key[1:])
                        before=copy.deepcopy(context) if key in anchors else None
                        f=extract(raw,n,stock,start,e,fit,ms,context,checks)
                        if key in anchors:
                            a=adds[key[1:]]
                            for col in ('grade','inventory_before','unit_cost_before','unit_roi_before','holding_days_before','invest_times_before','balance_before','roll_roi_before','roll_days_before','roll_rounds_before','buy_rule_before'):
                                assert e[col]==a[col],(key,col,e[col],a[col]);checks['HvsADDPrestate']+=1
                            assert a['inventory_before']>0 and r['ZSIMQTYBUY']>0
                            changed=dict(r)
                            for col in changed:
                                if col.startswith(('ZSIM','ZROLL')) and isinstance(changed[col],(int,float)):changed[col]=123456789.
                            alt=extract(raw[:n]+[changed,{'ZPRICECLOSE':-999}],n,stock,start,e,fit,ms,copy.deepcopy(before),C.Counter(),False)
                            for name in names:
                                assert f[name]==alt[name] or (not p.finite(f[name]) and not p.finite(alt[name])),(key,name,'poststate/future leak')
                            checks['poststateAndFuturePoisonControls']+=1
                            p.same(f['unit_roi_before'],100*(r['ZPRICECLOSE']/f['unit_cost_before']-1))
                            p.same(f['holding_cost_before'],f['inventory_before']*f['unit_cost_before']*1000)
                            distance=None
                            for back,q in enumerate(reversed(raw[:n])):
                                if q['ZSIMINVESTADDED']+q['ZSIMINVESTBYUSER']==1:
                                    distance=back;break
                                if q['ZSIMDAYS']<=1:break
                            if distance is None:
                                assert not p.finite(f['tradingDaysSinceLastInvestment'])
                                checks['noPriorAdditionStructuralNil']+=1
                            else:
                                assert f['tradingDaysSinceLastInvestment']==distance
                                checks['priorAdditionDistance']+=1
                            checks['ADDStateIndependentChecks']+=3
                        if day in needed:
                            assert set(names)<=set(f),(key,set(names)-set(f))
                            assert start<=day<=end and r['ZDATASOURCE']=='TWSE' and r['ZPRICECLOSE']>0
                            for name,col,_,_ in h.old.BASE_FEATURE_SPECS:
                                if p.finite(f[name]):assert f[name]==r[col];checks['directTChecks']+=1
                            for name in h.DELTAS:
                                if p.finite(f['delta_'+name]):assert f['delta_'+name]==f[name]-previous[name];checks['deltaChecks']+=1
                            cache[key]=[f[name] if p.finite(f[name]) else NAN for name in names]
                        previous=f
            print(json.dumps(dict(progress=sample+str(w),selected=len(cache))),flush=True)
    assert set(cache)==selected
    matrices={};allops=[]
    for label,windows in [('discovery',(1,2)),('later',(3,))]:
        keys=[];X=[];entries=[];ops=[]
        for e in events:
            if e['window'] not in windows:continue
            entries.append(len(X));indices=[]
            for offset,day in enumerate([e['date'],*[r['date'] for r in e['future']]]):
                vals=list(cache[(e['sample'],e['window'],e['stock'],day)])
                if offset:
                    for j in scols:vals[j]=NAN
                indices.append(len(X));X.append(vals)
                keys.append(dict(sample=e['sample'],window=e['window'],stock=e['stock'],date=day,anchor=e['date'],event=e['eventID'],offset=offset))
            op=old.opportunity(e['price'],[r['date'] for r in e['future']],[r['price'] for r in e['future']])
            op.update(sample=e['sample'],window=e['window'],stock=e['stock'],anchor=e['date'],indices=indices,gateType=e['gateType'],originalEntryRule=e['buy_rule_before'])
            assert op['lowestDates']==e['minimumDates'] and op['observedLower']==e['hasLower']
            ops.append(op)
        X=np.asarray(X,dtype=np.float64);entries=np.asarray(entries,dtype=np.int64)
        assert np.isnan(X[np.array([k['offset']>0 for k in keys])][:,scols]).all()
        np.savez_compressed(O/(label+'.npz'),X=X,valid=np.isfinite(X),anchors=entries)
        save(label+'-keys.json',keys);save(label+'-opportunities.json',ops)
        matrices[label]=X[entries];allops+=ops
    assert len(allops)==143 and sum(len(json.loads((O/(l+'-keys.json')).read_text())) for l in matrices)==1550
    atoms=gen.make_atoms(matrices['discovery'],cat)
    counts=C.Counter(a.group for a in atoms);parents=C.defaultdict(C.Counter)
    for a in atoms:parents[a.group][a.parent]+=1
    pairs={g+k:counts[g]*counts[k] if g!=k else (counts[g]**2-sum(v*v for v in parents[g].values()))//2 for g,k in [('T','T'),('S','S'),('M','M'),('T','S'),('T','M'),('S','M')]}
    budget=dict(atoms=len(atoms),fieldsWithAtoms=len({a.name for a in atoms}),sourceAtoms=dict(counts),AND2BySource=pairs,AND2=sum(pairs.values()),
                AND3Upper=200*len(atoms),AND4Upper=200*len(atoms),ORUpper=19900,initialUpper=sum(pairs.values())+400*len(atoms)+19900,
                realCompositeEvaluations=0,thresholdSource='W1/W2 anchor inputs only; no outcomes or W3',upperScope='AND2 exhaustive under parent constraint; AND3/4/OR bounded beam, not exhaustive')
    save('atoms-no-outcome-ranking.json',[dict(id=a.id,name=a.name,parent=a.parent,group=a.group,op=a.op,value=a.value) for a in atoms])
    save('search-budget.json',budget);save('feature-catalog.json',cat)
    save('availability.json',[dict(name=c['name'],group=c['group'],disposition='coarse-atoms-available' if any(a.name==c['name'] for a in atoms) else 'retained-no-nonconstant-atom',
        availability={l:dict(anchors=len(X),finite=int(np.isfinite(X[:,j]).sum()),distinct=len(np.unique(X[np.isfinite(X[:,j]),j]))) for l,X in matrices.items()}) for j,c in enumerate(cat)])
    for rel,digest in p.HASH.items():assert p.sha(p.R/rel)==digest,rel
    save('source-hashes.json',p.HASH)
    save('completion.json',dict(status='complete',stage='AD-P02',fields=len(cat),SFields=len(scols),events=143,rows=1550,distinctRows=len(selected),
         checks=dict(checks),futureS='All S masked after every anchor',sourcesUnchanged=len(p.HASH),builds=0,strategyReplays=0,realCompositeEvaluations=0,
         searchBudget=budget,artifacts={q.name:p.sha(q) for q in O.iterdir() if q.is_file()}))
    print(json.dumps(dict(status='complete',checks=dict(checks),budget=budget)),flush=True)

if __name__=='__main__':main()
