import json
import unittest
from pathlib import Path
from sell_delay_p01 import classify, O

class ExitInventoryTests(unittest.TestCase):
    def test_recovery_gate_requires_cooldown_but_independent_cut_does_not(self):
        self.assertEqual(classify(['S-T02e'], False), 'unclassified')
        self.assertEqual(classify(['S-T01c', 'S-T02e'], False), 'profit')
        self.assertEqual(classify(['S-T01c', 'S-T02e'], True), 'both')
        self.assertEqual(classify(['S-T02g'], False), 'recovery')
        self.assertEqual(classify(['S-T02h'], True), 'recovery')

    def test_frozen_inventory_no_double_count_or_window_borrow(self):
        rows=json.loads((O/'sell-events.json').read_text())
        keys={(r['sample'],r['window'],r['stock_id'],r['trade_date']) for r in rows}
        self.assertEqual(len(rows),len(keys))
        ends={1:20200722,2:20230722,3:20260722}
        for r in rows:
            self.assertGreater(r['inventory_before'],0)
            self.assertEqual(len(r['futureDates']),r['futureAvailableDays'])
            self.assertLessEqual(r['futureAvailableDays'],10)
            self.assertEqual(r['futureDates'],sorted(set(r['futureDates'])))
            self.assertTrue(all(r['trade_date']<d<=ends[r['window']] for d in r['futureDates']))
        inventory=json.loads((O/'event-inventory.json').read_text())
        total=inventory['totals']
        self.assertEqual(total['sellEvents'],sum(total.get(k,0)for k in ['profit','recovery','both']))
        self.assertEqual(total['sellEvents'],total['completeTen']+total['censoredTen'])
        self.assertFalse(inventory['futurePriceEffectsAnalyzed'])

    def test_source_coverage_and_holding_reactivation(self):
        cat=json.loads((O/'feature-catalog.json').read_text());names={x['name'] for x in cat}
        self.assertEqual(len(cat),len(names))
        self.assertTrue({'inventory_before','unit_roi_before','holding_cost_before','tradingDaysSinceLastInvestment'}<=names)
        rows=json.loads((O/'source-coverage.json').read_text())
        self.assertFalse(any(x['status']=='P02-source-pending' for x in rows))
        for x in rows:
            if x['status']=='alias-to-SD-feature':self.assertIn(x['mappedFeature'],names)
        current=json.loads((O/'source-universe.json').read_text())
        covered={(x['scope'],x['field']) for x in rows}
        self.assertTrue(all((s,n) in covered for s,fields in current.items() for n in fields))

if __name__=='__main__':unittest.main()
