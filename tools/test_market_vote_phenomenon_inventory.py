#!/usr/bin/env python3

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import market_vote_phenomenon_inventory as inventory


class MarketVotePhenomenonInventoryTests(unittest.TestCase):
    def test_window_boundaries_belong_to_later_window(self) -> None:
        self.assertEqual(inventory.window_for(20170722), 1)
        self.assertEqual(inventory.window_for(20200721), 1)
        self.assertEqual(inventory.window_for(20200722), 2)
        self.assertEqual(inventory.window_for(20230722), 3)
        self.assertEqual(inventory.window_for(20260722), 3)
        self.assertIsNone(inventory.window_for(20260723))

    def test_percentile_uses_linear_interpolation(self) -> None:
        self.assertEqual(inventory.percentile([0, 10], 0.5), 5)
        self.assertEqual(inventory.percentile([0, 10, 20], 0.9), 18)

    def test_companion_fields_are_not_direct_levels(self) -> None:
        row = inventory.classify_field({
            "field": "market_volume_max_9",
            "category": "market_activity",
            "source": "x",
            "formula_family": "x",
            "unit": "張",
        })
        self.assertEqual(row["candidate_role"], "extreme-comparison-only")
        self.assertFalse(row["level_allowed"])
        self.assertFalse(row["change_allowed"])

    def test_scale_free_fields_allow_levels(self) -> None:
        row = inventory.classify_field({
            "field": "market_ma_20_diff_z_125",
            "category": "price",
            "source": "x",
            "formula_family": "x",
            "unit": "標準分數",
        })
        self.assertTrue(row["level_allowed"])
        self.assertTrue(row["change_allowed"])
        self.assertTrue(row["standalone_allowed"])

    def test_fixed_anchors_are_semantic(self) -> None:
        self.assertEqual(inventory.fixed_anchors("market_z_125", "標準分數"), [("zero", 0.0)])
        self.assertEqual(
            inventory.fixed_anchors("market_kd_k", "無單位"),
            [("fixed-20", 20.0), ("fixed-50", 50.0), ("fixed-80", 80.0)],
        )

    def test_reindex_mask_maps_once_by_date(self) -> None:
        source_dates = [20200101, 20200103, 20200105]
        target_dates = [20191231, 20200101, 20200102, 20200103, 20200105]
        source_mask = (1 << 0) | (1 << 2)
        self.assertEqual(
            inventory.reindex_mask(source_mask, source_dates, target_dates),
            (1 << 1) | (1 << 4),
        )


if __name__ == "__main__":
    unittest.main()
