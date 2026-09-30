#!/usr/bin/env python3
"""P04: stock-held-out reruns of the frozen P03 discovery workflow (v33).
No App strategy replay; no v35 performance inference.
"""
from pathlib import Path
from collections import Counter, defaultdict
import dataclasses, hashlib, json, resource, sys, time
import numpy as np
import h_entry_composite_p03 as p
import h_entry_composite_search as e
import h_entry_composite_p03_review as review
from test_h_entry_composite_p03 import scalar
R=Path(__file__).resolve().parents[1]
O=R/'exports/h-entry-composite-p04-20260930'
read=p.read

def save(path,value):
    path.parent.mkdir(parents=True,exist_ok=True)
    tmp=path.with_suffix(path.suffix+'.tmp')
    tmp.write_text(json.dumps(value,ensure_ascii=False,indent=2,allow_nan=False)+'\n');tmp.replace(path)

def prepare():
    assert not (O/'protocol.json').exists()
    X,keys,rounds=p.dataset('discovery');cat=read(p.P/'feature-catalog.json')
    stocks=sorted({r['stock'] for r in rounds});assert len(stocks)==20
    original=read(p.O/'p04-cost-proposal.json');folds=[]
    protected={}
    for folder in [p.OLD,p.P,p.O,p.SW]:
        for f in folder.iterdir():
            if f.is_file() and f.suffix in ('.json','.npz','.py','.cpp','.md'):
                protected[str(f.relative_to(R))]=p.sha(f)
    for f in ['tools/h_entry_composite_p03.py','tools/h_entry_composite_search.py','tools/h_entry_composite_p03_review.py','tools/test_h_entry_composite_p03.py']:
        protected[f]=p.sha(R/f)
    for fold in range(5):
        held=stocks[fold::5];train=sorted(set(stocks)-set(held));ix=[i for i,k in enumerate(keys) if k['stock'] in train]
        eligible=[i for i,c in enumerate(cat) if c['name']!='tradingDaysSinceLastInvestment']
        atoms=e.make_atoms(X[ix][:,eligible],[cat[i]for i in eligible]);defs=[{k:v for k,v in dataclasses.asdict(a).items() if k not in ('mask','valid')} for a in atoms]
        pairs=Counter(e.group_key({a.group,b.group}) for i,a in enumerate(atoms) for b in atoms[i+1:] if a.parent!=b.parent)
        caps=[sum(v for k,v in pairs.items() if k!='TM'),pairs['TM']+400*len(atoms)+19900]
        expected=original['folds'][fold]
        assert held==expected['heldStocks'] and len(atoms)==expected['atoms'] and caps==expected['batchCaps'],(fold,len(atoms),caps,expected)
        coverage=[dict(name=c['name'],group=c['group'],atoms=sum(a.name==c['name'] for a in atoms))for c in cat]
        save(O/f'fold-{fold+1}'/'atoms.json',defs);save(O/f'fold-{fold+1}'/'coverage.json',coverage)
        folds.append(dict(fold=fold+1,heldStocks=held,trainStocks=train,trainRows=len(ix),atoms=len(atoms),pairCounts=dict(pairs),batchCaps=caps,totalCap=sum(caps)))
    save(O/'protected.json',protected)
    save(O/'protocol.json',dict(status='prepared-awaiting-budget',authorized='User: 所以是p04嗎？請繼續執行。',task='01a0ef6d-ef8b-7aa2-9790-ea4fa9c48f79',purpose='Original P03 workflow stability; not strategy efficacy, not rerunning rejected HC-P3-05',baseline=33,decisionBase=19,dataRules='T3/S57',currentBaseline=35,currentDataRules='T3/S59',comparison='v33 historical workflow only; new candidate needs v35 compatibility in P05',folds=folds,totalUpper=sum(f['totalCap']for f in folds),authorizedTotal=10000000,pendingExpandedBudget=True,selection='P03 unchanged: all eligible pairs, 200 per layer, 25 source reserve, max2 per parent family; <=6 positive-enrichment and entry-Jaccard<.8 families',leakage='Each stock all windows stays together. Cutpoints and ranking use only training stocks W1/W2. Freeze before held-stock W1/W2 and W3 review. All data historically seen, not new blind validation.',replays=0,appBuilds=0,simulatorOperations=0))
    print('PREPARED',len(folds),'folds',sum(f['totalCap']for f in folds),'upper; no search performed',flush=True)

def compact(defs,label,stocks):
    X,keys,allrounds=p.dataset(label);cat=read(p.P/'feature-catalog.json')
    rr=[r for r in allrounds if r['stock'] in stocks]
    C=np.load(p.P/'candidate-flat.npz')['X'];ck=read(p.P/'candidate-flat-keys.json');lookup={(k['anchor'],k['date']):i for i,k in enumerate(ck)}
    windows={1,2}if label=='discovery'else{3}
    flat=[r for r in read(p.SW/'unique-flat-paths.json')if r['stock'] in stocks and r['window'] in windows]
    n,c=len(rr),len(flat);obs=np.full((15*n+11*c,len(cat)),np.nan)
    for j,r in enumerate(rr):
        for d in range(min(10,r['end']-r['entry'])+1):obs[d*n+j]=X[r['entry']+d]
        if r['opportunity']and not r['censored']:
            for q,depth in enumerate((.25,.5,.75,1.)):
                price=r['entry_price']-depth*(r['entry_price']-r['minimum'])
                i=min(range(r['decline'],r['end']+1),key=lambda i:(abs(keys[i]['close']-price),i));obs[(11+q)*n+j]=X[i]
    for j,r in enumerate(flat):
        for d in r['days'][:11]:obs[15*n+d['wait']*c+j]=C[lookup[r['id'],d['date']]]
    atoms=[e.Atom(**a,mask=e.bits(m),valid=e.bits(v))for a,(m,v)in zip(defs,p.arrays(defs,obs,cat))]
    return atoms,p.Screen(rr,keys,flat)

