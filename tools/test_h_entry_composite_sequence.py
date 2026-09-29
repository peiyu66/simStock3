import unittest
import numpy as np
import h_entry_composite_sequence as s
class SequenceTests(unittest.TestCase):
 def run_path(self,values,prices,qualified=False):
  atoms=[dict(feature=0,name='x',op='gt',value=0),dict(feature=1,name='y',op='lt',value=2)]
  X=np.array([[v,1]for v in values],float)
  keys=[dict(date=20260101+i,close=p,h_score=0 if i!=1 else -1,h_threshold=0)for i,p in enumerate(prices)]
  r=dict(id='test',entry=0,end=len(keys)-1,entry_date=20260101,entry_price=prices[0],sample='A',window=1,stock='1',kind='rise_fall',opportunity=True,censored=False,decline=2)
  return s.details([[0,1]],X,keys,[r],atoms,qualified)[0]
 def test_first_release_not_later_cheapest(self):
  r=self.run_path([1,0,1,0],[100,103,95,90]);self.assertEqual(r['release'],20260102);self.assertAlmostEqual(r['gain'],-3);self.assertTrue(r['beforeDecline'])
 def test_strict_boundary(self):self.assertEqual(self.run_path([1,0],[100,99])['releasePrice'],99)
 def test_unreleased_fall_no_credit(self):
  r=self.run_path([1,1],[100,80]);self.assertTrue(r['noRelease']);self.assertEqual(r['gain'],0);self.assertIsNone(r['releasePrice'])
 def test_unreleased_rise_cost(self):self.assertAlmostEqual(self.run_path([1,1],[100,120])['gain'],-20)
 def test_not_triggered_zero(self):
  r=self.run_path([0,1],[100,80]);self.assertFalse(r['hit']);self.assertEqual(r['gain'],0)
 def test_missing_release_visible(self):self.assertTrue(self.run_path([1,np.nan],[100,99])['releaseMissing'])
 def test_original_qualification_separate(self):
  r=self.run_path([1,0,0],[100,99,101],True);self.assertEqual(r['release'],20260103);self.assertAlmostEqual(r['gain'],-1)
 def test_symmetric_clip(self):
  self.assertEqual(self.run_path([1,0],[100,50])['clippedGain'],10);self.assertEqual(self.run_path([1,0],[100,150])['clippedGain'],-10)
if __name__=='__main__':unittest.main()
