"""Focused controls for retrospective opportunities and causal data separation."""
import json
import math
import unittest
from decimal import Decimal, ROUND_HALF_UP
import numpy as np
from sell_delay_p02 import O, opportunity, net_sell, warning_valid

class OpportunityControls(unittest.TestCase):
    def test_all_tied_high_dates_and_higher_segments(self):
        days=list(range(1,11));prices=[99,105,105,100,99,103,105,98,101,100]
        o=opportunity(100,days,prices,2)
        self.assertEqual(o['highestDates'],[2,3,7])
        self.assertEqual(o['higherHighestDates'],[2,3,7])
        self.assertEqual(o['higherSegments'],[[2,3],[6,7],[9]])
        self.assertEqual(o['firstHigherDate'],2)
        self.assertEqual(o['higherDays'],5)
        self.assertTrue(o['fullOpportunity'])
        self.assertAlmostEqual(o['minGainBeforeFirstPeakPct'],-1)

    def test_equal_lower_and_truncated_never_count_as_full_success(self):
        equal=opportunity(100,list(range(10)),[100]*10,1)
        self.assertFalse(equal['fullOpportunity'])
        self.assertEqual(equal['higherHighestDates'],[])
        lower=opportunity(100,[1,2],[90,110],1)
        self.assertTrue(lower['observedHigher'])
        self.assertIsNone(lower['fullOpportunity'])
        empty=opportunity(100,[],[],1)
        self.assertIsNone(empty['highestClose'])
        self.assertFalse(empty['completeTen'])

    def test_fee_rounding_minimum_and_same_quantity(self):
        for price,qty in [(1,1),(1,2),(10,2),(100,1),(12.5,17),(99.95,16)]:
            gross=Decimal(str(price))*qty*1000
            fee=max(Decimal(20),(gross*Decimal('.001425')).quantize(Decimal(1),rounding=ROUND_HALF_UP))
            tax=(gross*Decimal('.003')).quantize(Decimal(1),rounding=ROUND_HALF_UP)
            self.assertAlmostEqual(net_sell(price,qty),float(gross-fee-tax))
        self.assertEqual(opportunity(100,[1],[100],5)['netProceedsDelta'],[0])

    def test_warning_decoder_rejects_wrong_identity_and_invalid_continuation(self):
        stock=dict(ZDATESTART=1,ZSIMMONEYBASE=600,ZSIMINVESTAUTO=2)
        rec=dict(formatVersion=5,dataRules='T3/S59',configuration=dict(start=1,budget=600,additions=2),snapshot=dict(status='normal'),locallyReleased=False)
        self.assertTrue(warning_valid(json.dumps(rec),stock))
        for patch in [dict(dataRules='T3/S57'),dict(continuationFloor=1),dict(locallyReleased=True),dict(snapshot=dict(status='normal',prewarningFailureDays=3,prewarningReason='priceBottom'))]:
            with self.assertRaises(AssertionError):warning_valid(json.dumps({**rec,**patch}),stock)

    def test_saved_data_has_exact_horizon_and_no_future_S(self):
        cat=json.loads((O/'feature-catalog.json').read_text())
        scols=[i for i,c in enumerate(cat) if c['group']=='S'];total=0
        for label in ('discovery','later'):
            data=np.load(O/f'{label}.npz');keys=json.loads((O/f'{label}-keys.json').read_text())
            ops=json.loads((O/f'{label}-opportunities.json').read_text());total+=len(ops)
            future=np.array([k['offset']>0 for k in keys])
            self.assertTrue(np.isnan(data['X'][future][:,scols]).all())
            self.assertTrue(np.array_equal(data['valid'],np.isfinite(data['X'])))
            for op in ops:
                path=[keys[i] for i in op['indices']]
                self.assertEqual([p['offset'] for p in path],list(range(len(path))))
                self.assertLessEqual(len(path),11)
                self.assertTrue(all(p['window']==op['window'] and p['stock']==op['stock'] for p in path))
                self.assertEqual(op['highestDates'],[p['date'] for p in path[1:] if p['close']==op['highestClose']])
            self.assertEqual(len(data['anchors']),len(ops))
        self.assertEqual(total,1609)

    def test_actual_s_controls_and_source_checks_complete(self):
        a=json.loads((O/'numerical-audit.json').read_text())['checks']
        self.assertEqual(a['poststateAndFuturePoisonControls'],1609)
        self.assertEqual(a['originalSaleFeeTaxProfit'],1609)
        self.assertEqual(a['investmentGapMatchesP01'],1609)
        self.assertEqual(a['selectedOfficialPositiveClose'],13494)
        self.assertGreater(a['persistedPostFitTransitions'],40000)

    def test_calendar_gaps_are_unknown_and_warmup_is_missing(self):
        cat=json.loads((O/'feature-catalog.json').read_text())
        z=next(i for i,c in enumerate(cat) if c['name']=='t_z125')
        unknown=0;gaps=0;early=0
        for label in ('discovery','later'):
            keys=json.loads((O/f'{label}-keys.json').read_text())
            X=np.load(O/f'{label}.npz')['X']
            for i,k in enumerate(keys):
                if k['priceObservations']<250:
                    early+=1
                    self.assertTrue(np.isnan(X[i,z]))
            for op in json.loads((O/f'{label}-opportunities.json').read_text()):
                if op['calendarGapDates']:
                    gaps+=1
                    self.assertIsNone(op['qualifiedOpportunity'])
                if op['qualifiedOpportunity'] is None:unknown+=1
                else:self.assertEqual(op['qualifiedOpportunity'],op['fullOpportunity'])
        self.assertEqual((gaps,unknown,early),(4,17,7))

if __name__=='__main__':unittest.main()
