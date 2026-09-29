#!/usr/bin/env python3
"""P03 descriptive chronology and independent verification, without new trades."""
from collections import Counter,defaultdict
import sys
import numpy as np
import h_entry_composite_p03 as p
import h_entry_composite_search as e
from test_h_entry_composite_p03 import scalar

def evaluate(expr, atomarrays):
    n=len(atomarrays[0][0]);m=np.zeros(n,bool);v=np.ones(n,bool)
    for branch in expr:
        b=np.ones(n,bool)
        for i in branch:
            a,av=atomarrays[i];b&=a;v&=av
        m|=b
    return m&v,v

def inputs(label):
    X,keys,rounds=p.dataset(label);defs=p.read(p.P/'atoms-no-outcome-ranking.json');cat=p.read(p.P/'feature-catalog.json')
    am=list(p.arrays(defs,X,cat))
    C=np.load(p.P/'candidate-flat.npz')['X'];ck=p.read(p.P/'candidate-flat-keys.json')
    allowed={1,2} if label=='discovery' else {3}
    indices=[j for j,k in enumerate(ck) if k['window'] in allowed]
    C=C[indices];ck=[ck[j] for j in indices]
    cm=list(p.arrays(defs,C,cat));lookup={(k['anchor'],k['date']):j for j,k in enumerate(ck)}
    flat=[r for r in p.read(p.SW/'unique-flat-paths.json') if r['window'] in allowed]
    return keys,rounds,am,flat,cm,lookup

def details(expr,data):
    keys,rounds,am,flat,cm,lookup=data;m,v=evaluate(expr,am);mc,vc=evaluate(expr,cm)
    base=[];own=[]
    for r in rounds:
        b,end=r['entry'],r['end'];hit=bool(m[b]);release=None
        if hit:release=next((i for i in range(b+1,end+1) if not m[i]),None)
        low_valid=low_off=0
        if hit and r['opportunity']:
            for depth in (.25,.5,.75,1.):
                price=r['entry_price']-depth*(r['entry_price']-r['minimum'])
                j=min(range(r['decline'],end+1),key=lambda i:(abs(keys[i]['close']-price),i))
                low_valid+=bool(v[j]);low_off+=bool(v[j] and not m[j])
        base.append(dict(id=r['id'],sample=r['sample'],window=r['window'],stock=r['stock'],name=r['name'],hit=hit,valid=bool(v[b]),target=r['opportunity'],control=r['closed'] and not r['bottom_boundary'] and not r['opportunity'],censored=r['censored'],bottomBoundary=r['bottom_boundary'],entryDate=r['entry_date'],exitDate=r['end_date'],kind=r['kind'],
                         wait=release-b if release is not None else None,releaseDate=keys[release]['date'] if release is not None else None,
                         saving=100*(1-keys[release]['close']/r['entry_price']) if release is not None else None,
                         early=release is not None and r['decline'] is not None and release<r['decline'],missing=release is not None and not bool(v[release]),lowValid=low_valid,lowOff=low_off))
    original_hits={r['id']:r['hit'] for r in base}
    for r in flat:
        hit=bool(mc[lookup[r['id'],r['entry']]]);release=None;fill=None
        assert hit==original_hits[r['id']],('initial predicate differs',r['id'],expr)
        if hit:
            release=next((d for d in r['days'][1:] if not mc[lookup[r['id'],d['date']]]),None)
            fill=next((d for d in r['days'][1:] if d['lFill'] or (d['hFeasible'] and not mc[lookup[r['id'],d['date']]])),None)
        own.append(dict(id=r['id'],sample=r['sample'],window=r['window'],stock=r['stock'],target=r['target'],hit=hit,source=r['source'],entryDate=r['entry'],originalExit=r['originalExit'],observedUntil=r['days'][-1]['date'],
                        rawReleaseWait=release['wait'] if release else None,rawReleaseHFeasible=release['hFeasible'] if release else None,
                        wait=fill['wait'] if fill else None,fillDate=fill['date'] if fill else None,lFill=fill['lFill'] if fill else False,
                        saving=100*(1-fill['price']/r['price']) if fill else None,
                        afterExit=bool(fill and r['closed'] and fill['date']>r['originalExit']),
                        early=bool(fill and r['declineDate'] is not None and fill['date']<r['declineDate']),
                        missing=bool(fill and not vc[lookup[r['id'],fill['date']]] and not fill['lFill'])))
    return base,own

