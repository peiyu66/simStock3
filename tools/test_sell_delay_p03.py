import unittest,itertools
import numpy as np
import h_entry_composite_search as e
import sell_delay_p03 as p

class SearchControls(unittest.TestCase):
    def planted(self,counterexample=False):
        X=np.array(list(itertools.product([0.,1.],repeat=6)))
        target=(X[:,0]>0)&(X[:,2]>0)|(X[:,1]>0)&(X[:,4]>0)
        truth=target.copy()
        if counterexample:truth[np.where(truth)[0][0]]=False
        ops=[dict(qualifiedOpportunity=bool(v)) for v in truth];screen=p.Screen(ops)
        atoms=[]
        for j in range(6):
            for op in ('gt','lt'):
                m=X[:,j]>.5 if op=='gt' else X[:,j]<.5
                atoms.append(e.Atom(len(atoms),f'f{j}',f'f{j}','TTSSMM'[j],op,.5,e.bits(m),(1<<64)-1))
        dest=p.Reservoir(screen,400);counts={};sources=set()
        for expr in p.generate_pairs(atoms):
            n=e.make_node(expr,atoms,screen.rank);dest.add(n);sources.add(n.stratum)
        pool=p.choose(dest.values(),atoms,screen);beam=pool;stages=[pool]
        for depth in (3,4):
            d=p.Reservoir(screen,400)
            for expr in p.expansions(beam,atoms):
                n=e.make_node(expr,atoms,screen.rank)
                if n:d.add(n);sources.add(n.stratum)
            beam=p.choose(d.values(),atoms,screen);stages.append(beam)
        d=p.Reservoir(screen,400)
        for expr in p.disjunctions(pool,atoms):
            n=e.make_node(expr,atoms,screen.rank)
            if n:d.add(n);sources.add(n.stratum)
        chosen=p.choose(d.values(),atoms,screen)
        return chosen,e.bits(target),screen,sources,stages

    def test_complete_generation_retains_injected_and_or_signal(self):
        selected,mask,screen,sources,stages=self.planted()
        self.assertTrue(any(n.mask==mask for n in selected))
        self.assertEqual(sources,set(e.STRATA))
        self.assertTrue(all(stages))

    def test_one_counterexample_not_dropped_before_deep_screen(self):
        selected,mask,screen,_,_=self.planted(True)
        n=next(n for n in selected if n.mask==mask)
        positive,negative,precision,_=screen.basic(n.mask,n.valid)
        self.assertEqual(negative,1)
        self.assertGreater(positive,1)
        self.assertLess(precision,1)

    def test_unknown_outcomes_not_counted_negative(self):
        screen=p.Screen([dict(qualifiedOpportunity=x) for x in [True,False,None]])
        self.assertEqual(screen.basic(5,7)[:2],(1,0))
        self.assertEqual(screen.basic(4,7)[:2],(0,0))

    def test_independent_boolean_and_global_missing(self):
        rng=np.random.default_rng(44);X=rng.normal(size=(50,4));X[0,3]=np.nan
        defs=[dict(id=i,name=f'f{i}',parent=f'f{i}',group='TSMT'[i],op='gt',value=0) for i in range(4)]
        cat=[dict(name=f'f{i}')for i in range(4)]
        atoms=[e.Atom(**a,mask=e.bits(m),valid=e.bits(v))for a,(m,v)in zip(defs,p.arrays(defs,X,cat))]
        n=e.make_node(((0,1),(2,3)),atoms,lambda m,v:(0,))
        expected=np.all(np.isfinite(X),axis=1)&((X[:,0]>0)&(X[:,1]>0)|(X[:,2]>0)&(X[:,3]>0))
        self.assertEqual(n.mask,e.bits(expected))
        self.assertFalse(n.mask&1)
        self.assertIsNone(e.make_node(((0,0),),atoms,lambda m,v:(0,)))

    def test_exact_pair_enumeration_and_batch_partition(self):
        atoms=[e.Atom(i,str(i),str(i//2),'T','gt',0,0,0)for i in range(8)]
        pairs=list(p.generate_pairs(atoms))
        expected={((a,b),) for a in range(8)for b in range(a+1,8)if a//2!=b//2}
        self.assertEqual(set(pairs),expected);self.assertEqual(len(pairs),len(expected))
        self.assertFalse(set(pairs[:11])&set(pairs[11:]))
        self.assertEqual(set(pairs[:11])|set(pairs[11:]),expected)

    def test_completed_real_coverage_and_budget(self):
        if not (p.O/'batch-2.json').exists():self.skipTest('pre-search controls')
        batches=[p.read(p.O/f'batch-{i}.json')for i in (1,2)]
        self.assertEqual(sum(b['counts']['AND2']for b in batches),2275114)
        self.assertEqual(sum(b['evaluated']for b in batches),3137081)
        self.assertTrue(all(b['evaluated']<=2000000 for b in batches))
        self.assertLessEqual(sum(b['evaluated']for b in batches),p.CAP)
        self.assertEqual(set(batches[1]['bySource']['AND3']),set(e.STRATA))
        self.assertEqual(set(batches[1]['bySource']['AND4']),set(e.STRATA))
        self.assertEqual(set(batches[1]['bySource']['OR']),set(e.STRATA))

    def test_real_mixed_family_survives_freeze_and_no_W3_refit(self):
        if not (p.O/'frozen-families.json').exists():self.skipTest('pre-freeze controls')
        frozen=p.read(p.O/'frozen-families.json')
        self.assertLessEqual(len(frozen['families']),6)
        self.assertTrue(any(0<f['metrics']['noHigher']<f['metrics']['higher']for f in frozen['families']))
        self.assertEqual(frozen['trainDiagnosticsSHA256'],p.sha(p.O/'train-diagnostics.json'))
        later={r['poolID']:r for r in p.read(p.O/'later-diagnostics.json')}
        for f in frozen['families']:self.assertEqual(f['expr'],later[f['poolID']]['expr'])

if __name__=='__main__':unittest.main()
