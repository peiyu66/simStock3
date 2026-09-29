#!/usr/bin/env python3
"""HC-SW: existing flat paths only; no simulation or post-fill extrapolation."""
import json, sys, itertools, hashlib
from pathlib import Path
from collections import Counter, defaultdict
import numpy as np
import h_entry_composite as h

ROOT = Path(__file__).resolve().parents[1]
OLD = ROOT/'exports/h-entry-composite-20260923'
OUT = ROOT/'exports/h-entry-composite-shortwait-20260929'
def read(p): return json.loads(p.read_text())
def save(name, value):
    (OUT/name).write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False)+'\n')

def load_data():
    keys=[]; rounds=[]; arrays=[]
    for label in ('discovery','later'):
        kk=read(OLD/f'{label}-keys.json'); rr=read(OLD/f'{label}-rounds.json')
        for r in rr:
            for f in ('entry','end','decline','trough'):
                if r[f] is not None:r[f]+=len(keys)
        rounds+=rr;keys+=kk;arrays.append(np.load(OLD/f'{label}.npz')['X'])
    return np.concatenate(arrays),keys,rounds

def extract():
    hashes={}
    for folder in ('h-entry-composite-20260923','h-entry-composite-ab-20260928','h-entry-composite-reanalysis-20260928','h-entry-composite-r02-20260929'):
        for p,digest in read(ROOT/'exports'/folder/'completion.json')['artifacts'].items():
            assert h.sha(ROOT/p)==digest,p
            hashes[p]=digest
    save('source-hashes.json',hashes)
    X,keys,rounds=load_data()
    lookup={(k['sample'],k['window'],k['stock'],k['date']):i for i,k in enumerate(keys)}
    rmap={(r['sample'],r['window'],r['stock'],r['entry_date']):r for r in rounds}
    anchors=defaultdict(list); oldrows=[]
    for rule,folder in [('d03','h-entry-composite-ab-20260928'),('d05','h-entry-composite-ab-20260928'),('r02','h-entry-composite-r02-20260929')]:
        for sample in 'AB':
            src=ROOT/'exports'/folder
            audit=read(src/f'audit-{rule}-{sample.lower()}.json');assert audit['passed']
            run=next((src/'source/exports/backtest-candidate-runs').glob(f'hc-{rule}-{sample.lower()}-candidate-*'))
            manifest=read(run/'manifest.json')
            assert manifest['ruleCommit']==h.COMMIT and manifest['dataRuleVersion']=='T3/S57'
            assert (run/'.complete').read_text().strip()==manifest['runID']
            diag=read(run/'hc-entry-diagnostics.json')['records']
            feasible={(int(d['windowStart'].replace('-','')),d['stock'],int(d['date'].replace('-',''))):d for d in diag}
            for row in audit['firstTransactions']:
                w={20170722:1,20200722:2,20230722:3}[row['start']]
                key=(sample,w,row['stock'],row['date']);r=rmap[key];b=r['entry']
                fill=lookup[(sample,w,row['stock'],row['newDate'])] if row['newDate'] else None
                last=fill if fill is not None else max(i for i,k in enumerate(keys) if (k['sample'],k['window'],k['stock'])==key[:3])
                assert row['originalPrice']==keys[b]['close']
                assert fill is None or keys[fill]['close']==row['newPrice']
                days=[]
                for i in range(b,last+1):
                    k=keys[i];assert (k['sample'],k['window'],k['stock'])==key[:3]
                    d=feasible.get((row['start'],row['stock'],k['date']))
                    days.append(dict(index=i,date=k['date'],wait=i-b,price=k['close'],hFeasible=d is not None,oldSuppressed=d['suppressed'] if d else False,lFill=i==fill and row['newRule']=='L'))
                assert days[0]['hFeasible'] and days[0]['oldSuppressed']
                assert fill is None or row['newRule']=='L' or days[-1]['hFeasible']
                item=dict(id=r['id'],sample=sample,window=w,stock=r['stock'],source=rule,entry=r['entry_date'],price=r['entry_price'],originalExit=r['end_date'],closed=r['closed'],target=r['opportunity'],declineDate=keys[r['decline']]['date'] if r['decline'] is not None else None,fillDate=row['newDate'],fillRule=row['newRule'],wait=fill-b if fill is not None else None,priceSaving=100*(1-row['newPrice']/row['originalPrice']) if fill is not None else None,days=days)
                anchors[r['id']].append(item);oldrows.append(item)
            print('EXTRACTED',rule,sample,flush=True)
    unique=[]; overlaps=0
    for aid,versions in sorted(anchors.items()):
        # Identical original anchor, no trade yet: feasible H must be identical.
        chosen=max(versions,key=lambda r:len(r['days']))
        for v in versions:
            for a,b in zip(chosen['days'],v['days']):
                assert (a['index'],a['price'],a['hFeasible'])==(b['index'],b['price'],b['hFeasible']),(aid,a,b)
                overlaps+=1
        unique.append(dict(chosen,sources=[v['source'] for v in versions]))
    save('observed-paths.json',oldrows);save('unique-flat-paths.json',unique)
    summaries=[]
    for rule in ('d03','d05','r02'):
        for sample in 'AB':
            rows=[r for r in oldrows if r['source']==rule and r['sample']==sample]
            item=dict(rule=rule,sample=sample,entries=len(rows),actualMedianWait=float(np.median([r['wait'] for r in rows if r['wait'] is not None])),afterExit=sum(r['fillDate'] is not None and r['closed'] and r['fillDate']>r['originalExit'] for r in rows),horizons={})
            for limit in (3,5,10):
                actual=[r for r in rows if r['wait'] is not None and r['wait']<=limit and (not r['closed'] or r['fillDate']<=r['originalExit'])]
                first=[next((d for d in r['days'][1:] if d['wait']<=limit and (d['hFeasible'] or d['lFill']) and (not r['closed'] or d['date']<=r['originalExit'])),None) for r in rows]
                oracle=[any(d['wait']<=limit and d['price']<r['price'] and (d['hFeasible'] or d['lFill']) and (not r['closed'] or d['date']<=r['originalExit']) for d in r['days'][1:]) for r in rows]
                item['horizons'][limit]=dict(actualFills=len(actual),actualCheaper=sum(r['priceSaving']>0 for r in actual),firstFeasible=sum(d is not None for d in first),firstFeasibleCheaper=sum(d is not None and d['price']<r['price'] for r,d in zip(rows,first)),anyFeasibleCheaper=sum(oracle))
            summaries.append(item)
    save('diagnosis.json',dict(sourceArtifactsVerified=len(hashes),observedPaths=len(oldrows),uniqueAnchors=len(unique),overlappingDaysChecked=overlaps,summary=summaries))
    print('DIAGNOSIS',json.dumps(summaries),flush=True)

