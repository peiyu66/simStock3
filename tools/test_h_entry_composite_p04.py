"""Partition integrity and independent chronology checks for P04."""
import dataclasses,unittest
import h_entry_composite_p04 as q
class P04Controls(unittest.TestCase):
 def test_partition_and_training_only_cutpoints(self):
  protocol=q.read(q.O/'protocol.json');X,keys,rr=q.p.dataset('discovery');cat=q.read(q.p.P/'feature-catalog.json');allstocks={r['stock']for r in rr};held=[]
  eligible=[i for i,c in enumerate(cat)if c['name']!='tradingDaysSinceLastInvestment']
  for f in protocol['folds']:
   train=set(f['trainStocks']);test=set(f['heldStocks']);self.assertFalse(train&test);self.assertEqual(train|test,allstocks);held+=list(test)
   ix=[i for i,k in enumerate(keys)if k['stock']in train]
   mutated=X.copy();mutated[[i for i,k in enumerate(keys)if k['stock']in test]]=1e15
   actual=q.e.make_atoms(mutated[ix][:,eligible],[cat[i]for i in eligible]);defs=[{k:v for k,v in dataclasses.asdict(a).items()if k not in ('mask','valid')}for a in actual]
   self.assertEqual(q.json.loads(q.json.dumps(defs)),q.read(q.O/f"fold-{f['fold']}"/'atoms.json'))
  self.assertEqual(len(held),len(set(held)));self.assertEqual(set(held),allstocks)
 def test_training_compact_matches_scalar_and_partition(self):
  protocol=q.read(q.O/'protocol.json');f=protocol['folds'][0];defs=q.read(q.O/'fold-1/atoms.json');atoms,screen=q.compact(defs,'discovery',f['trainStocks'])
  self.assertEqual({r['stock']for r in screen.rounds},set(f['trainStocks']))
  self.assertTrue({r['stock']for r in screen.flat}<=set(f['trainStocks']))
  rng=q.np.random.default_rng(904)
  for _ in range(30):
   size=15*screen.n+11*screen.c;v=rng.random(size)>.1;m=(rng.random(size)>.4)&v;mm,vv=q.e.bits(m),q.e.bits(v)
   self.assertEqual(screen.metrics(mm,vv),q.scalar(screen,mm,vv))
if __name__=='__main__':unittest.main()
