"""Meaningful chronology, missing-data, grammar and discovery controls for HC-D."""
import itertools
import unittest
import numpy as np
import h_entry_composite as h

class TrajectoryTests(unittest.TestCase):
    def test_rise_fall_trough_and_exit(self):
        r=h.cut_round([100,105,105,103,96,98,106],[1,1,1,1,1,1,0],0,6,True)
        self.assertEqual((r['decline'],r['trough'],r['opportunity']),(3,4,True))
    def test_sold_before_fall_is_control(self):
        r=h.cut_round([100,105,104],[1,1,0],0,2,True)
        self.assertIsNone(r['decline'])
    def test_initial_fall_not_relabelled_by_later_rebound(self):
        r=h.cut_round([100,98,101,96,105],[1,1,1,1,0],0,4,True)
        self.assertEqual(r['kind'],'fell_before_rise')
    def test_unfinished_never_positive(self):
        r=h.cut_round([100,103,98,96],[1,1,1,1],0,3,False)
        self.assertTrue(r['censored']);self.assertFalse(r['opportunity'])
    def test_boundary_low_not_confirmed(self):
        r=h.cut_round([100,103,98,96],[1,1,1,0],0,3,True)
        self.assertTrue(r['bottom_boundary']);self.assertFalse(r['opportunity'])
    def test_low_above_original_is_not_cheaper_opportunity(self):
        r=h.cut_round([100,110,105,112],[1,1,1,0],0,3,True)
        self.assertFalse(r['opportunity'])

class GrammarTests(unittest.TestCase):
    def test_interval_strict_boundaries_and_nan(self):
        x=np.array([[0.],[1.],[2.],[np.nan]])
        a=dict(feature=0,op='between',value=[0,2])
        mask,valid=h.atom_array(a,x)
        np.testing.assert_array_equal(mask,[False,True,False,False])
        np.testing.assert_array_equal(valid,[True,True,True,False])
    def test_or_missing_field_does_not_create_signal(self):
        x=np.array([[1,1,np.nan,0],[1,1,0,0],[0,0,1,1]],float)
        atoms=[dict(feature=j,op='gt',value=.5) for j in range(4)]
        mask,valid=h.eval_expr([[0,1],[2,3]],atoms,x)
        np.testing.assert_array_equal(mask,[False,True,True])
        np.testing.assert_array_equal(valid,[False,True,True])
    def test_bitmask_has_no_padding_events(self):
        self.assertEqual(h.bitmask([True,False,True]),5)
    def test_generic_atoms_recover_planted_and_interval_or(self):
        # Exhaustive balanced grid, thresholds not injected into the generator.
        x=np.array(list(itertools.product([-2,-1,0,1,2],repeat=4)),float)
        cat=[dict(name=f'x{j}',parent=f'x{j}',kind='continuous') for j in range(4)]
        atoms=h.make_atoms(x,cat)
        masks=[h.bitmask(h.atom_array(a,x)[0]) for a in atoms]
        def find(target,features):
            for i,a in enumerate(atoms):
                for j,b in enumerate(atoms[i+1:],i+1):
                    if {a['feature'],b['feature']}==set(features) and masks[i]&masks[j]==h.bitmask(target):return [i,j]
            self.fail('planted combination not recovered')
        left=find((x[:,0]>0)&(x[:,1]<0),(0,1))
        right=find((x[:,2]>0)&(x[:,3]<0),(2,3))
        find((x[:,0]>-1)&(x[:,0]<1)&(x[:,1]>0),(0,1))
        result,_=h.eval_expr([left,right],atoms,x)
        np.testing.assert_array_equal(result,((x[:,0]>0)&(x[:,1]<0))|((x[:,2]>0)&(x[:,3]<0)))
    def test_round_reference_never_leaves_decline_to_exit(self):
        x=np.zeros((5,1));keys=[dict(close=v) for v in [100,103,98,90,105]]
        rounds=[dict(entry=0,decline=2,end=4,minimum=90,entry_price=100,opportunity=True,censored=False)]
        _,meta,indices=h.search_observations(x,keys,rounds)
        self.assertEqual(indices[0],0)
        self.assertTrue(all(2<=j<=4 for j in indices[1:]));self.assertEqual(len(meta),5)

if __name__=='__main__':unittest.main()
