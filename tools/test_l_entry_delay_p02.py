#!/usr/bin/env python3
"""Bounded LD data controls; composite searches run on synthetic fixtures only."""
import collections, json, unittest
import numpy as np
import l_entry_delay_p02 as p
import test_h_entry_composite_search as synthetic

class LDControls(unittest.TestCase):
    def test_price_opportunity_semantics(self):
        a=p.opportunity(100,list(range(1,11)),[102,99,98,100,98,101,100,100,100,100])
        self.assertEqual(a['lowestDates'],[3,5])
        self.assertEqual(a['firstLowerDate'],2)
        self.assertEqual(a['lowerSegments'],[[2,3],[5]])
        self.assertEqual(a['pathTransitions'],['higher','lower','higher'])
        self.assertTrue(a['fullOpportunity'])
        self.assertFalse(p.opportunity(100,list(range(10)),[100]*10)['fullOpportunity'])
        self.assertIsNone(p.opportunity(100,[1,2],[99,98])['fullOpportunity'])
        self.assertTrue(p.opportunity(100,[1,2],[99,98])['observedLower'])
        self.assertIsNone(p.opportunity(100,[],[])['lowestClose'])

    def test_warning_identity_rejected(self):
        stock=dict(ZDATESTART=1,ZSIMMONEYBASE=600,ZSIMINVESTAUTO=2)
        b=dict(formatVersion=5,dataRules='T3/S61',configuration=dict(start=1,budget=600,additions=2),
               snapshot=dict(status='normal'),locallyReleased=False)
        self.assertTrue(p.warning_valid(json.dumps(b),stock))
        b['dataRules']='T3/S59'
        with self.assertRaises(AssertionError):p.warning_valid(json.dumps(b),stock)
        self.assertFalse(p.warning_valid(None,stock))

    def test_saved_time_and_masks(self):
        cat=p.read(p.O/'feature-catalog.json');s=[i for i,c in enumerate(cat)if c['group']=='S']
        self.assertEqual(len(s),43)
        expected=p.read(p.P/'entry-events.json')
        ref={(e['sample'],e['window'],e['stock'],e['date']):e for e in expected}
        seen=0
        for label,windows in [('discovery',{1,2}),('later',{3})]:
            data=np.load(p.O/(label+'.npz'));keys=p.read(p.O/(label+'-keys.json'))
            self.assertEqual(data['X'].shape,(len(keys),284))
            np.testing.assert_array_equal(data['valid'],np.isfinite(data['X']))
            for op in p.read(p.O/(label+'-opportunities.json')):
                e=ref[(op['sample'],op['window'],op['stock'],op['anchor'])]
                self.assertIn(op['window'],windows)
                rows=[keys[i]for i in op['indices']]
                self.assertEqual([r['date']for r in rows],[e['date'],*e['futureDates']])
                self.assertEqual(op['lowestDates'],e['minimumDates'])
                self.assertEqual(op['observedLower'],e['hasLowerPrice'])
                self.assertTrue(np.isnan(data['X'][op['indices'][1:]][:,s]).all())
                if e['grade']==0:self.assertTrue(np.isnan(data['X'][op['indices'][0],s]).all())
                self.assertEqual(op['qualifiedOpportunity'] is None,
                    not op['completeTen']or bool(op['calendarGaps'])or bool(op['nonpositiveVolumeDates']))
                seen+=1
        self.assertEqual(seen,60)

    def test_atoms_have_no_outcomes_and_exact_pair_count(self):
        cat=p.read(p.O/'feature-catalog.json');d=np.load(p.O/'discovery.npz')
        atoms=p.gen.make_atoms(d['X'][d['anchors']],cat)
        specs=[dict(id=a.id,name=a.name,parent=a.parent,group=a.group,op=a.op,value=a.value)for a in atoms]
        self.assertEqual(json.loads(json.dumps(specs)),p.read(p.O/'atoms-no-outcome-ranking.json'))
        # Independent direct enumeration of allowed parent pairs, no formula evaluation/ranking.
        count=sum(a.parent!=b.parent for i,a in enumerate(atoms)for b in atoms[i+1:])
        self.assertEqual(count,p.read(p.O/'search-budget.json')['AND2'])
        for a in atoms:self.assertEqual(a.mask & ~a.valid,0)
        self.assertEqual(p.read(p.O/'summary.json')['realCompositeEvaluations'],0)

    def test_live_source_and_numerical_controls(self):
        for path,digest in p.read(p.O/'source-hashes.json').items():self.assertEqual(p.p1.sha(p.R/path),digest,path)
        a=p.read(p.O/'numerical-audit.json');c=a['checks']
        self.assertTrue(a['passed'])
        self.assertEqual(c['poststateAndFuturePoisonControls'],60)
        self.assertEqual(c['technicalRecorderGapFromT3'],3)
        self.assertEqual(c['selectedOfficialRows'],652)
        self.assertEqual(c['entryTechnicalSourceChecks'],570)
        self.assertGreater(c['marketNumericChecks'],0)
        self.assertGreater(c['priorFitEqualsPreviousStored'],0)

def main():
    assert not(p.O/'completion.json').exists(),'Do not rewrite completed evidence'
    suite=unittest.TestSuite([unittest.defaultTestLoader.loadTestsFromTestCase(LDControls),
                             unittest.defaultTestLoader.loadTestsFromTestCase(synthetic.Controls)])
    result=unittest.TextTestRunner(verbosity=2).run(suite)
    p.save('tests.json',dict(passed=result.wasSuccessful(),testMethods=result.testsRun,
        syntheticCases=synthetic.results,realCompositeEvaluations=0,
        sourceHashes={str(p.R/'tools'/name):p.p1.sha(p.R/'tools'/name)for name in
                      ['test_l_entry_delay_p02.py','test_h_entry_composite_search.py']}))
    raise SystemExit(0 if result.wasSuccessful()else 1)

if __name__=='__main__':main()
