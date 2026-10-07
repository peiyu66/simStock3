#!/usr/bin/env python3
"""LD-P03 two bounded discovery batches; W3 is opened only after external freeze."""
import collections as C, dataclasses, datetime, functools, hashlib, json, resource, sys, time
from pathlib import Path
import numpy as np
import h_entry_composite_search as g

R=Path(__file__).resolve().parents[1]
P=R/'exports/l-entry-delay-p02-20261001'
O=R/'exports/l-entry-delay-p03-20261001'
def read(p):return json.loads(Path(p).read_text())
def sha(p):
    h=hashlib.sha256()
    with Path(p).open('rb')as f:
        for chunk in iter(lambda:f.read(1048576),b''):h.update(chunk)
    return h.hexdigest()
def now():return datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).isoformat()
def save(name,value):
    t=O/(name+'.tmp');t.write_text(json.dumps(value,ensure_ascii=False,indent=2,allow_nan=False)+'\n');t.replace(O/name)
def verify():
    c=read(P/'completion.json');assert c['status']=='complete'
    for path,d in {**read(P/'source-hashes.json'),**c['artifacts']}.items():assert sha(R/path)==d,path
    return {**read(P/'source-hashes.json'),**c['artifacts'],str((P/'completion.json').relative_to(R)):sha(P/'completion.json')}
def inputs():
    cat=read(P/'feature-catalog.json');data=np.load(P/'discovery.npz')
    X=data['X'][data['anchors']];ops=read(P/'discovery-opportunities.json')
    a=g.make_atoms(X,cat)
    specs=[dict(id=x.id,name=x.name,parent=x.parent,group=x.group,op=x.op,value=x.value)for x in a]
    assert json.loads(json.dumps(specs))==read(P/'atoms-no-outcome-ranking.json')
    assert len(a)==1986 and len(ops)==45
    return a,cat,ops
def indexmask(ops,predicate):return sum(1<<i for i,o in enumerate(ops)if predicate(o))
def metrics(mask,valid,ops):
    ids=[i for i in range(len(ops))if mask>>i&1]
    good=[i for i in ids if ops[i]['qualifiedOpportunity']is True]
    bad=[i for i in ids if ops[i]['qualifiedOpportunity']is False]
    unknown=[i for i in ids if ops[i]['qualifiedOpportunity']is None]
    by={}
    for cell in sorted({(o['sample'],o['window'])for o in ops}):
        eligible=[i for i,o in enumerate(ops)if (o['sample'],o['window'])==cell]
        by[cell[0]+str(cell[1])]=dict(hits=sum(i in ids for i in eligible),lower=sum(i in good for i in eligible),
            noLower=sum(i in bad for i in eligible),unknown=sum(i in unknown for i in eligible),valid=sum(bool(valid>>i&1)for i in eligible))
    stocks=C.Counter(ops[i]['stock']for i in good);dates=C.Counter(ops[i]['anchor']for i in good)
    return dict(hits=len(ids),lower=len(good),noLower=len(bad),unknown=len(unknown),
        precision=len(good)/(len(good)+len(bad))if good or bad else None,
        valid=valid.bit_count(),unavailable=len(ops)-valid.bit_count(),cells=by,positiveStocks=len(stocks),positiveDates=len(dates),
        maxPositiveStockShare=max(stocks.values())/len(good)if good else None,
        maxPositiveDateShare=max(dates.values())/len(good)if good else None,
        positiveIndices=good,counterexampleIndices=bad,unknownIndices=unknown)
