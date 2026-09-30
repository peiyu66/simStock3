import unittest
import numpy as np
import h_entry_composite_p05 as w
from h_entry_composite_p05_cases import samefill,positive,negative
class P05Checks(unittest.TestCase):
 def test_frozen_masks_against_direct_formula(self):
  defs=w.read(w.p.P/'atoms-no-outcome-ranking.json');cat=w.read(w.p.P/'feature-catalog.json');names={c['name']:i for i,c in enumerate(cat)};frozen=w.read(w.p.O/'frozen.json')['candidates'];count=0
  for label in ('discovery','later'):
   X,_,_=w.p.dataset(label);x=lambda n:X[:,names[n]]
   direct={
    'HC-P3-01':((x('osc')>.0091)&(x('ma20_diff_z125')>-.62)&(x('ma20_diff_z125')<.69))|((x('market_kd_j')>26)&(x('market_kd_j')<93)&(x('delta_kd_k')<-.13)),
    'HC-P3-02':((x('t_low_diff_125')>19)&(x('ma60d')<5.6))|((x('ma20_diff_z125')>-.62)&(x('ma20_diff_z125')<.69)&(x('market_kd_d')>62)),
    'HC-P3-03':(x('kd_k_z125')>0)&(x('osc_is_max9')==0)&(x('market_z_125')>-.43)&(x('ma20d')<8.9),
    'HC-P3-04':(x('kd_k_z125')>.027)&(x('osc_is_max9')==0)&(x('ma20_diff_is_max9')==0)&(x('market_z_125')>-.43),
    'HC-P3-06':(x('osc_z250')>.031)&(x('ma60_diff_z250')>0)&(x('osc_is_max9')==0)&(x('market_z_125')>-.43)}
   aa=list(w.p.arrays(defs,X,cat))
   for n in frozen:
    if n['id']not in direct:continue
    fields={defs[i]['name']for b in n['expr']for i in b};valid=np.isfinite(X[:,[names[f]for f in fields]]).all(axis=1);actual,av=w.r.evaluate(n['expr'],aa)
    np.testing.assert_array_equal(actual,direct[n['id']]&valid);np.testing.assert_array_equal(av,valid);count+=len(actual)
  self.assertEqual(count,219010)
 def test_unknown_and_late_are_not_repaired_cheaper(self):
  a=dict(hit=True,wait=2,afterExit=False,missing=False,saving=-2,fillDate=20200103,lFill=False,early=False)
  self.assertTrue(negative(a));self.assertFalse(positive(dict(a,wait=None,saving=None,fillDate=None)))
  self.assertFalse(positive(dict(a,saving=4,afterExit=True)))
  self.assertFalse(samefill(a,dict(a,wait=3,fillDate=20200106)))
 def test_current_round_alignment_and_bounds(self):
  a=w.read(w.O/'analysis.json');self.assertEqual(a['currentHEntries'],1597);self.assertEqual(a['diagnosticVariants'],49)
  frozen={c['id']:c['expr']for c in w.read(w.p.O/'frozen.json')['candidates']}
  for n in a['candidates']:
   self.assertEqual(n['expr'],frozen[n['id']]);self.assertNotEqual(n['id'],'HC-P3-05')
   for label,d in n['current'].items():
    ids=[r['id']for r in d['baselineDetails']];self.assertEqual(len(ids),len(set(ids)))
    for row in d['baselineDetails']:
     self.assertLessEqual(row['entryDate'],row['exitDate'])
     if row['releaseDate']is not None:self.assertLess(row['entryDate'],row['releaseDate']);self.assertLessEqual(row['releaseDate'],row['exitDate'])
if __name__=='__main__':unittest.main()
