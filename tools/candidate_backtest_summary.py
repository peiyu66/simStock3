#!/usr/bin/env python3
"""Validate and summarize one completed simStock3 candidate replay."""

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


def finite_number(value: Any, label: str) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError) as error:
        raise RuntimeError(f"Invalid numeric value for {label}: {value!r}") from error
    if not math.isfinite(number):
        fail(f"Non-finite numeric value for {label}: {value!r}")
    return number


def close_enough(left: float, right: float) -> bool:
    return math.isclose(left, right, rel_tol=1e-9, abs_tol=1e-8)


def sqlite_integrity(path: Path) -> None:
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        result = connection.execute("PRAGMA integrity_check").fetchone()
    finally:
        connection.close()
    if result is None or result[0] != "ok":
        fail(f"SQLite integrity failed: {path}: {result}")


def score_rows(decision: dict[str, Any]) -> tuple[list[dict[str, Any]], float, float]:
    rows = decision.get("groupMainScoreDeltas")
    if not isinstance(rows, list) or not rows:
        fail("Decision summary has no groupMainScoreDeltas")
    baseline_total = 0.0
    candidate_total = 0.0
    for index, row in enumerate(rows):
        if not isinstance(row, dict):
            fail(f"Invalid group score row at index {index}")
        baseline_total += finite_number(row.get("baseline"), f"group[{index}].baseline")
        candidate_total += finite_number(row.get("candidate"), f"group[{index}].candidate")
    return rows, baseline_total, candidate_total


def labels(items: Any, count_key: str = "count", label_key: str = "key") -> str:
    if not isinstance(items, list) or not items:
        return "none"
    output: list[str] = []
    for item in items:
        if isinstance(item, dict):
            output.append(f"{item.get(label_key, '?')} ({item.get(count_key, '?')})")
    return ", ".join(output) if output else "none"


