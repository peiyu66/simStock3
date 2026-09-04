#!/usr/bin/env python3

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import grade_trend_segments as segments


class GradeTrendSegmentTests(unittest.TestCase):
    def test_decision_base_dates_are_yyyymmdd_integers(self) -> None:
        self.assertEqual(segments.yyyymmdd(20170722), "2017-07-22")

    def test_late_threshold_reuses_two_existing_thresholds(self) -> None:
        self.assertEqual(segments.CONFIRMED_LATE_THRESHOLD, 0.911888)

    def test_improving_peak_strictly_crosses_into_late_at_threshold(self) -> None:
        boundary = segments.CONFIRMED_LATE_THRESHOLD
        self.assertEqual(
            segments.derive_segment(8, boundary - 0.000_001),
            "improving_seeking_peak_early",
        )
        self.assertEqual(
            segments.derive_segment(8, boundary),
            "improving_seeking_peak_late",
        )

    def test_worsening_bottom_strictly_crosses_into_late_at_threshold(self) -> None:
        boundary = -segments.CONFIRMED_LATE_THRESHOLD
        self.assertEqual(
            segments.derive_segment(10, boundary + 0.000_001),
            "worsening_seeking_bottom_early",
        )
        self.assertEqual(
            segments.derive_segment(10, boundary),
            "worsening_seeking_bottom_late",
        )

    def test_non_seeking_phases_remain_unchanged(self) -> None:
        expected = {
            0: "unavailable",
            1: "neutral",
            2: "improving_warning",
            3: "worsening_warning",
            6: "improving_cooldown",
            7: "worsening_cooldown",
            9: "improving_pulling_back",
            11: "worsening_rebounding",
        }
        self.assertEqual(
            {raw: segments.derive_segment(raw, None) for raw in expected},
            expected,
        )

    def test_each_derived_segment_collapses_to_original_raw_phase(self) -> None:
        fixtures = [
            (0, None), (1, None), (2, None), (3, None), (6, None), (7, None),
            (8, 0.7), (8, 1.0), (9, None), (10, -0.7), (10, -1.0), (11, None),
        ]
        for phase_raw, extreme in fixtures:
            segment = segments.derive_segment(phase_raw, extreme)
            self.assertEqual(segments.COLLAPSED_RAW[segment], phase_raw)

    def test_legacy_unsplit_confirmations_are_rejected(self) -> None:
        with self.assertRaises(Exception):
            segments.derive_segment(4, 1.0)
        with self.assertRaises(Exception):
            segments.derive_segment(5, -1.0)


if __name__ == "__main__":
    unittest.main()
