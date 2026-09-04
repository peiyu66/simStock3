#!/usr/bin/env python3

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import market_price_path as path


def rows(closes: list[float]) -> list[dict[str, object]]:
    return [
        {"date": f"day-{index:03d}", "close": close}
        for index, close in enumerate(closes)
    ]


class MarketPricePathTests(unittest.TestCase):
    def test_phase_raw_values_match_t3_contract(self) -> None:
        self.assertEqual(list(path.PHASES), list(range(10)))
        self.assertEqual(path.PHASES[1], ("sideways", "盤整"))
        self.assertEqual(path.PHASES[9], ("rebounding_late", "反彈後期"))

    def test_barrier_uses_sample_deviation_and_clamps(self) -> None:
        self.assertEqual(path.volatility_barrier([0.0] * 40), 0.05)
        self.assertEqual(
            path.volatility_barrier([0.2 if index % 2 == 0 else -0.2 for index in range(40)]),
            0.15,
        )
        self.assertIsNone(path.volatility_barrier([0.0] * 39))

    def test_python_port_matches_swift_early_late_fixture(self) -> None:
        closes = [100.0] * 41 + [106, 109, 80, 80, 60, 75, 75]
        result = path.calculate_labels(rows(closes))
        self.assertEqual(result[40]["phase_raw"], 1)
        self.assertEqual(result[41]["phase_raw"], 2)
        self.assertEqual(result[42]["phase_raw"], 3)
        self.assertEqual(result[43]["phase_raw"], 5)
        self.assertIn(result[44]["phase_raw"], (6, 7))
        self.assertEqual(result[45]["phase_raw"], 7)
        self.assertEqual(result[46]["phase_raw"], 9)
        self.assertIn(result[47]["phase_raw"], (2, 3))

    def test_first_forty_rows_are_unavailable(self) -> None:
        result = path.calculate_labels(rows([100.0] * 45))
        self.assertEqual([row["phase_raw"] for row in result[:40]], [0] * 40)
        self.assertEqual([row["phase_raw"] for row in result[40:]], [1] * 5)

    def test_appending_future_rows_does_not_change_prefix(self) -> None:
        prefix = [100.0] * 41 + [106, 109, 105]
        full = prefix + [103, 101, 99, 96]
        self.assertEqual(
            path.calculate_labels(rows(prefix)),
            path.calculate_labels(rows(full))[: len(prefix)],
        )

    def test_generated_transitions_are_legal(self) -> None:
        closes = (
            [100.0] * 41
            + [106, 109, 105, 110, 102, 102, 95, 104, 90, 98, 104, 95]
            + [92] * 25
        )
        result = path.calculate_labels(rows(closes))
        self.assertEqual(path.transition_mismatches(result), [])


if __name__ == "__main__":
    unittest.main()
