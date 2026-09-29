#!/usr/bin/env python3
"""HC-P03: frozen-input, two-batch composite discovery; never a strategy replay."""
from pathlib import Path
from collections import Counter, defaultdict
import dataclasses, hashlib, json, math, resource, sys, time
import numpy as np
import h_entry_composite_search as engine

R = Path(__file__).resolve().parents[1]
O = R / 'exports/h-entry-composite-p03-20260929'
P = R / 'exports/h-entry-composite-p02-20260929'
OLD = R / 'exports/h-entry-composite-20260923'
SW = R / 'exports/h-entry-composite-shortwait-20260929'
CELLS = ('A1', 'A2', 'B1', 'B2')
read = lambda p: json.loads(p.read_text())
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()

def save(name, value):
    tmp = O / (name + '.tmp')
    tmp.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + '\n')
    tmp.replace(O / name)

def arrays(atoms, X, cat):
    columns = {c['name']: j for j, c in enumerate(cat)}
    for a in atoms:
        x = X[:, columns[a['name']]]; valid = np.isfinite(x); v = a['value']
        op = a['op']
        if op == 'lt': hit = x < v
        elif op == 'gt': hit = x > v
        elif op == 'eq': hit = x == v
        elif op == 'ne': hit = x != v
        elif op == 'between': hit = (x > v[0]) & (x < v[1])
        else: raise ValueError(op)
        yield hit & valid, valid

def expression(expr, atoms):
    def fmt(a):
        if a['op'] == 'between': return f"{a['value'][0]:g} < {a['name']} < {a['value'][1]:g}"
        op = dict(lt='<', gt='>', eq='==', ne='!=')[a['op']]
        return f"{a['name']} {op} {a['value']:g}"
    return ' OR '.join('(' + ' AND '.join(fmt(atoms[i]) for i in b) + ')' for b in expr)

def dataset(label):
    return np.load(P / (label + '.npz'))['X'], read(OLD / (label + '-keys.json')), read(OLD / (label + '-rounds.json'))

def context():
    """Only train effects. Compact day blocks retain each round's first ten days."""
    X, keys, rounds = dataset('discovery'); cat = read(P / 'feature-catalog.json')
    defs = read(P / 'atoms-no-outcome-ranking.json')
    assert len(defs) == 2100
    C = np.load(P / 'candidate-flat.npz')['X']; ck = read(P / 'candidate-flat-keys.json')
    lookup = {(k['anchor'], k['date']): i for i, k in enumerate(ck)}
    flat = [r for r in read(SW / 'unique-flat-paths.json') if r['window'] < 3]
    n, c = len(rounds), len(flat); obs = np.full((15*n + 11*c, len(cat)), np.nan)
    for j, r in enumerate(rounds):
        for d in range(min(10, r['end']-r['entry'])+1): obs[d*n+j] = X[r['entry']+d]
        if r['opportunity'] and not r['censored']:
            for q, depth in enumerate((.25, .5, .75, 1.)):
                price = r['entry_price'] - depth*(r['entry_price']-r['minimum'])
                i = min(range(r['decline'], r['end']+1), key=lambda i:(abs(keys[i]['close']-price), i))
                obs[(11+q)*n+j] = X[i]
    for j, r in enumerate(flat):
        for d in r['days'][:11]: obs[15*n+d['wait']*c+j] = C[lookup[r['id'], d['date']]]
    atoms = [engine.Atom(**a, mask=engine.bits(m), valid=engine.bits(v)) for a,(m,v) in zip(defs,arrays(defs,obs,cat))]
    return atoms, Screen(rounds, keys, flat), defs