def summarize(base,own):
    out={}
    for cell in sorted({r['sample']+str(r['window']) for r in base}):
        rs=[r for r in base if r['sample']+str(r['window'])==cell];h=[r for r in rs if r['hit']];t=[r for r in h if r['target']]
        cs=[r for r in own if r['sample']+str(r['window'])==cell];ch=[r for r in cs if r['hit']]
        pos=sum(r['target'] for r in rs);neg=sum(r['control'] for r in rs)
        horizons={}
        for limit in (3,5,10):
            raw=[r for r in h if r['wait'] is not None and r['wait']<=limit]
            fill=[r for r in ch if r['wait'] is not None and r['wait']<=limit and not r['afterExit']]
            targetfill=[r for r in fill if r['target']]
            horizons[limit]=dict(rawReleased=len(raw),rawMissing=sum(r['missing'] for r in raw),rawCheaper=sum(r['saving']>0 and not r['missing'] for r in raw),rawDearer=sum(r['saving']<0 for r in raw),rawTargetProper=sum(r['target'] and r['saving']>0 and not r['early'] and not r['missing'] for r in raw),rawTargetEarly=sum(r['target'] and r['early'] for r in raw),
                                knownFills=len(fill),knownCheaper=sum(r['saving']>0 and not r['missing'] for r in fill),knownDearer=sum(r['saving']<0 for r in fill),knownEqual=sum(r['saving']==0 for r in fill),knownMissing=sum(r['missing'] for r in fill),knownUnresolved=len(ch)-len(fill),knownTargetFills=len(targetfill),knownTargetProper=sum(r['saving']>0 and not r['early'] and not r['missing'] for r in targetfill),knownTargetEarly=sum(r['early'] for r in targetfill),knownClippedSavingPerAllAnchors=sum(float(np.clip(r['saving'],-10,10)) for r in fill if not r['missing'])/len(cs) if cs else None)
        stocks=Counter(r['stock'] for r in h);quarters=Counter(str(r['entryDate'])[:4]+'Q'+str((int(str(r['entryDate'])[4:6])-1)//3+1) for r in h)
        out[cell]=dict(originalH=len(rs),hits=len(h),targets=pos,targetHits=len(t),controlHits=sum(r['control'] for r in h),censoredHits=sum(r['censored'] for r in h),boundaryHits=sum(r['bottomBoundary'] for r in h),stocks=dict(stocks),quarters=dict(quarters),
                       enrichment=len(t)/pos-sum(r['control'] for r in h)/neg if pos and neg else None,
                       rawNever=sum(r['wait'] is None for r in h),rawMedianWait=float(np.median([r['wait'] for r in h if r['wait'] is not None])) if any(r['wait'] is not None for r in h) else None,
                       lowValid=sum(r['lowValid'] for r in h),lowOff=sum(r['lowOff'] for r in h),knownAnchors=len(cs),knownHits=len(ch),unknownPathHits=len(h)-len(ch),knownNoFillObserved=sum(r['wait'] is None for r in ch),knownAfterExit=sum(r['afterExit'] for r in ch),knownBeyond10=sum(r['wait'] is not None and r['wait']>10 for r in ch),knownReleaseWithoutH=sum(r['rawReleaseWait'] is not None and not r['rawReleaseHFeasible'] for r in ch),horizons=horizons)
    return out

def triage():
    assert not (p.O/'triage.json').exists()
    data=inputs('discovery');atoms,screen,defs=p.context();retained=p.read(p.O/'retained.json');out=[]
    for i,r in enumerate(retained):
        n=e.make_node(r['expr'],atoms,screen.rank);z=scalar(screen,n.mask,n.valid)
        assert z==r['metrics'];assert list(screen.score_from(z))==r['score']
        base,own=details(r['expr'],data);summary=summarize(base,own)
        # Different implementations: compare compact search to complete daily walks.
        hs=[x for x in summary.values()]
        assert sum(x['hits'] for x in hs)==z['hits']
        assert sum(x['horizons'][10]['rawTargetProper'] for x in hs)==z['rawProper10']
        assert sum(x['horizons'][10]['knownTargetProper']+sum(y['hit'] and not y['target'] and y['wait'] is not None and y['wait']<=10 and not y['afterExit'] and not y['missing'] and y['saving']>0 for y in own if y['sample']+str(y['window'])==cell) for cell,x in summary.items())==z['knownProperCheaper10']
        out.append(dict(**r,index=i,cells=summary))
        if i%100==0: print('TRIAGE',i,'/',len(retained),flush=True)
    p.save('triage.json',out);p.save('rank-verification.json',dict(passed=True,retainedNodes=len(out),independentScalarChronologies=len(out),fullDailyCrossChecks=len(out),noStrategyReplay=True))

def freeze():
    assert not (p.O/'frozen.json').exists()
    rows=p.read(p.O/'triage.json');atoms,screen,defs=p.context();selected=[];seen=[]
    # Freeze the top six distinct discovery families. These are research leads,
    # not recommendations for replay; adverse evidence is retained in every card.
    for r in sorted(rows,key=lambda r:(r['score'],-sum(map(len,r['expr']))),reverse=True):
        if not r['metrics']['supported'] or min(r['metrics']['lifts'])<=0:continue
        n=e.make_node(r['expr'],atoms,screen.rank);mask=n.mask&screen.full
        if any((mask&s).bit_count()/max(1,(mask|s).bit_count())>=.8 for s in seen):continue
        selected.append(dict(id=f'HC-P3-{len(selected)+1:02}',index=r['index'],expr=r['expr'],expression=r['expression'],stratum=r['stratum'],score=r['score'],metrics=r['metrics'],status='frozen research lead; not replay proposal'))
        seen.append(mask)
        if len(selected)==6:break
    p.save('frozen.json',dict(candidates=selected,selection='top supported positive-enrichment discovery ranks, <=6 entry-Jaccard<.8 families; no later effects in selection',discoverySHA=p.sha(p.O/'triage.json'),alreadyKnownLater=True,createdBeforeCurrentLaterReview=True))
    print([(r['id'],r['expression']) for r in selected],flush=True)

def review():
    assert (p.O/'frozen.json').exists() and not (p.O/'review.json').exists()
    frozen=p.read(p.O/'frozen.json')['candidates'];outputs=[]
    for label in ('discovery','later'):
        data=inputs(label)
        for r in frozen:
            base,own=details(r['expr'],data);branches=[]
            if len(r['expr'])>1:
                for b in r['expr']:
                    bb,oo=details([b],data);branches.append(dict(expr=[b],cells=summarize(bb,oo)))
            outputs.append(dict(id=r['id'],label=label,cells=summarize(base,own),baselineDetails=base,knownFlatDetails=own,branches=branches))
            print('REVIEW',label,r['id'],flush=True)
    p.save('review.json',outputs)

if __name__=='__main__':
    assert not (p.O/'completion.json').exists(),'Frozen output'
    dict(triage=triage,freeze=freeze,review=review)[sys.argv[1]]()
