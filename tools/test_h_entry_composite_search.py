#!/usr/bin/env python3
"""Planted end-to-end retrieval, category/missingness and anti-crowding controls."""
import itertools,json,unittest
from pathlib import Path
import numpy as np
import h_entry_composite_search as s
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'exports/h-entry-composite-p02-20260929'
results=[]
class Controls(unittest.TestCase):
 def run_case(self,label,X,cat,y,required_shape):
  target=s.bits(y);valid=(1<<len(y))-1
  def rank(m,v):
   tp=(m&target).bit_count();fp=(m&~target).bit_count();fn=(target&~m).bit_count()
   # No hard target hint/branch whitelist; evaluate every generated expression on synthetic labels.
   return (-(fp+fn),tp,-fp)
  atoms,nodes,counts,strata=s.search(X,cat,rank)
  found=[n for n in nodes if n.mask==target and n.valid==valid and (len(n.expr)==2 if required_shape=='OR' else len(n.expr)==1 and len(n.expr[0])==required_shape)]
  self.assertTrue(found,label)
  if required_shape=='OR':self.assertGreater(counts.get('OR',0),0)
  results.append(dict(case=label,counts=counts,strata=strata,found=[[[dict(name=atoms[i].name,op=atoms[i].op,value=atoms[i].value) for i in b] for b in n.expr] for n in found[:1]]))
 def boolean_data(self,groups):
  X=np.array(list(itertools.product((0.,1.),repeat=len(groups))))
  cat=[dict(name=f'x{i}',parent=f'x{i}',group=g,kind='boolean') for i,g in enumerate(groups)]
  return X,cat
 def test_planted(self):
  for label,groups,k in [('pure-T',list('TTTT'),2),('S-pair',list('SSTT'),2),('AND3',list('TSMT'),3),('AND4',list('TSMT'),4)]:
   X,cat=self.boolean_data(groups);y=np.all(X[:,:k]==1,axis=1);self.run_case(label,X,cat,y,k)
 def test_two_OR_forms(self):
  X,cat=self.boolean_data(list('TSMT'));self.run_case('two-branches',X,cat,((X[:,0]==1)&(X[:,1]==1))|((X[:,2]==1)&(X[:,3]==1)),'OR')
  self.run_case('shared-parent-branch',X,cat,(X[:,0]==1)&((X[:,1]==1)|(X[:,2]==1)),'OR')
 def test_interval(self):
  X=np.array(list(itertools.product(range(-4,5),(0,1),(0,1))),float)
  cat=[dict(name='range',parent='range',group='T',kind='continuous'),dict(name='s',parent='s',group='S',kind='boolean'),dict(name='m',parent='m',group='M',kind='boolean')]
  self.run_case('wide-interval',X,cat,(X[:,0]>-2)&(X[:,0]<2)&(X[:,1]==1),2)
 def test_market_crowding(self):
  X,cat=self.boolean_data(list('TSMT'));y=(X[:,0]==1)&(X[:,1]==1)
  # Many market aliases of a strong single signal generate thousands of superficially good market pairs.
  for i in range(40):
   X=np.column_stack([X,X[:,0]]);cat.append(dict(name=f'near-market{i}',parent=f'near-market{i}',group='M',kind='boolean'))
  self.run_case('source-reservation-vs-market-aliases',X,cat,y,2)
 def test_categories_and_missing(self):
  X=np.array([[1,0],[2,1],[8,1],[9,1],[np.nan,1]],float);cat=[dict(name='phase',parent='phase',group='S',kind='category',values=[1,2,8,9]),dict(name='t',parent='t',group='T',kind='boolean')]
  a=s.make_atoms(X,cat);self.assertTrue(all(x.op in ('eq','ne') for x in a if x.name=='phase'));self.assertTrue(all(not (x.valid&(1<<4)) for x in a if x.name=='phase'))
  a1=next(x for x in a if x.name=='phase');a2=next(x for x in a if x.name=='t');n=s.make_node(((a1.id,a2.id),),a,lambda m,v:(0,));self.assertFalse(n.mask&(1<<4))
 def test_maturity_and_missing_OR(self):
  from h_entry_composite_p02 import market_ready
  m={'price_mature_250':'true','market_volume_mature_250':'false','market_value_mature_250':'false','market_transaction_mature_250':'false'}
  self.assertTrue(market_ready('market_kd_k',m));self.assertFalse(market_ready('market_volume_ma_20',m));self.assertFalse(market_ready('market_kd_k',None))
  X,cat=self.boolean_data(list('TSMT'));X[0,0]=np.nan
  a=s.make_atoms(X,cat);ones=[next(x.id for x in a if x.name==f'x{i}' and x.op=='eq' and x.value==1) for i in range(4)]
  n=s.make_node((tuple(ones[:2]),tuple(ones[2:])),a,lambda m,v:(0,));self.assertFalse(n.valid&1);self.assertFalse(n.mask&1)
  # An unavailable value is never encoded as category zero and cannot activate its negation.
  self.assertTrue(all(not (x.mask&1) for x in a if x.name=='x0'))
 def test_phase_transition_boundaries(self):
  from h_entry_composite_p02 import phase_next,fit_update
  self.assertEqual(phase_next(.2,8,.9,.8),(1,None));self.assertEqual(phase_next(.4,8,.9,.8),(6,None))
  self.assertEqual(phase_next(-1.0,11,-1.2,-.65),(10,-1.0))
  self.assertEqual(phase_next(.7,8,1.1,1.),(9,1.1))
 def test_same_parent_not_two_values(self):
  X=np.array([[-3,-1],[-1,1],[1,3],[3,5]],float);cat=[dict(name='x',parent='same',group='T',kind='continuous'),dict(name='dx',parent='same',group='T',kind='continuous')]
  a,n,c,g=s.search(X,cat,lambda m,v:(m.bit_count(),));self.assertEqual(c,{});self.assertFalse(n)
if __name__=='__main__':
 suite=unittest.defaultTestLoader.loadTestsFromTestCase(Controls);r=unittest.TextTestRunner(verbosity=2).run(suite)
 if r.wasSuccessful() and not (OUT/'completion.json').exists():(OUT/'synthetic-controls.json').write_text(json.dumps(dict(passed=True,testMethods=r.testsRun,cases=results),ensure_ascii=False,indent=2)+'\n')
 raise SystemExit(0 if r.wasSuccessful() else 1)