def ranker(ops):
    good=indexmask(ops,lambda o:o['qualifiedOpportunity']is True)
    bad=indexmask(ops,lambda o:o['qualifiedOpportunity']is False)
    unknown=indexmask(ops,lambda o:o['qualifiedOpportunity']is None)
    cells=[indexmask(ops,lambda o,k=k:(o['sample'],o['window'])==k)for k in sorted({(o['sample'],o['window'])for o in ops})]
    stocks=[indexmask(ops,lambda o,k=k:o['stock']==k)for k in sorted({o['stock']for o in ops})]
    dates=[indexmask(ops,lambda o,k=k:o['anchor']==k)for k in sorted({o['anchor']for o in ops})]
    @functools.lru_cache(maxsize=65536)
    def rank(mask,valid):
        tp=(mask&good).bit_count();fp=(mask&bad).bit_count();positive=mask&good
        # Explicit lexicographic ordering, no weighted score or hard precision/count gate.
        return (tp/(tp+fp)if tp+fp else -1,sum(bool(positive&c)for c in cells),tp,
                sum(bool(positive&c)for c in stocks),sum(bool(positive&c)for c in dates),
                -(mask&unknown).bit_count(),valid.bit_count())
    return rank
def serialize(n,atoms,ops):
    return dict(expr=n.expr,mask=n.mask,valid=n.valid,stratum=n.stratum,score=n.score,
        formula=' OR '.join('('+' AND '.join(f'{atoms[i].name} {atoms[i].op} {atoms[i].value}'for i in b)+')'for b in n.expr),
        parents=sorted({atoms[i].parent for b in n.expr for i in b}),metrics=metrics(n.mask,n.valid,ops))
def restore(d):return g.Node(tuple(tuple(b)for b in d['expr']),d['mask'],d['valid'],d['stratum'],tuple(d['score']))
def breadth(n):return (n.score[2],n.score[0],n.score[1],*n.score[3:])
class Reservoir:
    def __init__(self):self.precise=g.Reservoir(400);self.broad=g.Reservoir(400)
    def add(self,n):
        self.precise.add(n);self.broad.add(dataclasses.replace(n,score=breadth(n)))
    def values(self):
        # Reverse the leading swap to restore the canonical primary ordering.
        broad=[dataclasses.replace(n,score=(n.score[1],n.score[2],n.score[0],*n.score[3:]))for n in self.broad.values()]
        return list({n.expr:n for n in broad+self.precise.values()}.values())
def choose(nodes,atoms):
    selected=[];seen=set();families=C.Counter()
    def take(seq,quota):
        count=0
        for n in seq:
            key=(n.mask,n.valid);family=tuple(sorted({atoms[i].parent for b in n.expr for i in b}))
            if key in seen or families[family]>=2:continue
            seen.add(key);families[family]+=1;selected.append(n);count+=1
            if count>=quota or len(selected)==200:return
    precise=sorted(nodes,key=lambda n:(n.score,n.expr),reverse=True)
    broad=sorted(nodes,key=lambda n:(breadth(n),n.expr),reverse=True)
    for source in g.STRATA:
        if len(selected)<200:take([n for n in precise if n.stratum==source],min(13,200-len(selected)))
        if len(selected)<200:take([n for n in broad if n.stratum==source],min(12,200-len(selected)))
    if len(selected)<200:take(precise,200-len(selected))
    return selected
