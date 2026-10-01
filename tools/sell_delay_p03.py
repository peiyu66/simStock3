#!/usr/bin/env python3
"""SD-P03 bounded two-batch discovery; only original W1/W2 SELL features.
No strategy replay, no repair search, and no W3 read before explicit freeze.
"""
from pathlib import Path
from collections import Counter,defaultdict
import dataclasses,hashlib,json,math,resource,sys,time
import numpy as np
import h_entry_composite_search as engine
from h_entry_composite_p03 import arrays,expression
R=Path(__file__).resolve().parents[1]
P=R/'exports/sell-delay-p02-20260930';O=R/'exports/sell-delay-p03-20260930'
CAP=3150214;SPLIT=1400000;RULE='6097cc26fe839dd8878082ac8f11bdaf08cf0306'
read=lambda p:json.loads(p.read_text())
def sha(p):
    h=hashlib.sha256()
    with p.open('rb') as f:
        for b in iter(lambda:f.read(1048576),b''):h.update(b)
    return h.hexdigest()
def save(name,value):
    O.mkdir(parents=True,exist_ok=True);tmp=O/(name+'.tmp')
    tmp.write_text(json.dumps(value,ensure_ascii=False,indent=2,allow_nan=False)+'\n');tmp.replace(O/name)

class Screen:
    def __init__(self,ops):
        self.ops=ops
        self.pos=engine.bits([o['qualifiedOpportunity'] is True for o in ops]);self.neg=engine.bits([o['qualifiedOpportunity'] is False for o in ops]);self.known=self.pos|self.neg
        self.P=self.pos.bit_count();self.N=self.neg.bit_count()
        assert self.P and self.N
    def basic(self,m,v):
        p=(m&self.pos).bit_count();n=(m&self.neg).bit_count();total=p+n
        contrast=p/self.P-n/self.N
        precision=p/total if total else 0
        return p,n,precision,contrast
    def rank(self,m,v):
        p,n,precision,contrast=self.basic(m,v)
        # Transparent class-capture contrast, not a financial/weighted performance score.
        return (contrast,precision,p)
    def repair_rank(self,m,v):
        p,n,precision,contrast=self.basic(m,v)
        # Also preserve high-opportunity families; no zero-counterexample or sample-count gate.
        return (math.floor((precision+1e-12)/.05),p,contrast)
    def metrics(self,m,v):
        p,n,precision,contrast=self.basic(m,v);ids=[i for i in range(len(self.ops)) if m&(1<<i)];rows=[self.ops[i] for i in ids]
        cells={}
        for cell in sorted({o['sample']+str(o['window']) for o in self.ops}):
            base=[o for o in self.ops if o['sample']+str(o['window'])==cell];hit=[o for o in rows if o['sample']+str(o['window'])==cell]
            cp=sum(o['qualifiedOpportunity'] is True for o in hit);cn=sum(o['qualifiedOpportunity'] is False for o in hit)
            cells[cell]=dict(hits=len(hit),higher=cp,noHigher=cn,unknown=len(hit)-cp-cn,backgroundHigher=sum(o['qualifiedOpportunity'] is True for o in base),backgroundNoHigher=sum(o['qualifiedOpportunity'] is False for o in base))
        stocks=Counter(o['stock'] for o in rows);dates=Counter(o['anchor'] for o in rows)
        return dict(hits=len(ids),higher=p,noHigher=n,unknown=len(ids)-p-n,precision=precision,captureContrast=contrast,validInputs=v.bit_count(),missingInputs=len(self.ops)-v.bit_count(),stocks=len(stocks),maxStockHits=max(stocks.values(),default=0),distinctMarketDates=len(dates),maxSameDayHits=max(dates.values(),default=0),cells=cells,stockCounts=dict(stocks))