class Screen:
    def __init__(self, rounds, keys, flat):
        self.rounds, self.keys, self.flat = rounds, keys, flat
        self.n, self.c = n, c = len(rounds), len(flat)
        self.full = (1<<n)-1; self.cf = (1<<c)-1; self.co = 15*n
        self.pos = engine.bits([r['opportunity'] for r in rounds])
        self.neg = engine.bits([r['closed'] and not r['bottom_boundary'] and not r['opportunity'] for r in rounds])
        self.cells = [engine.bits([r['sample']+str(r['window']) == k for r in rounds]) for k in CELLS]
        self.stocks = [engine.bits([r['stock']==s for r in rounds]) for s in sorted({r['stock'] for r in rounds})]
        self.posden = [(x&self.pos).bit_count() for x in self.cells]
        self.negden = [(x&self.neg).bit_count() for x in self.cells]
        self.raw_available, self.raw_good, self.raw_early = [0], [0], [0]
        self.ch, self.cl, self.cgood, self.cbad, self.cexit = [0], [0], [0], [0], [0]
        for d in range(1,11):
            self.raw_available.append(engine.bits([r['entry']+d<=r['end'] for r in rounds]))
            self.raw_good.append(engine.bits([r['opportunity'] and r['entry']+d<=r['end'] and r['entry']+d>=r['decline'] and keys[r['entry']+d]['close']<r['entry_price'] for r in rounds]))
            self.raw_early.append(engine.bits([r['opportunity'] and r['entry']+d<r['decline'] for r in rounds]))
            dd = [r['days'][d] if d<len(r['days']) else None for r in flat]
            self.ch.append(engine.bits([a is not None and a['hFeasible'] for a in dd]))
            self.cl.append(engine.bits([a is not None and a['lFill'] for a in dd]))
            within = [a is not None and (not r['closed'] or a['date']<=r['originalExit']) for r,a in zip(flat,dd)]
            self.cexit.append(engine.bits(within))
            self.cgood.append(engine.bits([ok and a['price']<r['price'] and (not r['target'] or a['date']>=r['declineDate']) for r,a,ok in zip(flat,dd,within)]))
            self.cbad.append(engine.bits([a is not None and (not ok or a['price']>r['price'] or (r['target'] and a['date']<r['declineDate'])) for r,a,ok in zip(flat,dd,within)]))

    def metrics(self, m, v):
        hit = m & self.full; th = hit & self.pos
        counts = [(hit&cell).bit_count() for cell in self.cells]
        lifts = [(th&cell).bit_count()/pd-(hit&self.neg&cell).bit_count()/nd for cell,pd,nd in zip(self.cells,self.posden,self.negden)]
        nh, nt = hit.bit_count(), th.bit_count()
        stockcount = sum(bool(hit&s) for s in self.stocks)
        support = nh>=20 and min(counts)>=3 and stockcount>=4 and nt>=4
        remaining = hit; rawgood = rawe = rawvalid = rawmissing = 0
        ch = (m>>self.co)&self.cf; cr = ch; cg = cb = cf = cm = 0
        for d in range(1,11):
            # First false includes missing. Missing removes the gate but is never credited as a valid market release.
            released = remaining & ~(m>>(d*self.n)) & self.raw_available[d]
            usable = released & (v>>(d*self.n))
            rawgood += (usable & self.raw_good[d]).bit_count()
            rawe += (released & self.raw_early[d]).bit_count()
            rawvalid += usable.bit_count(); rawmissing += (released&~usable).bit_count()
            remaining &= ~released
            offset = self.co+d*self.c
            filled = cr & (((~(m>>offset)) & self.ch[d]) | self.cl[d])
            goodvalid = filled & ((v>>offset) | self.cl[d])
            cg += (goodvalid&self.cgood[d]).bit_count()
            cb += (filled&self.cbad[d]).bit_count()
            cf += (filled&self.cexit[d]).bit_count()
            cm += (filled&~goodvalid).bit_count()
            cr &= ~filled
        low_valid = low_off = 0
        for q in range(4):
            lv = (v>>((11+q)*self.n)) & th
            low_valid += lv.bit_count(); low_off += (lv&~(m>>((11+q)*self.n))).bit_count()
        cn = ch.bit_count()
        return dict(supported=support, hits=nh, targetHits=nt, stocks=stockcount, cellHits=counts, lifts=lifts,
                    rawProper10=rawgood, rawEarly10=rawe, rawValidRelease10=rawvalid, rawMissing10=rawmissing,
                    rawUnreleased10=remaining.bit_count(), knownHits=cn, knownProperCheaper10=cg, knownAdverse10=cb,
                    knownWithinExit10=cf, knownUnresolved10=cr.bit_count(), knownMissing10=cm,
                    lowValid=low_valid, lowReleased=low_off)

    @staticmethod
    def score_from(z):
        bucket=lambda v,step: math.floor((v+1e-12)/step)
        return (int(z['supported']), bucket(min(z['lifts']),.05),
                bucket(z['rawProper10']/max(1,z['targetHits']),.1),
                bucket(z['rawValidRelease10']/max(1,z['hits']),.1),
                bucket((z['knownProperCheaper10']-z['knownAdverse10'])/z['knownHits'],.1) if z['knownHits']>=5 else 0,
                bucket(z['lowReleased']/max(1,z['lowValid']),.05),
                round(sum(z['lifts'])/4,8), z['targetHits'])

    def rank(self,m,v): return self.score_from(self.metrics(m,v))

def choose(nodes, atoms):
    """Keep source quotas, unique signals, and no more than two identical parent sets."""
    family = Counter(); limited=[]
    for n in sorted(nodes,key=lambda n:(n.score,tuple(-i for b in n.expr for i in b)),reverse=True):
        f=tuple(sorted({atoms[i].parent for b in n.expr for i in b}))
        if family[f]>=2: continue
        family[f]+=1; limited.append(n)
    return engine.choose(limited,200,25)

