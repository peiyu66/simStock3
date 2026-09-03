#!/usr/bin/env python3

import unittest

import market_sell_rule_interaction as study


class MarketSellRuleInteractionTests(unittest.TestCase):
    def event(self, **updates):
        row = {
            "planned_action": "HOLD", "executed_action": "NONE",
            "decision_score": 3.0, "unit_roi_before": 3.0,
            "holding_days_before": 80.0, "grade": 0,
        }
        row.update(updates)
        return row

    def test_reconstructs_predeclared_profitable_boundaries(self):
        self.assertEqual(
            study.one_vote_short_profitable_gates(self.event()),
            ["S-T01c", "S-T01e"],
        )
        self.assertEqual(
            study.one_vote_short_profitable_gates(
                self.event(decision_score=2, unit_roi_before=10, holding_days_before=9)
            ),
            ["S-T01g", "S-T01h"],
        )

    def test_excludes_st01b_six_point_fallback(self):
        self.assertEqual(
            study.one_vote_short_profitable_gates(
                self.event(decision_score=5, unit_roi_before=1, holding_days_before=2)
            ),
            [],
        )

    def test_st01d_is_represented_by_its_superset_st01c(self):
        self.assertEqual(
            study.one_vote_short_profitable_gates(
                self.event(decision_score=3, unit_roi_before=4, holding_days_before=20)
            ),
            ["S-T01c"],
        )

    def test_candidate_stat_collapses_market_dates(self):
        rows = {
            date: {
                "score": 2.0 if date <= 40 else -2.0,
                "stocks": {("A", str(i)) for i in range(10)},
                "samples": {"A", "B"},
                "rows": [{"event_date": date, "sample": "A", "stock_id": str(i)} for i in range(10)],
            }
            for date in range(1, 81)
        }
        result = study.candidate_stat("M", rows, set(range(1, 41)))
        self.assertIsNotNone(result)
        self.assertGreater(result["standardized_effect"], 0)
        self.assertEqual(result["on_dates"], 40)
        self.assertEqual(result["off_dates"], 40)

    def test_synthetic_control(self):
        result = study.synthetic_control()
        self.assertTrue(result["passed"])
        self.assertGreater(result["plantedStandardizedEffect"], 0)
        self.assertLess(abs(result["removedStandardizedEffect"]), 0.25)

    def test_percentile(self):
        self.assertEqual(study.percentile([1, 2, 3, 4, 5], 0.5), 3)


if __name__ == "__main__":
    unittest.main()