class Reservoir:
    def __init__(self,screen,limit=400):self.screen=screen;self.a=engine.Reservoir(limit);self.b=engine.Reservoir(limit)
    def add(self,n):
        if n is None:return
        self.a.add(n);self.b.add(dataclasses.replace(n,score=self.screen.repair_rank(n.mask,n.valid)))
    def values(self):
        # Same expression can have different retention purposes; keep a single canonical node.
        return list({n.expr:dataclasses.replace(n,score=self.screen.rank(n.mask,n.valid)) for n in self.a.values()+self.b.values()}.values())

def choose(nodes,atoms,screen,width=200):
    # Each source receives entries from both rankings; parent-set diversity prevents near-duplicate beams.
    chosen=[];seen=set();parents=Counter()
    def take(seq,quota):
        if quota<=0 or len(chosen)>=width:return
        added=0
        for n in seq:
            key=(n.mask,n.valid);family=tuple(sorted({atoms[i].parent for branch in n.expr for i in branch}))
            if key in seen or parents[family]>=2:continue
            chosen.append(n);seen.add(key);parents[family]+=1;added+=1
            if added>=quota or len(chosen)>=width:return
    tie=lambda n:tuple(-i for branch in n.expr for i in branch)
    main=sorted(nodes,key=lambda n:(n.score,tie(n)),reverse=True)
    repair=sorted(nodes,key=lambda n:(screen.repair_rank(n.mask,n.valid),tie(n)),reverse=True)
    for source in engine.STRATA:
        take([n for n in main if n.stratum==source],12)
        take([n for n in repair if n.stratum==source],12)
    if len(chosen)<width:take(main,width-len(chosen))
    if len(chosen)<width:take(repair,width-len(chosen))
    return chosen

def generate_pairs(atoms):
    for i,a in enumerate(atoms):
        for b in atoms[i+1:]:
            if a.parent!=b.parent:yield ((a.id,b.id),)

def expansions(beam,atoms):
    seen=set()
    for n in beam:
        branch=n.expr[0];parents={atoms[i].parent for i in branch}
        for a in atoms:
            if a.parent in parents:continue
            expr=(tuple(sorted((*branch,a.id))),)
            if expr in seen:continue
            seen.add(expr);yield expr

def disjunctions(pool,atoms):
    for i,a in enumerate(pool):
        for b in pool[i+1:]:
            if len({atoms[t].parent for branch in a.expr+b.expr for t in branch})>4:continue
            # Do not discard nested hit masks: differing validity may still matter under strict missing rules.
            yield a.expr+b.expr

def context():
    cat=read(P/'feature-catalog.json');defs=read(P/'atoms-no-outcome-ranking.json');ops=read(P/'discovery-opportunities.json')
    data=np.load(P/'discovery.npz');X=data['X'][data['anchors']]
    assert len(defs)==2138 and len(X)==len(ops)==1073
    atoms=[engine.Atom(**a,mask=engine.bits(m),valid=engine.bits(v)) for a,(m,v) in zip(defs,arrays(defs,X,cat))]
    return cat,defs,atoms,Screen(ops)

def preflight():
    assert not (O/'protocol.json').exists(), 'Existing run must be resumed rather than reset'
    co=read(P/'completion.json');assert co['status']=='complete' and co['ruleCommit']==RULE
    sources={**read(P/'source-hashes.json'),**co['artifacts']}
    for path,digest in sources.items():assert sha(R/path)==digest,path
    for f in [P/'completion.json',R/'tools/sell_delay_p03.py',R/'tools/h_entry_composite_search.py',R/'tools/h_entry_composite_p03.py']:sources[str(f.relative_to(R))]=sha(f)
    save('source-hashes.json',sources)
    save('protocol.json',dict(status='running',stage='SD-P03',authorization='User 好 to SD-P03 two batches, initial upper 3150214, at most six families',task='01a0ef6d-ef8b-7aa2-9790-ea4fa9c48f79',baseline=35,decisionBase=21,dataRules='T3/S59',ruleCommit=RULE,initialSearchCap=CAP,batchCaps=[SPLIT,CAP-SPLIT],perBatchHardCap=2000000,repairSearchCap=0,maxFamilies=6,thresholdSource='frozen P02 original W1/W2 SELL causal features',retention='two lanes: class-capture contrast and coarse opportunity fraction then positive count; source and parent diversity; no adoption gates',futureS='unknown; never baseline descriptive',W3Read=False,strategyReplays=0,builds=0,downloads=0,CDEEffectsRead=False))

