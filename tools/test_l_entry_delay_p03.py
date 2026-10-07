#!/usr/bin/env python3
"""Synthetic ranking, retention and validity controls for LD-P03."""
import unittest
import numpy as np
import l_entry_delay_p03 as p

class Controls(unittest.TestCase):
    def setUp(self):
        self.ops=[dict(qualifiedOpportunity=q,sample='C'if i<2 else'D',window=1,
                       stock=str(i),anchor=20200101+i)for i,q in enumerate([True,False,True,None])]
    def test_unknown_not_counterexample(self):
        m=p.metrics(9,15,self.ops)
        self.assertEqual((m['lower'],m['noLower'],m['unknown'],m['precision']),(1,0,1,1))
        self.assertLess(p.ranker(self.ops)(8,15),p.ranker(self.ops)(1,15))
    def test_both_retention_orderings_preserved(self):
        a=p.g.Node(((0,1),),1,15,'T',(1.,1,1,1,1,0,4,-2,-2,-1))
        b=p.g.Node(((0,2),),7,15,'T',(2/3,2,2,2,2,0,4,-2,-2,-1))
        self.assertGreater(a.score,b.score);self.assertGreater(p.breadth(b),p.breadth(a))
        r=p.Reservoir();r.add(a);r.add(b)
        self.assertEqual({n.expr:n.score for n in r.values()},{a.expr:a.score,b.expr:b.score})
    def test_or_requires_all_inputs(self):
        X=np.array([[1,1,np.nan,0],[1,1,0,0],[0,0,1,1],[0,1,0,1]],float)
        cat=[dict(name=str(i),parent=str(i),group='T',kind='boolean')for i in range(4)]
        a=p.g.make_atoms(X,cat);ids=[next(t.id for t in a if t.name==str(i)and t.value==1)for i in range(4)]
        n=p.g.make_node((tuple(ids[:2]),tuple(ids[2:])),a,lambda m,v:(0,))
        self.assertEqual(n.mask,6);self.assertEqual(n.valid,14)
    def test_choose_parent_diversity_and_cap(self):
        a=[p.g.Atom(i,str(i),str(i//2),'T','eq',1,1,15)for i in range(8)]
        nodes=[p.g.Node(((i,j),),1<<k,15,'T',(1.,1,1,1,1,0,4,-2,-2,-1))for k,(i,j)in enumerate([(0,2),(0,3),(1,2),(4,6)])]
        chosen=p.choose(nodes,a)
        self.assertEqual(len(chosen),3)
        self.assertTrue(any(n.expr==((4,6),)for n in chosen))

if __name__=='__main__':unittest.main(verbosity=2)