def matrices(rows, X, atoms):
    # Bit zero is the trigger. Remaining bits represent observed trading days.
    masks=np.zeros((len(atoms),len(rows)),np.uint16)
    hm=np.zeros(len(rows),np.uint16);lm=hm.copy()
    gains=np.zeros((len(rows),11)); dates=np.zeros((len(rows),11),np.int32)
    for n,r in enumerate(rows):
        dd=r['days'][:11];idx=[d['index'] for d in dd]
        for a in atoms:
            sig,_=h.atom_array(a,X[idx])
            masks[a['id'],n]=sum(1<<i for i,hit in enumerate(sig) if hit)
        for d in dd[1:]:
            t=d['wait'];dates[n,t]=d['date'];gains[n,t]=100*(1-d['price']/r['price'])
            # A known original exit is a retrospective cost screen only.
            if r['closed'] and d['date']>r['originalExit']:continue
            if d['hFeasible']:hm[n]|=1<<t
            if d['lFill']:lm[n]|=1<<t
    return masks,hm,lm,gains,dates

def search():
    X,keys,rounds=load_data(); atoms=read(OLD/'atoms.json')
    rows=[r for r in read(OUT/'unique-flat-paths.json') if r['window']<3]
    masks,hm,lm,gains,dates=matrices(rows,X,atoms)
    usable=[a['id'] for a in atoms if not a['name'].startswith(('s_','delta_s_'))]
    cells=[np.array([r['sample']==s and r['window']==w for r in rows]) for s in 'AB' for w in (1,2)]
    # Predeclared screening only, not adoption criteria or optimized cutoffs.
    save('search-protocol.json',dict(entries=len(rows),atoms=len(usable),horizon=10,minHitsPerCell=5,minStocksPerCell=3,minResolvedFractionPerCell=.8,selection='worst cell signed price saving per all observed anchors; unresolved has zero benefit and is reported separately',maxExpressions=1000000,beamPairs=200,shortlist=6,priceClip=10,knownThirdWindow=True))
    first=np.array([((v&-v).bit_length()-1) if v else 0 for v in range(2048)],np.int16)
    count=0;support_count=0;positive_count=0;retained=[]
    def batch(exprs,bits):
        nonlocal count,support_count,positive_count,retained
        count+=len(exprs)
        hits=(bits&1)!=0
        available=((~bits)&hm[None,:])|lm[None,:]
        wait=first[available&2046]
        resolved=hits&(wait>0)
        prices=gains[np.arange(len(rows))[None,:],wait]*resolved
        clipped=np.clip(prices,-10,10)
        means=np.stack([clipped[:,c].mean(axis=1) for c in cells],axis=1)
        support=np.ones(len(exprs),bool)
        for c in cells:
            total=hits[:,c].sum(axis=1)
            support&=(total>=5)&(resolved[:,c].sum(axis=1)>=.8*total)
        candidates=np.flatnonzero(support)
        for i in candidates:
            if any(len({rows[j]['stock'] for j in np.flatnonzero(hits[i]&c)})<3 for c in cells):continue
            support_count+=1;positive_count+=bool(np.all(means[i]>0))
            retained.append(dict(atoms=exprs[i],worst=float(means[i].min()),mean=float(means[i].mean()),hits=int(hits[i].sum()),resolved=int(resolved[i].sum()),cells=means[i].tolist()))
        if len(retained)>2000:
            retained=sorted(retained,key=lambda x:(x['worst'],x['mean']),reverse=True)[:800]
    for pos,a in enumerate(usable):
        js=[b for b in usable[pos+1:] if atoms[a]['parent']!=atoms[b]['parent']]
        if js:batch([[a,b] for b in js],masks[a][None,:]&masks[js])
        if pos%200==0:print('PAIR SEARCH',pos,'/',len(usable),'evaluated',count,flush=True)
    pairs=sorted(retained,key=lambda x:(x['worst'],x['mean']),reverse=True)
    beam=[];seen=set()
    for node in pairs:
        a,b=node['atoms'];signature=(masks[a]&masks[b]).tobytes()
        if signature in seen:continue
        seen.add(signature);beam.append(node)
        if len(beam)==200:break
    pair_count=count
    seen3=set()
    for node in beam:
        a,b=node['atoms'];js=[];exprs=[]
        for c in usable:
            expr=tuple(sorted((a,b,c)))
            if atoms[c]['parent'] in (atoms[a]['parent'],atoms[b]['parent']) or expr in seen3:continue
            seen3.add(expr);js.append(c);exprs.append(list(expr))
        if js:batch(exprs,masks[a][None,:]&masks[b][None,:]&masks[js])
    ranked=sorted(retained,key=lambda x:(x['worst'],x['mean']),reverse=True)
    unique=[];seen=set()
    for node in ranked:
        sig=np.bitwise_and.reduce(masks[node['atoms']],axis=0);signature=sig.tobytes()
        if signature in seen:continue
        seen.add(signature);unique.append(node)
        if len(unique)==200:break
    assert count<=1000000
    save('search-results.json',dict(evaluated=count,pairs=pair_count,triples=count-pair_count,supportPassed=support_count,positiveFourCells=positive_count,nodes=unique))
    chosen=[];entrymasks=[]
    for node in unique:
        if node['worst']<=0:continue
        hit=(np.bitwise_and.reduce(masks[node['atoms']],axis=0)&1)!=0
        if any(np.count_nonzero(hit&m)/max(1,np.count_nonzero(hit|m))>=.75 for m in entrymasks):continue
        chosen.append(dict(node,id=f'HC-SW{len(chosen)+1:02}',expression=h.format_expr([node['atoms']],atoms)))
        entrymasks.append(hit)
        if len(chosen)==6:break
    save('frozen.json',dict(candidates=chosen,selection='W1/W2 only; W3 already known',searchSHA=h.sha(OUT/'search-results.json')))
    print('SEARCH COMPLETE',count,'support',support_count,'positive',positive_count,[(c['id'],c['expression']) for c in chosen],flush=True)

