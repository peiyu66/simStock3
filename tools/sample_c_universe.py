#!/usr/bin/env python3
"""Freeze the FT4 Sample C catalog universe and deterministic evaluation order."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
from collections import Counter
from pathlib import Path
from typing import Any


DEFAULT_EXCLUDED = {
    "1216", "1301", "1590", "1101", "1477", "2002", "2201", "2308",
    "2317", "2330", "2368", "2382", "2449", "2882", "2912", "3017",
    "3045", "3653", "8454", "8996",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def selection_key(seed: str, stock_id: str) -> str:
    return hashlib.sha256(f"{seed}|{stock_id}".encode()).hexdigest()


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--catalog", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--seed", required=True)
    parser.add_argument("--listed-on-or-before", default="20180102")
    parser.add_argument("--initial-batch", type=int, default=40)
    parser.add_argument("--increment-batch", type=int, default=20)
    parser.add_argument("--maximum-evaluated", type=int, default=100)
    args = parser.parse_args()

    catalog = json.loads(args.catalog.read_text(encoding="utf-8"))
    if not isinstance(catalog, list) or len(catalog) < 500:
        raise RuntimeError("TWSE catalog is missing or incomplete")
    report_dates = {str(row.get("出表日期", "")).strip() for row in catalog}
    if len(report_dates) != 1:
        raise RuntimeError(f"catalog has inconsistent report dates: {report_dates}")

    reason_counts: Counter[str] = Counter()
    eligible: list[dict[str, Any]] = []
    for row in catalog:
        stock_id = str(row.get("公司代號", "")).strip()
        listing_date = str(row.get("上市日期", "")).strip()
        if not re.fullmatch(r"[0-9]{4}", stock_id):
            reason_counts["nonFourDigitCompanyCode"] += 1
            continue
        if listing_date > args.listed_on_or_before:
            reason_counts["listedAfterCutoff"] += 1
            continue
        if str(row.get("產業別", "")).strip() == "91":
            reason_counts["TDRIndustry91"] += 1
            continue
        if stock_id in DEFAULT_EXCLUDED:
            reason_counts["sampleAOrB"] += 1
            continue
        eligible.append(
            {
                "stockID": stock_id,
                "stockName": str(row.get("公司簡稱", "")).strip(),
                "industryCode": str(row.get("產業別", "")).strip(),
                "listingDate": listing_date,
                "selectionKey": selection_key(args.seed, stock_id),
            }
        )

    eligible.sort(key=lambda row: (row["selectionKey"], row["stockID"]))
    for index, row in enumerate(eligible, start=1):
        if index <= args.initial_batch:
            batch = 1
        else:
            batch = 2 + (index - args.initial_batch - 1) // args.increment_batch
        row["selectionRank"] = index
        row["evaluationBatch"] = batch if index <= args.maximum_evaluated else "reserve"
        row["historicalDataStatus"] = "notChecked"
        row["group1QualificationStatus"] = "notEvaluated"

    if len({row["stockID"] for row in eligible}) != len(eligible):
        raise RuntimeError("duplicate stock IDs after filtering")
    if DEFAULT_EXCLUDED.intersection(row["stockID"] for row in eligible):
        raise RuntimeError("Sample A/B stock leaked into Sample C universe")

    args.output.mkdir(parents=True, exist_ok=True)
    write_csv(args.output / "candidate-universe.csv", eligible)
    manifest = {
        "formatVersion": 1,
        "phase": "FT4a",
        "catalogSource": "https://openapi.twse.com.tw/v1/opendata/t187ap03_L",
        "catalogReportDateROC": next(iter(report_dates)),
        "catalogSHA256": sha256(args.catalog),
        "catalogRowCount": len(catalog),
        "filters": {
            "companyCode": "exactly four ASCII digits",
            "securityType": "exclude industry 91 Taiwan depositary receipts",
            "listedOnOrBefore": args.listed_on_or_before,
            "excludeSampleAAndB": sorted(DEFAULT_EXCLUDED),
        },
        "candidateCount": len(eligible),
        "excludedCounts": dict(sorted(reason_counts.items())),
        "industryCounts": dict(sorted(Counter(
            row["industryCode"] for row in eligible
        ).items())),
        "selectionOrder": {
            "method": "ascending SHA256(seed + '|' + stockID)",
            "seed": args.seed,
            "initialBatch": args.initial_batch,
            "incrementBatch": args.increment_batch,
            "maximumEvaluated": args.maximum_evaluated,
        },
        "dataAvailability": {
            "catalog": "available",
            "historicalTWSE": "not checked until FT4b",
            "technicalAndSimulation": "not built until FT4b",
        },
        "sampleCSelected": False,
    }
    (args.output / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )


if __name__ == "__main__":
    main()
