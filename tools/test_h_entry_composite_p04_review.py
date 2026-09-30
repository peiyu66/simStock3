import unittest
import numpy as np
import h_entry_composite_p04_review as v
from h_entry_composite_p04_supplement import neighbors
class DiagnosticControls(unittest.TestCase):
 def test_or_missing_and_drop_shared(self):
  a=[(np.array([True,True,False]),np.ones(3,bool)),(np.array([True,False,True]),np.ones(3,bool)),(np.array([False,True,True]),np.array([False,True,True]))]
  m,valid=v.r.evaluate([[0,1],[0,2]],a)
  self.assertEqual(m.tolist(),[False,True,False]);self.assertEqual(valid.tolist(),[False,True,True])
  m,_=v.r.evaluate([[1],[2]],a);self.assertEqual(m.tolist(),[False,True,True])
 def test_adjacent_cut_coordinates(self):
  defs=[dict(name='x',op='between',value=[0.,2.]),dict(name='x',op='lt',value=-1.),dict(name='x',op='lt',value=0.),dict(name='x',op='gt',value=1.),dict(name='x',op='gt',value=2.),dict(name='x',op='gt',value=3.),dict(name='flag',op='eq',value=1.)]
  out=list(neighbors([[0,6]],defs));self.assertEqual([x['value']for x in out],[[-1.,2.],[1.,2.],[0.,1.],[0.,3.]])
  self.assertTrue(all(x['atom']==0 for x in out));self.assertEqual(defs[0]['value'],[0.,2.])
 def test_train_only_iqr(self):
  defs=[dict(name='x',op='gt',value=1.),dict(name='flag',op='eq',value=1.)];cat=[dict(name='x',kind='continuous'),dict(name='flag',kind='boolean')];x=np.array([[0.,1.],[2.,1.],[4.,0.],[6.,0.],[999.,1.]])
  a=list(v.variant_specs([[0,1]],defs,x,cat,[0,1,2,3]));x[-1]=1e20;b=list(v.variant_specs([[0,1]],defs,x,cat,[0,1,2,3]));self.assertEqual(a,b);self.assertEqual([s['value']for s in a if s['kind']=='cut'],[.7,1.3])
 def test_unknown_is_not_success(self):
  # No independently observed candidate path must remain explicitly unknown.
  b=dict(id='x',sample='A',window=1,stock='x',hit=True,target=False,control=True,censored=False,bottomBoundary=False,entryDate=20200101,wait=1,saving=5.,missing=False,early=False,lowValid=0,lowOff=0)
  z=v.totals([b],[]);self.assertEqual(z['unknownPathHits'],1);self.assertEqual(z['knownCheaper10'],0)
if __name__=='__main__':unittest.main()