def evaluate(expr, rows, X, atoms):
    sig,valid=h.eval_expr([expr],atoms,X);out=[]
    for r in rows:
        b=r['days'][0]['index'];hit=bool(sig[b]);fill=None
        assert not r['days'][0]['lFill'],'Immediate L needs separate zero-wait treatment'
        if hit:
            fill=next((d for d in r['days'][1:] if (d['hFeasible'] and not sig[d['index']]) or d['lFill']),None)
        out.append(dict(id=r['id'],sample=r['sample'],window=r['window'],stock=r['stock'],target=r['target'],hit=hit,wait=fill['wait'] if fill else None,date=fill['date'] if fill else None,entryDate=r['entry'],entryPrice=r['price'],price=fill['price'] if fill else None,saving=100*(1-fill['price']/r['price']) if fill else 0,afterExit=fill is not None and r['closed'] and fill['date']>r['originalExit'],beforeDecline=fill is not None and r['declineDate'] is not None and fill['date']<r['declineDate'],missingRelease=fill is not None and not valid[fill['index']],observedUntil=r['days'][-1]['date']))
    return out

def summarize(rows, limit):
    out={}
    for s,w in sorted({(r['sample'],r['window']) for r in rows}):
        rs=[r for r in rows if (r['sample'],r['window'])==(s,w)]
        hit=[r for r in rs if r['hit']]
        filled=[r for r in hit if r['wait'] is not None and r['wait']<=limit and not r['afterExit']]
        targets=[r for r in filled if r['target']]
        out[f'{s}{w}']=dict(anchors=len(rs),hits=len(hit),stocks=len({r['stock'] for r in hit}),resolved=len(filled),unresolved=len(hit)-len(filled),cheaper=sum(r['saving']>0 for r in filled),dearer=sum(r['saving']<0 for r in filled),equal=sum(r['saving']==0 for r in filled),meanAll=sum(r['saving'] for r in filled)/len(rs),clippedMeanAll=sum(np.clip(r['saving'],-10,10) for r in filled)/len(rs),meanFilled=float(np.mean([r['saving'] for r in filled])) if filled else None,medianWait=float(np.median([r['wait'] for r in filled])) if filled else None,targetHits=sum(r['target'] for r in hit),targetResolved=len(targets),targetSaving=sum(r['saving'] for r in targets),targetBeforeDecline=sum(r['beforeDecline'] for r in targets),missingRelease=sum(r['missingRelease'] for r in filled))
    return out

