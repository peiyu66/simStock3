#!/usr/bin/env python3
"""Independent exhaustive archive audit using scalar atoms and first-stop masks."""
import collections as C
import hashlib
import json
import math
import numpy as np
import add_delay_p03 as a

def independent_inputs(part='discovery'):
    data=np.load(a.P/(part+'.npz'));X=data['X'];entries=data['anchors']
    specs=a.read(a.P/'atoms-no-outcome-ranking.json');cat=a.read(a.P/'feature-catalog.json');lookup={c['name']:i for i,c in enumerate(cat)}
    ops=a.read(a.P/(part+'-opportunities.json'));labels=[r for r in a.read(a.P/'quality-labels.json')['rows'] if r['partition']==part]
    bits=lambda xs:sum(1<<i for i,v in enumerate(xs) if v)
    atoms=[]
    for spec in specs:
        column=X[:,lookup[spec['name']]];valid=[math.isfinite(float(x)) for x in column];truth=[]
        for ok,x in zip(valid,column):
            v=spec['value'];op=spec['op']
            if not ok:truth.append(False)
            elif op=='lt':truth.append(x<v)
            elif op=='gt':truth.append(x>v)
            elif op=='eq':truth.append(x==v)
            elif op=='ne':truth.append(x!=v)
            elif op=='between':truth.append(v[0]<x<v[1])
            else:raise AssertionError(op)
        stops=[0]*10;missing=[0]*10
        for k,o in enumerate(ops):
            for t,idx in enumerate(o['indices'][1:]):
                if not valid[idx] or not truth[idx]:
                    stops[t]|=1<<k
                    if not valid[idx]:missing[t]|=1<<k
                    break
        atoms.append(dict(spec,mask=bits([truth[i] for i in entries]),valid=bits([valid[i] for i in entries]),stops=stops,missing=missing))
    price=[]
    for t in range(10):
        price.append(tuple(bits([len(o['dailyChangePct'])>t and check(o['dailyChangePct'][t]) for o in ops]) for check in (lambda x:x<0,lambda x:x>0,lambda x:x==0)))
    return dict(atoms=atoms,ops=ops,labels=labels,eligible=bits([l['eligible'] for l in labels]),quality_unknown=bits([not l['eligible'] for l in labels]),lower=bits([l['opportunity'] is True for l in labels]),price_days=price)

def release_counts(x,y,mask,data):
    waiting=mask&data['eligible'];quality=(mask&data['quality_unknown']).bit_count()
    if 'S' in (x['group'],y['group']):return (0,0,0,0,waiting.bit_count(),quality)
    lo=hi=eq=unknown=0
    for t,prices in enumerate(data['price_days']):
        stop=waiting&(x['stops'][t]|y['stops'][t]);unavailable=stop&(x['missing'][t]|y['missing'][t]);released=stop&~unavailable
        unknown+=unavailable.bit_count();lo+=(released&prices[0]).bit_count();hi+=(released&prices[1]).bit_count();eq+=(released&prices[2]).bit_count();waiting&=~stop
        if not waiting:break
    return (lo,hi,eq,waiting.bit_count(),unknown,quality)

def main():
    assert not (a.O/'coverage-audit.json').exists()
    guard=a.Guard();guard.check();guard.watch()
    protected=a.verify_sources();data=independent_inputs();atoms=data['atoms'];n=len(atoms)
    seen=bytearray(n*(n-1)//2);counts=C.Counter();perbatch={};checked=0
    expected={'T':259368,'S':44509,'M':520475,'TS':219675,'TM':743125,'SM':310575}
    # Counts also recomputed independently from parent multiplicity.
    groups=C.defaultdict(list)
    for spec in atoms:groups[spec['group']].append(spec)
    mathematical={}
    for group in 'TSM':
        ns=len(groups[group]);parents=C.Counter(s['parent'] for s in groups[group])
        mathematical[group]=ns*(ns-1)//2-sum(v*(v-1)//2 for v in parents.values())
    for source,g,h in [('TS','T','S'),('TM','T','M'),('SM','S','M')]:mathematical[source]=len(groups[g])*len(groups[h])
    assert mathematical==expected
    for batch in ('A','B'):
        folder=a.O/('batch-'+batch);cp=a.read(folder/'checkpoint.json');assert cp['status']=='complete'
        path=folder/'pairs.bin';assert a.sha(path)==cp['prefixSHA256'] and path.stat().st_size==cp['count']*a.RECORD.size
        assert cp['coreSeconds']<600 and cp['peakRSSBytes']<2147483648 and cp['peakArtifactBytes']<256000000
        local=C.Counter();last=None
        for i,j,mb,vb,*r in a.records(path):
            assert 0<=i<j<n and atoms[i]['parent']!=atoms[j]['parent']
            position=i*(2*n-i-1)//2+j-i-1
            assert not seen[position],('duplicate',batch,i,j)
            seen[position]=1;group=''.join(g for g in 'TSM' if g in (atoms[i]['group'],atoms[j]['group']))
            assert group in a.GROUPS[batch]
            assert last is None or (i,j)>last;last=(i,j)
            mask=int.from_bytes(mb,'little');valid=int.from_bytes(vb,'little')
            assert mask==atoms[i]['mask']&atoms[j]['mask'] and valid==atoms[i]['valid']&atoms[j]['valid']
            assert tuple(r)==release_counts(atoms[i],atoms[j],mask,data),(batch,i,j,r)
            assert sum(r)==mask.bit_count()
            counts[group]+=1;local[group]+=1;checked+=1
            if checked%200000==0:
                guard.check();print(json.dumps(dict(audited=checked,seconds=round(guard.seconds(),2))),flush=True)
        assert sum(local.values())==a.EXPECTED[batch] and dict(local)==cp['counts']
        perbatch[batch]=dict(records=sum(local.values()),counts=dict(local),sha256=cp['prefixSHA256'],coreSeconds=cp['coreSeconds'],peakRSSBytes=cp['peakRSSBytes'],peakArtifactBytes=cp['peakArtifactBytes'])
    assert dict(counts)==expected and sum(seen)==2097727
    prefix=a.read(a.O/'A-prefix-control.json')
    with (a.O/'batch-A/pairs.bin').open('rb') as f:prefixbytes=f.read(prefix['count']*a.RECORD.size)
    assert hashlib.sha256(prefixbytes).hexdigest()==prefix['prefixSHA256']
    assert a.read(a.O/'batch-A/checkpoint.json')['resumes']==1
    for rel,h in protected.items():assert a.sha(a.R/rel)==h,rel
    guard.finish()
    a.save(a.O/'coverage-audit.json',dict(passed=True,formulaRecords=checked,duplicates=0,missing=0,exactPairCounts=mathematical,batches=perbatch,
        atomSource='Scalar comparisons rebuilt from frozen actual AD-P02 matrices; generation independently reproduced before each search',
        releaseOracle='Every record checked against first-stop-per-atom masks, independent of production day-by-day waiting masks',
        realCheckpointPrefix=dict(records=prefix['count'],unchangedAfterResume=True),
        priorRawEvidence='AD-P02 input hashes, raw SQL prestate and poison controls verified; no new source data or post-ADD S used',
        fullSourceHashes=protected,auditSeconds=guard.seconds(),auditPeakRSSBytes=guard.peak_rss,auditSHA256=a.sha(__file__)),guard)
    print(json.dumps(dict(passed=True,records=checked,counts=dict(counts),seconds=guard.seconds())))

if __name__=='__main__':main()