def search(fold,batch):
    protocol=read(O/'protocol.json');spec=protocol['folds'][fold-1];destdir=O/f'fold-{fold}';defs=read(destdir/'atoms.json')
    path=destdir/f'batch-{batch}.json';assert not path.exists(),'completed batch is immutable'
    completed=sum(read(f)['evaluated']for f in O.glob('fold-*/batch-*.json'))
    assert completed+spec['batchCaps'][batch-1]<=protocol['authorizedTotal'],'budget approval needed before this batch'
    atoms,screen=compact(defs,'discovery',spec['trainStocks']);counts=Counter();sources=defaultdict(Counter);dest=e.Reservoir(400);start=time.monotonic()
    if batch==2:
        prior=read(destdir/'batch-1.json');assert prior['complete']
        for n in p.restore(prior['reservoir'],atoms,screen):dest.add(n)
    def consider(expr,stage,store):
        n=e.make_node(expr,atoms,screen.rank)
        if n is None:return
        counts[stage]+=1;sources[stage][n.stratum]+=1
        assert sum(counts.values())<=spec['batchCaps'][batch-1]
        store.add(n)
    def progress(stage,index):
        x=dict(fold=fold,batch=batch,stage=stage,index=index,evaluated=sum(counts.values()),elapsedSeconds=time.monotonic()-start,peakRSSBytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
        assert x['peakRSSBytes']<2*1024**3
        save(destdir/f'progress-{batch}.json',x);print(json.dumps(x),flush=True)
    for i,a in enumerate(atoms):
        for b in atoms[i+1:]:
            if a.parent==b.parent:continue
            if (e.group_key({a.group,b.group})=='TM')!=(batch==2):continue
            consider(((a.id,b.id),),'AND2',dest)
        if i%100==0:progress('AND2',i)
    pool=p.choose(dest.values(),atoms);retained=[];pools={}
    if batch==2:
        retained+=pool;pools['AND2']=[p.serial(n)for n in pool];beam=pool
        for depth in (3,4):
            store=e.Reservoir(400);seen=set();stage='AND'+str(depth)
            for j,n in enumerate(beam):
                branch=n.expr[0];parents={atoms[i].parent for i in branch}
                for a in atoms:
                    if a.parent in parents:continue
                    expr=(tuple(sorted((*branch,a.id))),)
                    if expr in seen:continue
                    seen.add(expr);consider(expr,stage,store)
                if j%40==0:progress(stage,j)
            beam=p.choose(store.values(),atoms);retained+=beam;pools[stage]=[p.serial(n)for n in beam]
        store=e.Reservoir(400)
        for i,a in enumerate(pool):
            for b in pool[i+1:]:
                if len({atoms[t].parent for branch in a.expr+b.expr for t in branch})>4:continue
                if a.mask|b.mask in (a.mask,b.mask):continue
                consider(a.expr+b.expr,'OR',store)
        ors=p.choose(store.values(),atoms);retained+=ors;pools['OR']=[p.serial(n)for n in ors]
    progress('complete',len(atoms))
    save(path,dict(complete=True,fold=fold,batch=batch,evaluated=sum(counts.values()),counts=dict(counts),bySource={k:dict(v)for k,v in sources.items()},elapsedSeconds=time.monotonic()-start,peakRSSBytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,reservoir=[p.serial(n)for n in dest.values()]if batch==1 else [],pools=pools))
    if batch==2:
        records=[]
        for n in retained:
            z=screen.metrics(n.mask,n.valid);assert z==scalar(screen,n.mask,n.valid)
            records.append(dict(**p.serial(n),expression=p.expression(n.expr,defs),metrics=z))
        save(destdir/'retained.json',records)
        selected=[];seen=[]
        for r in sorted(records,key=lambda r:(r['score'],-sum(map(len,r['expr']))),reverse=True):
            if not r['metrics']['supported']or min(r['metrics']['lifts'])<=0:continue
            n=e.make_node(r['expr'],atoms,screen.rank);mask=n.mask&screen.full
            if any((mask&s).bit_count()/max(1,(mask|s).bit_count())>=.8 for s in seen):continue
            selected.append(r);seen.append(mask)
            if len(selected)==6:break
        save(destdir/'frozen.json',dict(selected=selected,trainingOnly=True,heldEffectsRead=False,independentChronologies=len(records)))
    print('BATCH COMPLETE',fold,batch,sum(counts.values()),flush=True)

if __name__=='__main__':
    if sys.argv[1]=='prepare':prepare()
    elif sys.argv[1]=='search':search(int(sys.argv[2]),int(sys.argv[3]))