def review():
    X,keys,rounds=load_data();atoms=read(OLD/'atoms.json');rows=read(OUT/'unique-flat-paths.json')
    # Recover all original first fills from recorded feasible days and original expressions.
    oldrules={c['id'].lower().replace('hc-',''):c['expr'] for c in read(OLD/'frozen-candidates.json')['candidates']}
    oldrules.update({c['id'].lower().replace('hc-',''):c['expr'] for c in read(ROOT/'exports/h-entry-composite-reanalysis-20260928/frozen.json')['candidates']})
    checked=0
    for r in read(OUT/'observed-paths.json'):
        sig,_=h.eval_expr(oldrules[r['source']],atoms,X)
        fill=next((d for d in r['days'][1:] if (d['hFeasible'] and not sig[d['index']]) or d['lFill']),None)
        assert (fill['date'] if fill else None)==r['fillDate'],(r['id'],r['source'],fill,r['fillDate'])
        checked+=1
    # Independent scalar chronology against every retained vector-search node.
    scalarchecks=0
    train=[r for r in rows if r['window']<3]
    for node in read(OUT/'search-results.json')['nodes']:
        result=summarize(evaluate(node['atoms'],train,X,atoms),10)
        observed=[result[k]['clippedMeanAll'] for k in ('A1','A2','B1','B2')]
        assert np.allclose(observed,node['cells'],rtol=1e-12,atol=1e-12),(node,observed)
        scalarchecks+=1
    summaries=[]
    for node in read(OUT/'frozen.json')['candidates']:
        detail=evaluate(node['atoms'],rows,X,atoms)
        cells={limit:summarize(detail,limit) for limit in (3,5,10)}
        robust=[]
        for stock in sorted({r['stock'] for r in rows}):
            sub=summarize([r for r in detail if r['stock']!=stock],10)
            robust.append(dict(excluded=stock,means={k:v['meanAll'] for k,v in sub.items()}))
        sig,_=h.eval_expr([node['atoms']],atoms,X)
        coverage={}
        for s,w in sorted({(r['sample'],r['window']) for r in rounds}):
            allr=[r for r in rounds if (r['sample'],r['window'])==(s,w)]
            hits=[r for r in allr if sig[r['entry']]]
            observed_ids={r['id'] for r in detail if r['hit']}
            coverage[f'{s}{w}']=dict(totalOriginalH=len(allr),hits=len(hits),targets=sum(r['opportunity'] for r in hits),observedFlatPaths=sum(r['id'] in observed_ids for r in hits))
        # Diagnostic neighboring existing cuts only; no reranking or replacement.
        neighboring=[]
        for ai in node['atoms']:
            a=atoms[ai]
            same=[z for z in atoms if z['feature']==a['feature'] and z['op']==a['op']]
            if a['op'] not in ('lt','gt'):continue
            same.sort(key=lambda z:z['value']);ix=[z['id'] for z in same].index(ai)
            for j in (ix-1,ix+1):
                if 0<=j<len(same):
                    expr=[same[j]['id'] if v==ai else v for v in node['atoms']]
                    neighboring.append(dict(expression=h.format_expr([expr],atoms),cells=summarize(evaluate(expr,rows,X,atoms),10)))
        summaries.append({**node,'discoveryCells':node['cells'],'cells':cells,'detail':detail,'coverage':coverage,'leaveOneStockOut':robust,'neighbors':neighboring})
        print('REVIEW',node['id'],json.dumps(cells[10]),flush=True)
    save('review.json',summaries)
    save('verification.json',dict(originalFirstFillsReproduced=checked,independentScalarNodes=scalarchecks,sourceHashes=len(read(OUT/'source-hashes.json')),postFillStateExtrapolated=False))

