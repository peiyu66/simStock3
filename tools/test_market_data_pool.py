#!/usr/bin/env python3

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import market_data_pool as pool


def price_payload(close: str = "8,114.26") -> bytes:
    return json.dumps({
        "stat": "OK",
        "fields": list(pool.PRICE.fields),
        "data": [
            ["105/01/04", "8,315.79", "8,326.33", "8,109.09", close],
            ["105/01/05", "8,111.41", "8,127.52", "8,070.96", "8,119.73"],
        ],
    }).encode()


def activity_payload(close: str = "8,114.26") -> bytes:
    return json.dumps({
        "stat": "OK",
        "hints": "單位：元、股",
        "fields": list(pool.ACTIVITY.fields),
        "data": [
            ["105/01/04", "3,828,317,506", "77,036,676,791", "823,702", close, "-223.80"],
            ["105/01/05", "4,582,175,023", "89,206,768,814", "939,683", "8,119.73", "5.47"],
        ],
    }).encode()


class MarketDataPoolTests(unittest.TestCase):
    def test_price_parser_keeps_true_ohlc(self) -> None:
        rows = pool.parse_json_rows(pool.PRICE, price_payload(), "2016-01")
        self.assertEqual(rows[0]["date"], "2016-01-04")
        self.assertEqual(rows[0]["open"], "8315.79")
        self.assertEqual(rows[0]["high"], "8326.33")
        self.assertEqual(rows[0]["low"], "8109.09")
        self.assertEqual(rows[0]["close"], "8114.26")

    def test_activity_parser_keeps_int64_fields(self) -> None:
        rows = pool.parse_json_rows(pool.ACTIVITY, activity_payload(), "2016-01")
        self.assertEqual(rows[0]["volume_shares"], 3_828_317_506)
        self.assertEqual(rows[0]["trade_value"], 77_036_676_791)
        self.assertEqual(rows[0]["transaction_count"], 823_702)
        self.assertEqual(pool.volume_lots(rows[0]["volume_shares"]), "3828317.506")

    def test_schema_change_is_rejected(self) -> None:
        payload = json.loads(price_payload())
        payload["fields"][1] = "不同欄位"
        with self.assertRaises(pool.MarketDataError):
            pool.parse_json_rows(pool.PRICE, json.dumps(payload).encode(), "2016-01")

    def test_invalid_ohlc_is_rejected(self) -> None:
        payload = json.loads(price_payload())
        payload["data"][0][2] = "8,000.00"
        with self.assertRaises(pool.MarketDataError):
            pool.parse_json_rows(pool.PRICE, json.dumps(payload).encode(), "2016-01")

    def test_cache_is_immutable_and_digest_checked(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            revision = pool.save_source_revision(
                root, pool.PRICE, "2016-01", "https://example.invalid", price_payload(), {}
            )
            selected = pool.selected_revision(root, pool.PRICE, "2016-01")
            self.assertEqual(selected.sha256, revision.sha256)
            selected.raw_path.write_bytes(b"changed")
            with self.assertRaises(pool.MarketDataError):
                pool.selected_revision(root, pool.PRICE, "2016-01")

    def test_csv_parser_compares_numeric_rows_without_big5_headers(self) -> None:
        raw = (
            b'"header in big5"\n'
            b'"105/01/04","8,315.79","8,326.33","8,109.09","8,114.26",\n'
            b'"105/01/05","8,111.41","8,127.52","8,070.96","8,119.73",\n'
        )
        rows = pool.parse_csv_rows(pool.PRICE, raw, "2016-01")
        self.assertEqual(rows[0]["close"], "8114.26")


if __name__ == "__main__":
    unittest.main()
