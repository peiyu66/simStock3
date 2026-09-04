#!/usr/bin/env python3
"""Validate and summarize one score-only full-period candidate replay."""

from __future__ import annotations

import argparse
import json
import math
import sqlite3
import sys
from pathlib import Path
from typing import Any


def fail(message: str) -> None:
    raise RuntimeError(message)


def load_json(path: Path) -> dict[str, Any]:
    if not path.is_file():
        fail(f"Missing JSON file: {path}")
    with path.open(encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        fail(f"Expected JSON object: {path}")
    return value


def number(value: Any, label: str) -> float:
    try:
        result = float(value)
    except (TypeError, ValueError) as error:
        raise RuntimeError(f"Invalid numeric value for {label}: {value!r}") from error
    if not math.isfinite(result):
        fail(f"Non-finite numeric value for {label}: {value!r}")
    return result


def sqlite_integrity(path: Path) -> None:
    if not path.is_file():
        fail(f"Missing SQLite file: {path}")
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        result = connection.execute("PRAGMA integrity_check").fetchone()
    finally:
        connection.close()
    if result is None or result[0] != "ok":
        fail(f"SQLite integrity failed: {path}: {result}")


def validate_run(
    run_dir: Path,
    expected_run_id: str,
    expected_sample: str,
) -> tuple[dict[str, Any], dict[str, Any]]:
    manifest = load_json(run_dir / "manifest.json")
    result = load_json(run_dir / "baseline.json")
    complete = run_dir / ".complete"
    if not complete.is_file() or complete.read_text(encoding="utf-8").strip() != expected_run_id:
        fail(f"Completion marker mismatch: {run_dir}")
    if manifest.get("runID") != expected_run_id or result.get("runID") != expected_run_id:
        fail(f"Run ID mismatch: {run_dir}")
    if manifest.get("sampleID") != expected_sample or result.get("sampleID") != expected_sample:
        fail(f"Sample mismatch: {run_dir}")
    if int(manifest.get("invalidValueCount", 0)) != 0:
        fail(f"Run contains invalid values: {run_dir}")
    if int(manifest.get("excludedNoTransactionCount", 0)) != 0:
        fail(f"Run contains no-transaction exclusions: {run_dir}")
    period_starts = manifest.get("periodStarts")
    if not isinstance(period_starts, list) or len(period_starts) != 1:
        fail(f"Run is not a single full-period profile: {run_dir}")
    sqlite_integrity(run_dir / "browse.store")
    return manifest, result


def keyed(items: Any, key: str, label: str) -> dict[str, dict[str, Any]]:
    if not isinstance(items, list):
        fail(f"Expected list for {label}")
    output: dict[str, dict[str, Any]] = {}
    for item in items:
        if not isinstance(item, dict) or not isinstance(item.get(key), str):
            fail(f"Invalid {label} row: {item!r}")
        item_key = item[key]
        if item_key in output:
            fail(f"Duplicate {label} key: {item_key}")
        output[item_key] = item
    return output


def build_summary(
    run_dir: Path,
    reference_run_dir: Path,
    expected_run_id: str,
    expected_sample: str,
) -> str:
    manifest, candidate = validate_run(run_dir, expected_run_id, expected_sample)
    reference_manifest = load_json(reference_run_dir / "manifest.json")
    reference_id = str(reference_manifest.get("runID", ""))
    if not reference_id:
        fail("Reference manifest has no runID")
    reference_manifest, reference = validate_run(
        reference_run_dir, reference_id, expected_sample
    )

    matching_fields = (
        "dataRuleVersion",
        "ruleCommit",
        "historyStart",
        "through",
        "moneyBaseWan",
        "automaticInvestments",
        "stockCount",
        "periodStarts",
    )
    for field in matching_fields:
        if manifest.get(field) != reference_manifest.get(field):
            fail(
                f"Candidate/reference {field} mismatch: "
                f"{manifest.get(field)!r} != {reference_manifest.get(field)!r}"
            )

    candidate_score = number(candidate.get("combinedScore"), "candidate combinedScore")
    reference_score = number(reference.get("combinedScore"), "reference combinedScore")
    candidate_groups = keyed(candidate.get("groups"), "group", "candidate group")
    reference_groups = keyed(reference.get("groups"), "group", "reference group")
    if candidate_groups.keys() != reference_groups.keys():
        fail("Candidate/reference group sets differ")
    if not math.isclose(
        sum(number(row.get("mainScore"), "candidate group score") for row in candidate_groups.values()),
        candidate_score,
        rel_tol=1e-9,
        abs_tol=1e-8,
    ):
        fail("Candidate group scores do not equal combined score")

    candidate_stocks = keyed(candidate.get("stocks"), "id", "candidate stock")
    reference_stocks = keyed(reference.get("stocks"), "id", "reference stock")
    if candidate_stocks.keys() != reference_stocks.keys():
        fail("Candidate/reference stock sets differ")

    changed_stocks: list[tuple[str, dict[str, Any], dict[str, Any]]] = []
    for stock_id, row in candidate_stocks.items():
        before = reference_stocks[stock_id]
        numeric_changed = any(
            not math.isclose(
                number(row.get(field), f"candidate {stock_id} {field}"),
                number(before.get(field), f"reference {stock_id} {field}"),
                rel_tol=1e-9,
                abs_tol=1e-8,
            )
            for field in ("roi", "averageDays", "rounds")
        )
        categorical_changed = any(
            row.get(field) != before.get(field)
            for field in ("grade", "moneyLacked", "status")
        )
        if numeric_changed or categorical_changed:
            changed_stocks.append((stock_id, before, row))

    problem_stocks = [
        f"{row.get('id')} {row.get('name')}"
        for row in candidate_stocks.values()
        if row.get("moneyLacked") or row.get("status") != "正常"
    ]

    lines = [
        "# Candidate full-period stress summary",
        "",
        f"- Sample: `{expected_sample}`",
        f"- Run: `{expected_run_id}`",
        f"- Reference: `{reference_id}`",
        f"- Data rule: `{manifest.get('dataRuleVersion', '?')}`",
        f"- Candidate rule version: `{manifest.get('ruleVersion', '?')}`",
        f"- Formal rule commit: `{manifest.get('ruleCommit', '?')}`",
        f"- Full-period score: `{reference_score:.3f} -> {candidate_score:.3f}` (`{candidate_score - reference_score:+.3f}`)",
        "",
        "## Group results",
        "",
        "| Group | Baseline score | Candidate score | Score delta | ROI delta | Days delta |",
        "|---|---:|---:|---:|---:|---:|",
    ]
    for group_name, row in candidate_groups.items():
        before = reference_groups[group_name]
        base_score = number(before.get("mainScore"), f"{group_name} baseline score")
        next_score = number(row.get("mainScore"), f"{group_name} candidate score")
        roi_delta = number(row.get("averageROI"), f"{group_name} candidate ROI") - number(
            before.get("averageROI"), f"{group_name} baseline ROI"
        )
        days_delta = number(row.get("averageDays"), f"{group_name} candidate days") - number(
            before.get("averageDays"), f"{group_name} baseline days"
        )
        lines.append(
            f"| {group_name} | {base_score:.3f} | {next_score:.3f} | "
            f"{next_score - base_score:+.3f} | {roi_delta:+.3f} | {days_delta:+.3f} |"
        )

    lines.extend(["", "## Changed stock outcomes", ""])
    if changed_stocks:
        lines.extend(
            [
                "| Stock | Group | ROI delta | Days delta | Rounds delta | Grade |",
                "|---|---|---:|---:|---:|---|",
            ]
        )
        for stock_id, before, row in changed_stocks:
            roi_delta = number(row.get("roi"), f"{stock_id} candidate ROI") - number(
                before.get("roi"), f"{stock_id} baseline ROI"
            )
            days_delta = number(row.get("averageDays"), f"{stock_id} candidate days") - number(
                before.get("averageDays"), f"{stock_id} baseline days"
            )
            rounds_delta = number(row.get("rounds"), f"{stock_id} candidate rounds") - number(
                before.get("rounds"), f"{stock_id} baseline rounds"
            )
            grade = str(row.get("grade", "?"))
            if grade != str(before.get("grade", "?")):
                grade = f"{before.get('grade', '?')} -> {grade}"
            lines.append(
                f"| {stock_id} {row.get('name', '')} | {row.get('group', '?')} | "
                f"{roi_delta:+.3f} | {days_delta:+.3f} | {rounds_delta:+.0f} | {grade} |"
            )
    else:
        lines.append("No changed stock ending outcome.")

    lines.extend(
        [
            "",
            "## Integrity checks",
            "",
            f"- Changed stock outcomes: `{len(changed_stocks)}`",
            f"- Invalid values: `{int(manifest.get('invalidValueCount', 0))}`",
            f"- No-transaction exclusions: `{int(manifest.get('excludedNoTransactionCount', 0))}`",
            f"- Capital/status problems: `{len(problem_stocks)}`"
            + (f" ({', '.join(problem_stocks)})" if problem_stocks else ""),
            "- Candidate and reference browse.store integrity: `ok`",
            "- DecisionDelta: not produced by design for full-period score-only replay",
            "",
            "This summary verifies output identity and integrity. Adoption or the next sample still requires explicit review and authorization.",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument("--reference-run-dir", type=Path, required=True)
    parser.add_argument("--expected-run-id", required=True)
    parser.add_argument("--expected-sample", choices=("A", "B", "C", "D", "E"), required=True)
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()
    try:
        summary = build_summary(
            arguments.run_dir,
            arguments.reference_run_dir,
            arguments.expected_run_id,
            arguments.expected_sample,
        )
    except (OSError, ValueError, RuntimeError, sqlite3.Error) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    if arguments.output is not None:
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(summary, encoding="utf-8")
    print(summary)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
