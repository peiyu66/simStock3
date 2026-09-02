#!/usr/bin/env python3

import unittest

import market_entry_rule_interaction as study


class MarketEntryRuleInteractionTests(unittest.TestCase):
    def test_candidate_stat_collapses_market_dates(self):
        rows = {
            date: {
                "score": 2.0 if date <= 40 else -2.0,
                "stocks": {("A", str(i)) for i in range(10)},
                "samples": {"A", "B"},
                "rows": [{"buy_date": date, "sample": "A", "stock_id": str(i)} for i in range(10)],
            }
            for date in range(1, 81)
        }
        result = study.candidate_stat("R", "M", rows, set(range(1, 41)))
        self.assertIsNotNone(result)
        self.assertGreater(result["standardized_effect"], 0)
        self.assertEqual(result["on_dates"], 40)
        self.assertEqual(result["off_dates"], 40)

    def test_common_market_shift(self):
        shifted = study.shifted_date_sets({"a": {1, 3}}, [1, 2, 3, 4], 1)
        self.assertEqual(shifted["a"], {2, 4})

    def test_synthetic_control(self):
        result = study.synthetic_control()
        self.assertTrue(result["passed"])
        self.assertGreater(result["plantedStandardizedEffect"], 0)
        self.assertLess(abs(result["removedStandardizedEffect"]), 0.25)

    def test_percentile(self):
        self.assertEqual(study.percentile([1, 2, 3, 4, 5], 0.5), 3)


if __name__ == "__main__":
    unittest.main()