def build_summary(
    run_dir: Path,
    delta_dir: Path,
    expected_candidate_id: str,
    expected_sample: str,
) -> str:
    baseline = load_json(run_dir / "baseline.json")
    manifest = load_json(run_dir / "manifest.json")
    decision = load_json(delta_dir / "decision-summary.json")
    analysis_path = delta_dir / "analysis-summary.json"
    analysis = load_json(analysis_path) if analysis_path.is_file() else {}

    if not (delta_dir / ".complete").is_file():
        fail(f"DecisionDelta completion marker is missing: {delta_dir}")

    candidate_id = str(decision.get("candidateID", ""))
    sample = str(decision.get("sampleID", ""))
    run_id = str(decision.get("candidateRunID", ""))
    decision_base_id = str(decision.get("baselineDecisionBaseID", ""))
    if candidate_id != expected_candidate_id:
        fail(f"Candidate ID mismatch: {candidate_id} != {expected_candidate_id}")
    if sample != expected_sample:
        fail(f"Sample mismatch: {sample} != {expected_sample}")
    if baseline.get("runID") != run_id or manifest.get("runID") != run_id:
        fail("Candidate run ID differs between DecisionDelta, baseline, and manifest")
    if baseline.get("sampleID") != sample or manifest.get("sampleID") != sample:
        fail("Sample differs between DecisionDelta, baseline, and manifest")

    invalid_values = int(manifest.get("invalidValueCount", 0))
    excluded_no_transaction = int(manifest.get("excludedNoTransactionCount", 0))
    if invalid_values != 0:
        fail(f"Candidate contains {invalid_values} invalid values")

    problem_stocks = [
        f"{item.get('id')} {item.get('name')}"
        for item in baseline.get("stocks", [])
        if item.get("moneyLacked") or item.get("status") != "正常"
    ]
    if problem_stocks:
        fail("Capital or result status problem: " + ", ".join(problem_stocks))

    prestate_mismatches = int(decision.get("prestateMismatchCount", 0))
    if prestate_mismatches != 0:
        fail(f"DecisionDelta has {prestate_mismatches} pre-state mismatches")

    is_zero_decision = bool(decision.get("isZeroDecisionDelta", False))
    delta_sqlite = delta_dir / "decision-delta.sqlite"
    if delta_sqlite.is_file():
        sqlite_integrity(delta_sqlite)
    elif not is_zero_decision:
        fail("Non-zero DecisionDelta is missing decision-delta.sqlite")

    if not is_zero_decision:
        if not analysis:
            fail("Non-zero DecisionDelta is missing analysis-summary.json")
        if not (delta_dir / ".analysis-complete").is_file():
            fail("Non-zero DecisionDelta is missing .analysis-complete")
        if analysis.get("candidateID") != candidate_id:
            fail("Analysis candidate ID does not match DecisionDelta")

    groups, baseline_total, candidate_total = score_rows(decision)
    reported_candidate = finite_number(baseline.get("combinedScore"), "baseline.combinedScore")
    reported_delta = finite_number(decision.get("combinedMainScoreDelta"), "combinedMainScoreDelta")
    if not close_enough(candidate_total, reported_candidate):
        fail(f"Candidate score mismatch: groups={candidate_total} baseline.json={reported_candidate}")
    if not close_enough(candidate_total - baseline_total, reported_delta):
        fail("Combined score delta does not equal candidate minus formal baseline")

    lines = [
        "# Candidate backtest summary",
        "",
        f"- Candidate: `{candidate_id}`",
        f"- Sample: `{sample}`",
        f"- Run: `{run_id}`",
        f"- DecisionBase: `{decision_base_id}`",
        f"- Data rule: `{baseline.get('dataRuleVersion', '?')}`",
        f"- Candidate rule version: `{baseline.get('ruleVersion', '?')}`",
        f"- Formal rule commit: `{baseline.get('ruleCommit', '?')}`",
        f"- Fixed-three-year score: `{baseline_total:.3f} -> {candidate_total:.3f}` (`{reported_delta:+.3f}`)",
        "",
        "## Group scores",
        "",
        "| Group | Formal Baseline | Candidate | Delta |",
        "|---|---:|---:|---:|",
    ]
    for row in groups:
        base = finite_number(row.get("baseline"), "group baseline")
        candidate = finite_number(row.get("candidate"), "group candidate")
        delta = finite_number(row.get("delta"), "group delta")
        lines.append(f"| {row.get('group', '?')} | {base:.3f} | {candidate:.3f} | {delta:+.3f} |")

    window_rows = analysis.get("groupScoreDeltas", []) if analysis else []
    lines.extend(["", "## Changed window/group scores", ""])
    if isinstance(window_rows, list) and window_rows:
        lines.extend(
            [
                "| Window | Group | Formal Baseline | Candidate | Delta |",
                "|---|---|---:|---:|---:|",
            ]
        )
        for row in window_rows:
            base = finite_number(row.get("baselineScore"), "window baseline")
            candidate = finite_number(row.get("candidateScore"), "window candidate")
            delta = finite_number(row.get("delta"), "window delta")
            lines.append(
                f"| {row.get('windowStart', '?')} | {row.get('group', '?')} | "
                f"{base:.3f} | {candidate:.3f} | {delta:+.3f} |"
            )
    else:
        lines.append("No changed window/group ending score.")

    lines.extend(
        [
            "",
            "## DecisionDelta checks",
            "",
            f"- Pre-state mismatches: `{prestate_mismatches}`",
            f"- First divergences: `{int(decision.get('firstDivergenceCount', 0))}`",
            f"- Outcome differences: `{int(decision.get('outcomeDifferenceCount', 0))}`",
            f"- Changed events: `{int(decision.get('changedEventCount', 0))}`",
            f"- Reconvergences: `{int(decision.get('reconvergenceCount', 0))}`",
            f"- Invalid values: `{invalid_values}`",
            f"- No-transaction exclusions: `{excluded_no_transaction}`",
            f"- First divergences by stock: {labels(analysis.get('firstDivergencesByStock'))}",
            f"- First divergences by window: {labels(analysis.get('firstDivergencesByWindow'))}",
            f"- First divergences by Grade: {labels(analysis.get('firstDivergencesByGrade'))}",
            "",
            "This summary verifies output identity and integrity. Adoption or the next sample still requires explicit review and authorization.",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument("--delta-dir", type=Path, required=True)
    parser.add_argument("--expected-candidate-id", required=True)
    parser.add_argument("--expected-sample", choices=("A", "B", "C", "D", "E"), required=True)
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()

    try:
        summary = build_summary(
            arguments.run_dir,
            arguments.delta_dir,
            arguments.expected_candidate_id,
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
