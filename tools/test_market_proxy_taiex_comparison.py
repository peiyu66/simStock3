#!/usr/bin/env python3

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import market_proxy_taiex_comparison as study


class MarketProxyTaiexComparisonTests(unittest.TestCase):
    def test_average_ranks_keeps_ties(self) -> None:
        self.assertEqual(study.average_ranks([30, 10, 20, 20]), [4, 1, 2.5, 2.5])

    def test_correlations_identify_same_and_reversed_order(self) -> None:
        values = [1.0, 2.0, 4.0, 8.0]
        self.assertAlmostEqual(study.pearson(values, values), 1.0)
        self.assertAlmostEqual(study.spearman(values, list(reversed(values))), -1.0)

    def test_percentile_uses_linear_interpolation(self) -> None:
        self.assertEqual(study.percentile([0, 10], 0.5), 5)
        self.assertEqual(study.percentile([0, 10, 20], 0.9), 18)

    def test_sign_has_explicit_zero(self) -> None:
        self.assertEqual(study.sign(-0.1), -1)
        self.assertEqual(study.sign(0), 0)
        self.assertEqual(study.sign(0.1), 1)

    def test_comparison_metrics(self) -> None:
        rows = [
            {"proxy_return": -0.2, "taiex_return": -0.1},
            {"proxy_return": 0.1, "taiex_return": 0.2},
        ]
        result = study.comparison_metrics(rows)
        self.assertEqual(result["rows"], 2)
        self.assertEqual(result["direction_agreement_rate"], 1)
        self.assertAlmostEqual(result["median_absolute_difference"], 0.1)


if __name__ == "__main__":
    unittest.main()