def serial(n): return dict(expr=n.expr,score=n.score,stratum=n.stratum)
def restore(records,atoms,screen):
    out=[]
    for r in records:
        n=engine.make_node(r['expr'],atoms,screen.rank)
        assert tuple(r['score'])==n.score, r
        out.append(n)
    return out

def search(batch):
    assert not (O/'completion.json').exists()
    assert batch in (1,2)
    name=f'batch-{batch}.json'; assert not (O/name).exists(), 'Do not repeat a completed batch'
    atoms,screen,defs=context(); counts=Counter(); validcounts=Counter(); supported=Counter(); strata=defaultdict(Counter)
    dest=engine.Reservoir(400); start=time.monotonic(); initial=0
    if batch==2:
        prior=read(O/'batch-1.json'); assert prior['complete'] and prior['evaluated']==1379111
        for n in restore(prior['reservoir'],atoms,screen): dest.add(n)
        initial=prior['evaluated']
    cap=[1379111,1675480][batch-1]
    def consider(expr,stage,store):
        n=engine.make_node(expr,atoms,screen.rank)
        if n is None: return
        counts[stage]+=1; assert sum(counts.values())<=cap
        strata[stage][n.stratum]+=1
        if n.mask&screen.full: validcounts[stage+':'+n.stratum]+=1
        if n.score[0]: supported[stage+':'+n.stratum]+=1
        store.add(n)
    def progress(stage,i):
        state=dict(batch=batch,stage=stage,index=i,evaluated=sum(counts.values()),totalIncludingPrior=initial+sum(counts.values()),counts=dict(counts),elapsedSeconds=round(time.monotonic()-start,2),peakRSSBytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
        save(f'progress-{batch}.json',state)
        print(json.dumps(state),flush=True)
        assert state['peakRSSBytes']<2*1024**3,'memory budget exceeded'
    for i,a in enumerate(atoms):
        for b in atoms[i+1:]:
            if a.parent==b.parent: continue
            is_tm=engine.group_key({a.group,b.group})=='TM'
            if is_tm!=(batch==2): continue
            consider(((a.id,b.id),),'AND2',dest)
        if i%50==0: progress('AND2',i)
    pool=choose(dest.values(),atoms)
    retained=[]; pools={}; eliminations={}
    if batch==1:
        assert counts['AND2']==1379111
    else:
        assert counts['AND2']==815580
        pools['AND2']=[serial(n) for n in pool];retained+=pool;beam=pool
        for depth in (3,4):
            stage='AND'+str(depth);d=engine.Reservoir(400);seen=set()
            for j,n in enumerate(beam):
                branch=n.expr[0];parents={atoms[i].parent for i in branch}
                for a in atoms:
                    if a.parent in parents: continue
                    expr=(tuple(sorted((*branch,a.id))),)
                    if expr in seen: continue
                    seen.add(expr);consider(expr,stage,d)
                if j%20==0: progress(stage,j)
            beam=choose(d.values(),atoms);retained+=beam;pools[stage]=[serial(n) for n in beam]
        d=engine.Reservoir(400);reasons=Counter()
        for i,a in enumerate(pool):
            for b in pool[i+1:]:
                if len({atoms[t].parent for branch in a.expr+b.expr for t in branch})>4:
                    reasons['moreThan4Parents']+=1;continue
                if a.mask|b.mask in (a.mask,b.mask):
                    reasons['nestedBeforeValidity']+=1;continue
                consider(a.expr+b.expr,'OR',d)
            if i%20==0: progress('OR',i)
        ors=choose(d.values(),atoms);retained+=ors;pools['OR']=[serial(n) for n in ors];eliminations['OR']=dict(reasons)
    progress('complete',len(atoms))
    result=dict(complete=True,batch=batch,evaluated=sum(counts.values()),counts=dict(counts),bySource={k:dict(v) for k,v in strata.items()},nonemptyEntry=dict(validcounts),supportPassed=dict(supported),elapsedSeconds=time.monotonic()-start,peakRSSBytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
                reservoir=[serial(n) for n in dest.values()] if batch==1 else [],pools=pools,eliminations=eliminations)
    save(name,result)
    if batch==2:
        save('retained.json',[dict(**serial(n),expression=expression(n.expr,defs),metrics=screen.metrics(n.mask,n.valid)) for n in retained])
    print('BATCH COMPLETE',batch,result['evaluated'],flush=True)

if __name__=='__main__': search(int(sys.argv[1]))
