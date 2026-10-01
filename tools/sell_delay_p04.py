#!/usr/bin/env python3
"""Bounded SD-P04 counterexample repairs. No strategy replay or future baseline S."""
from pathlib import Path
from collections import Counter
from itertools import combinations, permutations
import json, sys, time, resource
import numpy as np
import sell_delay_p03 as p
from sell_delay_p03 import engine, read, sha, R, P
O=R/'exports/sell-delay-p04-20260930'
NAMES=['notHit','higherRelease','lowerRelease','equalRelease','stillTrue10','windowTruncated','unknownInputs','dataUnknown']
def save(name,value):
    O.mkdir(exist_ok=True,parents=True); q=O/(name+'.tmp')
    q.write_text(json.dumps(value,ensure_ascii=False,indent=2,allow_nan=False)+'\n');q.replace(O/name)
def canon(e):return tuple(sorted(tuple(sorted(b)) for b in e))
def add(e,a):return tuple(tuple(b)+tuple(a) for b in e)
def replace(e,pos,a):
    x=[list(b) for b in e];x[pos[0]][pos[1]]=a;return canon(x)
def mechanism(a):
    n=a['name'].lower()
    if a['group']=='S':return '持倉與效率前態：辨別資金占用、輪次及效率轉折；未來S未知，不當作解除改善'
    if any(s in n for s in ('volume','value','transaction','v_','vma','vmax','vmin')):return '量能與活躍度：辨別反彈參與度及量能極端'
    if any(s in n for s in ('kd','osc')):return '動能：辨別超熱、負動能與反彈階段'
    if any(s in n for s in ('path','phase','duration')):return '價格路徑：辨別探頂、回落、探底及反彈進度'
    return '價格位置與均線：辨別相對高低、趨勢及回落幅度'

class Context:
    def __init__(self,label):
        self.label=label;self.cat=read(P/'feature-catalog.json');self.defs=read(P/'atoms-no-outcome-ranking.json')
        z=np.load(P/f'{label}.npz');self.X=z['X'];self.anchors=z['anchors'];self.ops=read(P/f'{label}-opportunities.json');self.keys=read(P/f'{label}-keys.json')
        ar=list(p.arrays(self.defs,self.X,self.cat));self.hit=np.array([m for m,v in ar]);self.valid=np.array([v for m,v in ar])
        self.atoms=[engine.Atom(**a,mask=0,valid=0) for a in self.defs]
        self.idx=np.full((len(self.ops),11),-1,dtype=int)
        for j,o in enumerate(self.ops):self.idx[j,:len(o['indices'])]=o['indices']
        self.present=self.idx>=0;self.pos=np.array([o['qualifiedOpportunity'] is True for o in self.ops]);self.neg=np.array([o['qualifiedOpportunity'] is False for o in self.ops]);self.known=self.pos|self.neg
        self.close=np.array([k['close'] for k in self.keys]);self.full=np.array([o['completeTen'] for o in self.ops]);self.col={c['name']:j for j,c in enumerate(self.cat)}
    def legal(self,e):return engine.make_node(e,self.atoms,lambda m,v:(0,)) is not None
    def mask(self,e):
        v=np.logical_and.reduce(self.valid[[i for b in e for i in b]],axis=0)
        h=np.logical_or.reduce([np.logical_and.reduce(self.hit[list(b)],axis=0) for b in e],axis=0)&v
        return h,v
    def outcomes(self,e):
        h,v=self.mask(e);hits=h[self.anchors];hh=h[self.idx];vv=v[self.idx]
        stops=(~hh[:,1:]|~vv[:,1:])&self.present[:,1:];has=stops.any(axis=1);off=stops.argmax(axis=1)+1
        rows=np.arange(len(hits));idx=self.idx[rows,off];delta=100*(self.close[idx]/self.close[self.anchors]-1)
        status=np.where(self.full,4,5)
        status=np.where(has,np.where(~v[idx],6,np.where(delta>0,1,np.where(delta<0,2,3))),status)
        status=np.where(self.known,status,7);status=np.where(hits,status,0)
        return status,off,delta,h,v
    def evaluate(self,e,base=None):
        st,off,delta,h,v=self.outcomes(e);hits=st>0
        r=dict(counts={NAMES[i]:int(np.sum(st==i)) for i in range(1,8)},hits=int(hits.sum()),positive=int(np.sum(hits&self.pos)),negative=int(np.sum(hits&self.neg)),unknown=int(np.sum(hits&~self.known)))
        r['medianReleasePct']=float(np.median(delta[(st>=1)&(st<=3)])) if np.any((st>=1)&(st<=3)) else None
        r['worstReleasePct']=float(np.min(delta[(st>=1)&(st<=3)])) if np.any((st>=1)&(st<=3)) else None
        if base is not None:
            bh=base>0;bad=base==2;good=base==1
            r['comparison']=dict(originalHitsRetained=int(np.sum(hits&bh)),newHits=int(np.sum(hits&~bh)),positiveKept=int(np.sum(hits&bh&self.pos)),positiveLost=int(np.sum(~hits&bh&self.pos)),negativeExcluded=int(np.sum(~hits&bh&self.neg)),negativeRemaining=int(np.sum(hits&bh&self.neg)),higherKeptAsHigher=int(np.sum(good&(st==1))),higherLostTrigger=int(np.sum(good&~hits)),higherTurnedLower=int(np.sum(good&(st==2))),lowerExcluded=int(np.sum(bad&~hits)),lowerRepairedHigher=int(np.sum(bad&(st==1))),lowerRemaining=int(np.sum(bad&(st==2))),lowerMovedUnknownOrLate=int(np.sum(bad&(st>=4))))
        return r
    def details(self,e):
        st,off,delta,h,v=self.outcomes(e);out=[]
        for j in np.flatnonzero(st):
            o=self.ops[j];d=int(off[j]);row=dict(sample=o['sample'],window=o['window'],stock=o['stock'],anchor=o['anchor'],exitRoute=o['exitRoute'],opportunity=o['qualifiedOpportunity'],result=NAMES[st[j]],highestDates=o['higherHighestDates'],maxGainPct=o['maxGainPct'],minGainPct=o['minGainPct'],firstPeakOffset=o['firstPeakOffset'])
            if st[j] in (1,2,3):row.update(firstOffDate=self.keys[self.idx[j,d]]['date'],offset=d,releasePriceDeltaPct=float(delta[j]),netProceedsDelta=o['netProceedsDelta'][d-1])
            out.append(row)
        return out

