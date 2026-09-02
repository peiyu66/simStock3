#!/usr/bin/env python3

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import market_data_pool as pool
import market_snapshot_reuse as reuse


class MarketSnapshotReuseTests(unittest.TestCase):
    def test_add_years_keeps_fixed_window_boundary(self) -> None:
        self.assertEqual(reuse.add_years("2017-07-22", 3), "2020-07-22")

    def test_line_prefix_keeps_header_and_requested_rows(self) -> None:
        data = b"a,b\n1,2\n3,4\n5,6\n"
        self.assertEqual(reuse.line_prefix(data, 2), b"a,b\n1,2\n3,4\n")

    def test_hashed_bundle_rejects_changed_content(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            payload = b"original\n"
            (root / "data.csv").write_bytes(payload)
            manifest = {
                "bundle_id": "fixture",
                "files": {"data.csv": pool.sha256(payload)},
            }
            (root / "manifest.json").write_text(json.dumps(manifest))
            (root / ".complete").write_text("fixture\n")
            reuse.verify_hashed_bundle(
                root, id_key="bundle_id", file_hashes_key="files"
            )
            (root / "data.csv").write_bytes(b"changed\n")
            with self.assertRaises(pool.MarketDataError):
                reuse.verify_hashed_bundle(
                    root, id_key="bundle_id", file_hashes_key="files"
                )

    def test_three_windows_are_derived_from_baseline_manifest(self) -> None:
        baselines = {
            "A": {"manifest": {
                "periodStarts": ["2017/07/22", "2020/07/22", "2023/07/22"],
                "through": "2026/07/22",
            }}
        }
        self.assertEqual(
            reuse.window_specs(baselines),
            [
                {"window_id": "W1", "declared_start": "2017-07-22", "declared_end": "2020-07-22"},
                {"window_id": "W2", "declared_start": "2020-07-22", "declared_end": "2023-07-22"},
                {"window_id": "W3", "declared_start": "2023-07-22", "declared_end": "2026-07-22"},
            ],
        )


if __name__ == "__main__":
    unittest.main()
