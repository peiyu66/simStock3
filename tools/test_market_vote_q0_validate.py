#!/usr/bin/env python3

import csv
import hashlib
import importlib.util
import tempfile
import unittest
from datetime import date, timedelta
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("market_vote_q0_validate.py")
SPEC = importlib.util.spec_from_file_location("market_vote_q0_validate", MODULE_PATH)
q0 = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(q0)


class MarketVoteQ0ValidateTests(unittest.TestCase):
    def test_qualifying_dates_enforces_frozen_shape_and_threshold(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "market-technical.csv"
            final = date(2026, 7, 22)
            first = final - timedelta(days=2_568)
            with path.open("w", newline="", encoding="utf-8") as handle:
                writer = csv.DictWriter(handle, fieldnames=["date", q0.SOURCE_FIELD])
                writer.writeheader()
                for index in range(2_569):
                    writer.writerow({
                        "date": (first + timedelta(days=index)).isoformat(),
                        q0.SOURCE_FIELD: -1 if index in (0, 2_568) else 0,
                    })
            original_hash = q0.MARKET_SHA256
            try:
                q0.MARKET_SHA256 = hashlib.sha256(path.read_bytes()).hexdigest()
                self.assertEqual(
                    q0.qualifying_dates(path),
                    {int(first.strftime("%Y%m%d")), 20260722},
                )
            finally:
                q0.MARKET_SHA256 = original_hash

    def test_zero_control_requires_every_delta_counter_to_be_zero(self):
        summary = {
            key: 0 for key in (
                "changedEventCount", "changedVoteCount", "changedGateCount",
                "firstDivergenceCount", "prestateMismatchCount", "outcomeDifferenceCount",
                "groupOutcomeDifferenceCount", "addedEventCount", "removedEventCount",
            )
        }
        summary.update(isZeroDecisionDelta=True, isZeroOutcomeDelta=True)
        diagnostics = {
            "mode": "never",
            "sourceRowCount": 2_569,
            "contributionsByPhase": {phase: 0 for phase in ("GRADE", "H_BUY", "L_BUY", "SELL", "ADD")},
            "evaluationsByPhase": {"GRADE": 0, "H_BUY": 1, "L_BUY": 1, "SELL": 1, "ADD": 1},
        }
        q0.validate_zero_control("never", summary, diagnostics)
        summary["changedVoteCount"] = 1
        with self.assertRaisesRegex(RuntimeError, "changedVoteCount"):
            q0.validate_zero_control("never", summary, diagnostics)

    def test_run_manifest_locks_sample_versions_and_resources(self):
        manifest = {
            "runID": "run",
            "sampleID": "A",
            "dataRuleVersion": "T2/S39",
            "ruleCommit": q0.FORMAL_RULE_COMMIT,
            "moneyBaseWan": 600,
            "automaticInvestments": 2,
            "through": "2026/07/22",
        }
        q0.validate_run_manifest(manifest, "run")
        manifest["sampleID"] = "B"
        with self.assertRaisesRegex(RuntimeError, "sample mismatch"):
            q0.validate_run_manifest(manifest, "run")


if __name__ == "__main__":
    unittest.main()