def rank(r,stateful=False,lane=0):
    c=r['counts'];q=r['comparison']
    if stateful:
        den=r['positive']+r['negative'];return ((r['positive']/den if den else 0),r['positive'],-r['unknown'])
    good=c['higherRelease'];bad=c['lowerRelease'];late=c['stillTrue10']+c['unknownInputs']+c['dataUnknown']+c['windowTruncated'];total=max(1,r['hits'])
    if lane==0:return (good/total,good,-bad,-late,q['higherKeptAsHigher'],-q['newHits'])
    return (q['higherKeptAsHigher']-q['lowerRemaining'],good/total,-bad,-late,-q['newHits'])

def preflight():
    assert not (O/'protocol.json').exists()
    co=read(p.O/'completion.json');sources={**read(p.O/'source-hashes.json'),**co['artifacts'],str((p.O/'completion.json').relative_to(R)):sha(p.O/'completion.json')}
    for f,h in sources.items():assert sha(R/f)==h,f
    save('source-hashes.json',sources)
    save('protocol.json',dict(stage='SD-P04',status='running',authorization='User 好，請繼續。 after sole SD-P04 proposal and explanation of six families',task='01a0ef6d-ef8b-7aa2-9790-ea4fa9c48f79',baseline=35,decisionBase=21,dataRules='T3/S59',ruleCommit=p.RULE,cap=40000,stageACap=12828,stageBCap=25992,otherCap=1180,thresholds='P02 frozen 2138 coarse atoms; no new cuts',train='W1/W2',later='freeze before new W3 checks; original P03 W3 already seen',futureS='NaN; never baseline descriptive',strategyReplays=0,builds=0,downloads=0,CDEEffectsRead=False,selection='two transparent descriptive lanes: higher-release fraction/coverage; S uses opportunity fraction/coverage; no adoption gate'))

def stage_a():
    assert not (O/'stage-a.json').exists()
    c=Context('discovery');families=read(p.O/'frozen-families.json')['families'];out=[];start=time.monotonic()
    for f in families:
        e=canon(f['expr']);base=c.outcomes(e)[0];rows=[];invalid=0
        for a in c.defs:
            ex=canon(add(e,[a['id']]))
            if not c.legal(ex):invalid+=1;continue
            rows.append(dict(atom=a['id'],expr=ex,**c.evaluate(ex,base)))
        out.append(dict(family=f['family'],original=c.evaluate(e),attempted=len(c.defs),invalidGrammar=invalid,evaluated=len(rows),rows=rows))
        print(f['family'],len(rows),'evaluated',flush=True)
    assert sum(x['evaluated'] for x in out)<=12828
    save('stage-a.json',out);save('progress.json',dict(stage='A-complete',evaluations=sum(x['evaluated'] for x in out),elapsedSeconds=time.monotonic()-start,peakRSSBytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss))

