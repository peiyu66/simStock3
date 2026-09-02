#!/usr/bin/env python3

from __future__ import annotations

import math
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import market_technical as mt


class MarketTechnicalTests(unittest.TestCase):
    def test_swift_round_uses_ties_away_from_zero(self) -> None:
        self.assertEqual(mt.swift_round(1.5), 2)
        self.assertEqual(mt.swift_round(-1.5), -2)
        self.assertEqual(mt.swift_round(1.49), 1)
        self.assertEqual(mt.swift_round(-1.49), -1)

    def test_flat_price_has_stable_kd_and_zero_z(self) -> None:
        rows = [
            {"open": 100, "high": 100, "low": 100, "close": 100}
            for _ in range(300)
        ]
        result = mt.calculate_price(rows)
        self.assertEqual(result[-1]["market_kd_k"], 50)
        self.assertEqual(result[-1]["market_z_250"], 0)
        self.assertTrue(all(math.isfinite(row[field]) for row in result for field in mt.PRICE_FIELDS))

    def test_first_price_row_matches_tupdate_initialization(self) -> None:
        result = mt.calculate_price([{"open": 10, "high": 12, "low": 8, "close": 11}])[0]
        self.assertEqual(result["market_kd_k"], 50)
        self.assertEqual(result["market_osc_ema_12"], 10.5)
        self.assertEqual(result["market_ma_20"], 0)
        self.assertEqual(result["market_high_max_9"], 0)

    def test_activity_zero_is_legal_and_finite(self) -> None:
        result = mt.calculate_activity([0.0] * 300)
        self.assertEqual(result[-1]["ma_20_diff"], 0)
        self.assertEqual(result[-1]["z_250"], 0)
        self.assertTrue(all(math.isfinite(row[field]) for row in result for field in mt.ACTIVITY_SUFFIXES))

    def test_activity_uses_current_observation(self) -> None:
        result = mt.calculate_activity([100.0, 200.0])
        self.assertEqual(result[-1]["ma_20"], 150)
        self.assertEqual(result[-1]["max_9"], 200)
        self.assertEqual(result[-1]["min_9"], 100)

    def test_market_contract_has_frozen_field_counts(self) -> None:
        self.assertEqual(len(mt.PRICE_FIELDS), 47)
        self.assertEqual(len(mt.ACTIVITY_SUFFIXES), 18)
        self.assertEqual(len(mt.TECHNICAL_FIELDS), 101)
        self.assertEqual(len(mt.catalog_rows()), 101)

    def test_prefix_results_do_not_depend_on_future_rows(self) -> None:
        rows = [
            {
                "date": f"day-{index:03d}",
                "open": 100 + index / 10,
                "high": 101 + index / 10,
                "low": 99 + index / 10,
                "close": 100 + index / 10,
                "volume_lots": 1000 + index,
                "trade_value": 1_000_000 + index,
                "transaction_count": 10_000 + index,
            }
            for index in range(40)
        ]
        prefix = mt.calculate_market(rows[:20])
        full = mt.calculate_market(rows)
        self.assertEqual(prefix, full[:20])


if __name__ == "__main__":
    unittest.main()
