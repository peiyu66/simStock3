#!/usr/bin/env python3
"""Independent chronological checks for P03's compact bit-block ranking."""
import unittest
import numpy as np
import h_entry_composite_p03 as p
import h_entry_composite_search as e

def scalar(screen,m,v):
    n,c=screen.n,screen.c
    hit=lambda i: bool(m&(1<<i))
    valid=lambda i: bool(v&(1<<i))
    rr=screen.rounds; keys=screen.keys; flat=screen.flat
    hits=[j for j in range(n) if hit(j)]; targets=[j for j in hits if rr[j]['opportunity']]
    cellhits=[];lifts=[]
    for cell in p.CELLS:
        ids=[j for j,r in enumerate(rr) if r['sample']+str(r['window'])==cell]
        pos=[j for j in ids if rr[j]['opportunity']]
        neg=[j for j in ids if rr[j]['closed'] and not rr[j]['bottom_boundary'] and not rr[j]['opportunity']]
        cellhits.append(sum(j in hits for j in ids))
        lifts.append(sum(j in hits for j in pos)/len(pos)-sum(j in hits for j in neg)/len(neg))
    z=dict(supported=len(hits)>=20 and min(cellhits)>=3 and len({rr[j]['stock'] for j in hits})>=4 and len(targets)>=4,
           hits=len(hits),targetHits=len(targets),stocks=len({rr[j]['stock'] for j in hits}),cellHits=cellhits,lifts=lifts,
           rawProper10=0,rawEarly10=0,rawValidRelease10=0,rawMissing10=0,rawUnreleased10=0,
           knownHits=0,knownProperCheaper10=0,knownAdverse10=0,knownWithinExit10=0,knownUnresolved10=0,knownMissing10=0,lowValid=0,lowReleased=0)
    for j in hits:
        r=rr[j];d=next((d for d in range(1,11) if r['entry']+d<=r['end'] and not hit(d*n+j)),None)
        if d is None:z['rawUnreleased10']+=1
        else:
            ok=valid(d*n+j);z['rawValidRelease10']+=ok;z['rawMissing10']+=not ok
            z['rawProper10']+=bool(ok and r['opportunity'] and r['entry']+d>=r['decline'] and keys[r['entry']+d]['close']<r['entry_price'])
            z['rawEarly10']+=bool(r['opportunity'] and r['entry']+d<r['decline'])
        if r['opportunity']:
            for q in range(4):
                i=(11+q)*n+j;z['lowValid']+=valid(i);z['lowReleased']+=valid(i) and not hit(i)
    for j,r in enumerate(flat):
        if not hit(15*n+j):continue
        z['knownHits']+=1
        d=next((d for d in r['days'][1:11] if d['lFill'] or (d['hFeasible'] and not hit(15*n+d['wait']*c+j))),None)
        if d is None:z['knownUnresolved10']+=1;continue
        ok=valid(15*n+d['wait']*c+j) or d['lFill'];within=not r['closed'] or d['date']<=r['originalExit']
        z['knownMissing10']+=not ok;z['knownWithinExit10']+=within
        z['knownProperCheaper10']+=bool(ok and within and d['price']<r['price'] and (not r['target'] or d['date']>=r['declineDate']))
        z['knownAdverse10']+=bool(not within or d['price']>r['price'] or (r['target'] and d['date']<r['declineDate']))
    return z

class Controls(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Four cells, each with positive and negative examples. Different paths
        # include early release, late exit, missing release, L takeover, censoring.
        rr=[];keys=[];flat=[]
        for k in range(8):
            sample='A' if k<4 else 'B';w=(k//2)%2+1;b=len(keys)
            prices=[100,103,101,98,97,96,99,100,101,102,104]
            keys.extend(dict(close=x) for x in prices)
            target=k%2==0
            rr.append(dict(sample=sample,window=w,stock=str(k),opportunity=target,closed=True,bottom_boundary=False,entry=b,end=b+10,entry_price=100,decline=b+2 if target else None))
            days=[dict(wait=d,date=d+1,price=x,hFeasible=d not in (1,2),lFill=(k==2 and d==2)) for d,x in enumerate(prices[:(4 if k==6 else 11)])]
            flat.append(dict(target=target,closed=True,originalExit=4 if k==4 else 11,declineDate=3 if target else None,price=100,days=days))
        cls.screen=p.Screen(rr,keys,flat);cls.length=15*8+11*8

    def test_independent_random_chronology(self):
        rng=np.random.default_rng(703)
        for _ in range(60):
            v=rng.random(self.length)>.1;m=(rng.random(self.length)>.4)&v
            mm,vv=e.bits(m),e.bits(v)
            self.assertEqual(self.screen.metrics(mm,vv),scalar(self.screen,mm,vv))

    def test_missing_release_never_good(self):
        v=np.ones(self.length,bool);m=v.copy();v[8:16]=False;m[8:16]=False
        z=self.screen.metrics(e.bits(m),e.bits(v))
        self.assertEqual(z['rawMissing10'],8);self.assertEqual(z['rawProper10'],0)

    def test_l_takeover_and_censored_path(self):
        m=(1<<self.length)-1;z=self.screen.metrics(m,m)
        self.assertEqual(z['knownWithinExit10'],1)
        self.assertEqual(z['knownUnresolved10'],7)
        self.assertEqual(z['rawUnreleased10'],8)

    def test_or_global_missing_and_parent_guard(self):
        atoms=[e.Atom(i,str(i),str(i),'TSMT'[i],'gt',0,mask,valid) for i,(mask,valid) in enumerate([(3,7),(3,7),(4,7),(4,6)])]
        n=e.make_node(((0,1),(2,3)),atoms,lambda m,v:(0,))
        self.assertEqual(n.mask,6);self.assertEqual(n.valid,6)
        self.assertIsNone(e.make_node(((0,0),),atoms,lambda m,v:(0,)))

    def test_source_quotas_and_parent_diversity(self):
        atoms=[e.Atom(i,str(i),str(i),'T','gt',0,0,0) for i in range(500)]
        nodes=[]
        for j,g in enumerate(e.STRATA):
            for i in range(30):
                aid=2*(j*30+i);nodes.append(e.Node(((aid,aid+1),),1<<(j*30+i),1<<300,g,(1000 if g=='M' else 1,i)))
        chosen=p.choose(nodes,atoms)
        self.assertEqual(len(chosen),200)
        self.assertTrue(all(sum(n.stratum==g for n in chosen)>=25 for g in e.STRATA))

if __name__=='__main__': unittest.main(verbosity=2)