def select_atoms():
    assert not (O/'selected-atoms.json').exists()
    defs=read(P/'atoms-no-outcome-ranking.json');fs=read(p.O/'frozen-families.json')['families'];stage=read(O/'stage-a.json');out=[]
    for f,z in zip(fs,stage):
        stateful=f['family'] in ('SD-F04','SD-F05');chosen=[];parents=Counter()
        # Use relative/normalized indicators for transferable follow-up repairs. Stage A still audits ALL fields.
        eligible=lambda a: not (a['name'] in ('priceClose','priceHigh','priceLow','priceOpen','volumeClose','unit_cost_before','inventory_before') or a['name'].startswith('market_raw_') or a['name'] in ('market_high_max_9','market_low_min_9','market_ma_20','market_ma_60','market_path_anchor','market_path_extreme','tMa20','tMa60','tHighMax9','tLowMin9','tPricePathAnchorClose','tPricePathExtremeClose'))
        for lane in (0,1):
            for r in sorted(z['rows'],key=lambda r:rank(r,stateful,lane),reverse=True):
                a=defs[r['atom']]
                if not eligible(a) or r['atom'] in chosen or parents[a['parent']]>=2 or not r['hits']:continue
                chosen.append(a['id']);parents[a['parent']]+=1
                if len(chosen)>=(12 if lane==0 else 24):break
        if not chosen: # F06 already consumes four parents: all additions invalid; fixed structural substitutions instead.
            names=['kd_d_z125','market_ma_60_diff_z_125','market_volume_ma_20_diff_min_9','market_transaction_z_250','osc_z125','ma20_diff','market_kd_k_z_250','market_osc_z_125','price_path_pullback','market_path_rebound','market_ma_20_days','market_volume_z_125']
            for name in names:
                pool=[a for a in defs if a['name']==name]
                preferred=sorted(pool,key=lambda a:(a['op']!='between',abs(float(a['value'])) if isinstance(a['value'],(int,float)) else 0))[:2]
                chosen += [a['id'] for a in preferred]
        chosen=chosen[:24];assert len(chosen)<=24
        out.append(dict(family=f['family'],atoms=[dict(**defs[i],mechanism=mechanism(defs[i])) for i in chosen],stateful=stateful,selectionUsesW3=False))
    save('selected-atoms.json',dict(status='frozen-before-stage-B',stageASHA256=sha(O/'stage-a.json'),families=out))

def variants(e,ids):
    positions=[(j,k) for j,b in enumerate(e) for k in range(len(b))]
    for pos in positions:
        for a in ids:
            yield 'replace1',replace(e,pos,a)
            yield 'orAlternative1',canon(e+replace(e,pos,a))
    for a,b in combinations(ids,2):
        yield 'add2AND',canon(add(e,[a,b]))
        yield 'add2OR',canon(add(e,[a])+add(e,[b]))
        yield 'newORBranch',canon(e+((a,b),))
    for p1,p2 in combinations(positions,2):
        for a,b in permutations(ids,2):
            x=[list(z) for z in e];x[p1[0]][p1[1]]=a;x[p2[0]][p2[1]]=b
            yield 'replace2',canon(x)

def stage_b():
    assert not (O/'stage-b.json').exists()
    c=Context('discovery');fs=read(p.O/'frozen-families.json')['families'];sel=read(O/'selected-atoms.json');za=read(O/'stage-a.json');out=[];count=0
    for f,s,aa in zip(fs,sel['families'],za):
        e=canon(f['expr']);base=c.outcomes(e)[0];seen={canon(r['expr']) for r in aa['rows']}|{e};rows=[];skips=Counter()
        for typ,ex in variants(e,[a['id'] for a in s['atoms']]):
            if ex in seen:skips['duplicate']+=1;continue
            if not c.legal(ex):skips['grammar']+=1;continue
            seen.add(ex);count+=1;assert count<=25992
            rows.append(dict(kind=typ,expr=ex,**c.evaluate(ex,base)))
        out.append(dict(family=f['family'],evaluated=len(rows),skips=dict(skips),rows=rows));print(f['family'],len(rows),'B evaluations',flush=True)
        save('progress.json',dict(stage='B',family=f['family'],stageBEvaluations=count,peakRSSBytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss))
    save('stage-b.json',out)

def short():
    defs=read(P/'atoms-no-outcome-ranking.json');a=read(O/'stage-a.json');b=read(O/'stage-b.json');out=[]
    for aa,bb in zip(a,b):
        f=aa['family'];rows=[dict(kind='add1AND',**r) for r in aa['rows']]+bb['rows'];selected=[];seen=set()
        for lane in (0,1):
            for r in sorted(rows,key=lambda r:rank(r,f in ('SD-F04','SD-F05'),lane),reverse=True):
                sig=(tuple(r['counts'].values()),tuple(r['comparison'].values()))
                if sig in seen or not r['hits']:continue
                seen.add(sig);selected.append(dict(**r,expression=p.expression(r['expr'],defs)))
                if len(selected)>=(12 if lane==0 else 24):break
        out.append(dict(family=f,original=aa['original'],shortlist=selected))
    save('train-shortlist.json',out)
    for x in out:
        print(x['family'],'original',x['original'])
        for r in x['shortlist'][:7]:print(r['kind'],r['expression'],r['counts'],r['comparison'])

if __name__=='__main__':
    assert not (O/'completion.json').exists(), 'Completed P04 evidence is immutable'
    globals()[sys.argv[1]]()