def run(stage):
    assert not(O/'completion.json').exists()
    if stage=='pairs':
        assert not(O/'batch1.json').exists()
        O.mkdir(parents=True,exist_ok=True);protected=verify()
        protected[str(Path(__file__).relative_to(R))]=sha(__file__)
        save('protected.json',protected)
        save('protocol.json',dict(stage='LD-P03',status='running',startedAt=now(),authorization='User 好 approved sole two-batch proposal',
          baseline=37,decisionBase=23,dataRules='T3/S61',ruleCommit='7ba8447fbf207484ab305cad0c6beca216da8c93',
          budget=[1962848,814306],totalUpper=2777154,W3Max=6,
          ranking='Primary lexicographic: lower proportion, positive windows, positive cases, stocks/dates, fewer unknown, valid, simpler. Secondary: positive cases first. Each source gets up to13 primary+12 secondary; max2 per parent family; width200.',
          precisionThreshold=None,minimumCases=None,W3ForSelection=False,ABEEffectsRead=False,
          repairsAllowed=False,replays=0,builds=0,downloads=0,simulatorOperations=0))
    else:
        assert stage=='higher'and(O/'batch1.json').exists()and not(O/'batch2.json').exists()
        for path,d in read(O/'protected.json').items():assert sha(R/path)==d,path
    atoms,cat,ops=inputs();rank=ranker(ops);counts=C.Counter();by=C.defaultdict(C.Counter);hist=C.defaultdict(C.Counter)
    start=time.monotonic()
    def consider(expr,depth,dest):
        n=g.make_node(expr,atoms,rank)
        if n is None:return
        n.score+=(-len({atoms[i].parent for b in n.expr for i in b}),-sum(atoms[i].comparisons for b in n.expr for i in b),-len(n.expr))
        counts[depth]+=1;by[depth][n.stratum]+=1
        assert sum(counts.values())<=(1962848 if stage=='pairs'else 814300),'batch budget exceeded'
        tp=(n.mask&index_good).bit_count();fp=(n.mask&index_bad).bit_count()
        hist[depth][f'{tp}/{fp}']+=1
        dest.add(n)
        if sum(counts.values())%100000==0:
            progress=dict(stage=stage,counts=dict(counts),seconds=round(time.monotonic()-start,2),peakRSSBytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
            assert progress['peakRSSBytes']<2*1024**3
            save('progress.json',progress);print(json.dumps(progress),flush=True)
    index_good=indexmask(ops,lambda o:o['qualifiedOpportunity']is True);index_bad=indexmask(ops,lambda o:o['qualifiedOpportunity']is False)
    if stage=='pairs':
        dest=Reservoir()
        for i,a in enumerate(atoms):
            for b in atoms[i+1:]:
                if a.parent!=b.parent:consider(((a.id,b.id),),'AND2',dest)
        assert counts['AND2']==1962848
        retained=dest.values();pool=choose(retained,atoms)
        save('pair-retained.json',[serialize(n,atoms,ops)for n in retained])
        save('pair-pool.json',[serialize(n,atoms,ops)for n in pool])
    else:
        pool=[restore(d)for d in read(O/'pair-pool.json')];beam=pool;retained=[]
        for depth in (3,4):
            dest=Reservoir();seen=set()
            for n in beam:
                b=n.expr[0];parents={atoms[i].parent for i in b}
                for a in atoms:
                    if a.parent in parents:continue
                    expr=(tuple(sorted((*b,a.id))),)
                    if expr in seen:continue
                    seen.add(expr);consider(expr,'AND'+str(depth),dest)
            beam=choose(dest.values(),atoms);retained+=dest.values()
            save(f'and{depth}-pool.json',[serialize(n,atoms,ops)for n in beam])
        dest=Reservoir()
        for i,a in enumerate(pool):
            for b in pool[i+1:]:
                if len({atoms[t].parent for branch in a.expr+b.expr for t in branch})>4:continue
                if a.mask|b.mask in (a.mask,b.mask):continue
                consider(a.expr+b.expr,'OR',dest)
        retained+=dest.values();save('higher-retained.json',[serialize(n,atoms,ops)for n in retained])
        save('or-pool.json',[serialize(n,atoms,ops)for n in choose(dest.values(),atoms)])
    result=dict(status='complete',stage=stage,counts=dict(counts),bySource={k:dict(v)for k,v in by.items()},
        hitHistogram={k:dict(v)for k,v in hist.items()},seconds=time.monotonic()-start,completedAt=now(),
        peakRSSBytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,retained=len(retained))
    save('batch1.json'if stage=='pairs'else 'batch2.json',result)
    print(json.dumps({k:v for k,v in result.items()if k!='hitHistogram'}),flush=True)

if __name__=='__main__':run(sys.argv[1])