def search(batch):
    assert not (O/'completion.json').exists()
    assert not (O/f'batch-{batch}.json').exists()
    cat,defs,atoms,screen=context();dest=Reservoir(screen);counts=Counter();strata=defaultdict(Counter);nonempty=defaultdict(Counter);start=time.monotonic();before=0
    for path,digest in read(O/'source-hashes.json').items():assert sha(R/path)==digest,path
    if batch==2:
        p=read(O/'batch-1.json');assert p['complete'] and p['evaluated']==SPLIT
        for expr in p['reservoir']:
            n=engine.make_node(expr,atoms,screen.rank);assert n is not None;dest.add(n)
        before=SPLIT
    cap=SPLIT if batch==1 else CAP-SPLIT
    def progress(stage):
        z=dict(batch=batch,stage=stage,evaluated=sum(counts.values()),totalIncludingPrior=before+sum(counts.values()),counts=dict(counts),elapsedSeconds=round(time.monotonic()-start,2),peakRSSBytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
        assert z['peakRSSBytes']<2*1024**3
        save(f'progress-{batch}.json',z);print(json.dumps(z),flush=True)
    def consider(expr,stage,target):
        n=engine.make_node(expr,atoms,screen.rank)
        if n is None:return
        counts[stage]+=1;assert sum(counts.values())<=cap
        strata[stage][n.stratum]+=1
        if n.mask:nonempty[stage][n.stratum]+=1
        target.add(n)
        if sum(counts.values())%100000==0:progress(stage)
    pairs=0
    for index,expr in enumerate(generate_pairs(atoms),1):
        pairs+=1
        if batch==1 and index>SPLIT:break
        if batch==2 and index<=SPLIT:continue
        consider(expr,'AND2',dest)
    retained=[];pools={}
    if batch==1:assert counts['AND2']==SPLIT
    else:
        assert pairs==2275114 and counts['AND2']==2275114-SPLIT
        pool=choose(dest.values(),atoms,screen);beam=pool
        pools['AND2']=[n.expr for n in pool];retained+=pool
        for depth in (3,4):
            d=Reservoir(screen)
            for expr in expansions(beam,atoms):consider(expr,'AND'+str(depth),d)
            beam=choose(d.values(),atoms,screen);retained+=beam;pools['AND'+str(depth)]=[n.expr for n in beam];progress('AND'+str(depth))
        d=Reservoir(screen)
        for expr in disjunctions(pool,atoms):consider(expr,'OR',d)
        ors=choose(d.values(),atoms,screen);retained+=ors;pools['OR']=[n.expr for n in ors]
    progress('complete')
    save(f'batch-{batch}.json',dict(complete=True,batch=batch,evaluated=sum(counts.values()),counts=dict(counts),bySource={k:dict(v) for k,v in strata.items()},nonempty={k:dict(v) for k,v in nonempty.items()},elapsedSeconds=time.monotonic()-start,peakRSSBytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,reservoir=[n.expr for n in dest.values()] if batch==1 else [],pools=pools))
    if batch==2:
        unique={n.expr:n for n in retained}
        save('retained.json',[dict(poolID=f'R{i+1:03}',expr=n.expr,stratum=n.stratum,expression=expression(n.expr,defs),rank=n.score,repairRank=screen.repair_rank(n.mask,n.valid),metrics=screen.metrics(n.mask,n.valid)) for i,n in enumerate(unique.values())])
    print('BATCH_COMPLETE',batch,sum(counts.values()),flush=True)

if __name__=='__main__':
    if sys.argv[1]=='preflight':preflight()
    else:search(int(sys.argv[1]))
