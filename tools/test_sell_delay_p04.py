#!/usr/bin/env python3
"""Causal chronology, bounded grammar, preserved counterexamples and independent masks."""
import unittest
from collections import Counter
import numpy as np
import sell_delay_p04 as q
from sell_delay_p04 import Context,read,P,O,p,engine,canon

class Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.train=Context('discovery');cls.later=Context('later')
    def test_frozen_originals_reproduce_p03(self):
        fs=read(p.O/'frozen-families.json')['families']
        for label,c,file in [('discovery',self.train,'train-diagnostics.json'),('later',self.later,'later-diagnostics.json')]:
            old={r['poolID']:r for r in read(p.O/file)}
            for f in fs:
                got=c.evaluate(f['expr']);want=old[f['poolID']]
                self.assertEqual(got['hits'],want['metrics']['hits'])
                self.assertEqual(got['counts'],{n:want['proxy'].get(n,0)for n in q.NAMES[1:]})
    def test_independent_full_matrix_and_scalar_chronology(self):
        rows=read(O/'review.json');checks=0
        for label,c in [('discovery',self.train),('later',self.later)]:
            atoms=[engine.Atom(**a,mask=engine.bits(h),valid=engine.bits(v))for a,h,v in zip(c.defs,c.hit,c.valid)]
            for r in rows:
                if r['partition']!=label:continue
                e=r['expr'];n=engine.make_node(e,atoms,lambda m,v:(0,));h,v=c.mask(e)
                self.assertEqual(n.mask,engine.bits(h));self.assertEqual(n.valid,engine.bits(v))
                counts=Counter();cases=[]
                for j,op in enumerate(c.ops):
                    if not(n.mask&(1<<op['indices'][0])):continue
                    result='stillTrue10' if op['completeTen']else'windowTruncated'
                    for k in op['indices'][1:]:
                        if not(n.valid&(1<<k)):result='unknownInputs';break
                        if not(n.mask&(1<<k)):
                            price=c.keys[k]['close'];result='higherRelease' if price>op['originalClose']else'lowerRelease'if price<op['originalClose']else'equalRelease';break
                    if op['qualifiedOpportunity']is None:result='dataUnknown'
                    counts[result]+=1
                self.assertEqual({n:counts[n]for n in q.NAMES[1:]},r['metrics']['counts']);checks+=1
        self.assertEqual(checks,74)
    def test_search_sample_independent_masks(self):
        c=self.train;atoms=[engine.Atom(**a,mask=engine.bits(h),valid=engine.bits(v))for a,h,v in zip(c.defs,c.hit,c.valid)];checks=0
        for a,b in zip(read(O/'stage-a.json'),read(O/'stage-b.json')):
            rows=a['rows']+b['rows']
            for j in np.linspace(0,len(rows)-1,50,dtype=int):
                r=rows[j];n=engine.make_node(r['expr'],atoms,lambda m,v:(0,));h,v=c.mask(r['expr'])
                self.assertEqual(n.mask,engine.bits(h));self.assertEqual(n.valid,engine.bits(v));self.assertEqual(int(h[c.anchors].sum()),r['hits']);checks+=1
        self.assertEqual(checks,300)
    def test_all_search_grammar_counts_and_no_future_s(self):
        total=0
        for file,cap in [('stage-a.json',12828),('stage-b.json',25992)]:
            zs=read(O/file);n=sum(z['evaluated']for z in zs);self.assertLessEqual(n,cap);total+=n
            for z in zs:
                self.assertEqual(z['evaluated'],len(z['rows']))
                self.assertEqual(len(z['rows']),len({canon(r['expr'])for r in z['rows']}))
                for r in z['rows']:self.assertTrue(self.train.legal(r['expr']))
        self.assertEqual(total,18876)
        for c in [self.train,self.later]:
            mask=np.ones(len(c.X),bool);mask[c.anchors]=False;cols=[j for j,x in enumerate(c.cat)if x['group']=='S']
            self.assertTrue(np.isnan(c.X[np.ix_(mask,cols)]).all())
    def test_counterexample_not_hidden_as_unknown_or_late(self):
        rs=read(O/'review.json');r=next(r for r in rs if r['id']=='SD-F01-R1'and r['partition']=='discovery');m=r['metrics']
        self.assertEqual(m['comparison']['lowerExcluded'],2);self.assertEqual(m['comparison']['higherKeptAsHigher'],15)
        self.assertEqual(m['comparison']['lowerMovedUnknownOrLate'],0);self.assertEqual(m['comparison']['positiveLost'],3)
        self.assertEqual(m['counts']['higherRelease'],17)
    def test_strict_or_missing_and_first_stop(self):
        c=Context.__new__(Context);c.hit=np.array([[True,False,True],[True,True,True],[True,True,True],[True,True,True]])
        c.valid=np.array([[True,True,True],[True,True,True],[True,False,True],[True,True,True]])
        h,v=c.mask(((0,1),(2,3)));self.assertEqual(h.tolist(),[True,False,True]);self.assertFalse(v[1])
        c.anchors=np.array([0]);c.idx=np.array([[0,1,2]+[-1]*8]);c.present=c.idx>=0;c.close=np.array([100.,90.,120.]);c.full=np.array([False]);c.known=np.array([True]);c.ops=[{}]
        st,off,*_=c.outcomes(((0,1),(2,3)));self.assertEqual(st[0],6);self.assertEqual(off[0],1)
        c.valid[:]=True;st,off,*_=c.outcomes(((0,1),));self.assertEqual(st[0],2);self.assertEqual(off[0],1)
        c.known[:]=False;st,*_=c.outcomes(((0,1),));self.assertEqual(st[0],7)
    def test_stateful_counterexample_exclusion_cost_is_visible(self):
        rs=read(O/'bounded-field-sensitivity.json')
        rows=[r for r in rs if r['family']=='SD-F04' and '5.8e+06 < holding_cost_before < 6e+06' in r['expression']]
        self.assertEqual(len(rows),2)
        train=next(r for r in rows if r['partition']=='discovery')['metrics']
        later=next(r for r in rows if r['partition']=='later')['metrics']
        self.assertEqual(train['comparison']['positiveLost'],8)
        self.assertEqual(later['comparison']['negativeExcluded'],1)
        self.assertEqual(later['comparison']['positiveLost'],1)
        self.assertEqual(later['counts']['unknownInputs'],1)

    def test_frozen_w3_and_budget(self):
        f=read(O/'frozen-review.json');self.assertEqual(f['trainASHA256'],q.sha(O/'stage-a.json'));self.assertEqual(f['trainBSHA256'],q.sha(O/'stage-b.json'))
        extra=read(O/'review-budget.json')['evaluations']+read(O/'sensitivity-budget.json')['evaluations']+374+12+6+len(read(O/'bounded-field-sensitivity.json'))
        self.assertLessEqual(extra,1180);self.assertLessEqual(18876+extra,40000)
        self.assertEqual(q.sha(O/'frozen-review.json'),read(O/'review-budget.json')['frozenSHA256'])

if __name__=='__main__':unittest.main(verbosity=2)