def supplement():
    X,keys,rounds=load_data();atoms=read(OLD/'atoms.json');result=[]
    for node in read(OUT/'review.json'):
        hits=[r for r in node['detail'] if r['hit']]
        good=[r for r in hits if r['wait'] is not None and r['wait']<=10 and not r['afterExit']]
        targets=[r for r in good if r['target']]
        unresolved=[r for r in hits if r not in good]
        sig,_=h.eval_expr([node['atoms']],atoms,X)
        raw=[]
        for r in rounds:
            if not sig[r['entry']]:continue
            release=next((i for i in range(r['entry']+1,r['end']+1) if not sig[i]),None)
            raw.append(dict(id=r['id'],sample=r['sample'],window=r['window'],target=r['opportunity'],wait=release-r['entry'] if release is not None else None,saving=100*(1-keys[release]['close']/r['entry_price']) if release is not None else None))
        result.append(dict(id=node['id'],hits=len(hits),shortFills=len(good),cheaper=sum(r['saving']>0 for r in good),dearer=sum(r['saving']<0 for r in good),equal=sum(r['saving']==0 for r in good),targetHits=sum(r['target'] for r in hits),targetShortFills=len(targets),targetCheaper=sum(r['saving']>0 for r in targets),targetBeforeDecline=sum(r['beforeDecline'] for r in targets),targetSaving=sum(r['saving'] for r in targets),unresolved=dict(total=len(unresolved),outsideObservedPath=sum(r['wait'] is None for r in unresolved),knownAfterOriginalExit=sum(r['afterExit'] for r in unresolved),knownOver10Days=sum(r['wait'] is not None and r['wait']>10 for r in unresolved)),rawReleaseOnly=dict(originalHits=len(raw),releasedBy5=sum(r['wait'] is not None and r['wait']<=5 for r in raw),releasedBy10=sum(r['wait'] is not None and r['wait']<=10 for r in raw),neverWithinOriginalRound=sum(r['wait'] is None for r in raw))))
    ceiling={}
    for s in 'AB':
        targets=[r for r in rounds if r['sample']==s and r['opportunity']]
        ceiling[s]=dict(targets=len(targets),horizons={n:sum(any(keys[i]['close']<r['entry_price'] for i in range(r['decline'],min(r['entry']+n,r['end'])+1)) for r in targets) for n in (3,5,10)})
    save('supplement.json',dict(candidates=result,hindsightPriceOnlyCeiling=ceiling))
    # Explicit chronology and censoring tests; no arbitrary forced buy at expiry.
    a=[dict(id=0,feature=0,name='a',parent='a',op='gt',value=0),dict(id=1,feature=1,name='b',parent='b',op='gt',value=0)]
    xx=np.array([[1.,1.],[0,1],[0,1],[0,1]])
    base=dict(id='test',sample='A',window=1,stock='test',target=True,entry=1,price=100,originalExit=4,closed=True,declineDate=2,days=[dict(index=i,date=i+1,wait=i,price=p,hFeasible=q,lFill=False) for i,(p,q) in enumerate([(100,True),(90,False),(95,True),(96,True)])])
    def one(row=base, arr=xx):return evaluate([0,1],[row],arr,a)[0]
    assert one()['date']==3  # Cheap raw release on day 2 cannot buy without eligibility.
    small={**base,'days':base['days'][:2]}
    assert one(small)['date'] is None  # Do not extrapolate beyond the observed flat path.
    nohit=xx.copy();nohit[0,0]=0
    assert not one(arr=nohit)['hit'] and one(arr=nohit)['date'] is None
    earlyL={**base,'days':[dict(d,lFill=d['date']==2) for d in base['days']]}
    assert one(earlyL)['date']==2  # L can take over before a new H opportunity.
    late={**base,'originalExit':2}
    assert one(late)['afterExit'] and summarize([one(late)],10)['A1']['resolved']==0
    missing=xx.copy();missing[2,0]=np.nan
    assert one(arr=missing)['missingRelease']  # Missing means no restriction, explicitly labeled.
    v=read(OUT/'verification.json');v['chronologyBoundaryTests']=6
    for p,digest in read(OUT/'source-hashes.json').items():assert h.sha(ROOT/p)==digest,p
    v['finalSourceHashesUnchanged']=len(read(OUT/'source-hashes.json'));save('verification.json',v)
    print(json.dumps(result),flush=True)

if __name__=='__main__':
    assert not (OUT/'completion.json').exists(),'Completed output is immutable'
    globals()[sys.argv[1]]()
