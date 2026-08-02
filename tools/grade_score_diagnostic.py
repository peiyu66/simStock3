#!/usr/bin/env python3
"""Compare current Grade bands with score-based bands on a Baseline store."""

from __future__ import annotations

import argparse
import csv
import json
from collections import Counter
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

from grade_mechanics_audit import (
    GRADE_NAMES,
    add_candidate,
    buy_signal,
    grade_rule_outputs,
    grouped_rows,
    read_rows,
    sell_signal,
)


def efficiency_score(roi: float, days: float) -> float:
    if days <= 0:
        return 0
    return roi * 100 / days if roi >= 0 else roi * days / 100


def score_grade(rounds: float, days: float, roi: float) -> int:
    if not (rounds > 2 or days > 360):
        return 0
    score = efficiency_score(roi, days)
    if score > 30:
        return 3
    if score > 15:
        return 2
    if score > 7:
        return 1
    if score < -20:
        return -3
    if score < -10:
        return -2
    return -1


def action_for(
    row: dict[str, Any],
    previous: dict[str, Any],
    history: list[dict[str, Any]],
    grade: int,
) -> tuple[str, str]:
    buy = buy_signal(row, previous, grade)
    inventory_before = (
        float(previous["qty_inventory"] or 0) > 0
        or float(row["qty_sell"] or 0) > 0
    )
    if not inventory_before:
        return buy or "none", "not-held"
    if sell_signal(row, previous, history, grade):
        return buy or "none", "sell"
    if add_candidate(row, previous, grade, buy):
        return buy or "none", "add-candidate"
    return buy or "none", "hold"


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    if not rows:
        return
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sample", required=True)
    parser.add_argument("--store", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    through = datetime.strptime(manifest["through"], "%Y/%m/%d") - timedelta(hours=8)
    rows, stocks = read_rows(args.store)
    rows = [row for row in rows if row["date_time"] <= through]
    rows_by_sid = grouped_rows(rows)

    current_counts: Counter[int] = Counter()
    score_counts: Counter[int] = Counter()
    transitions: Counter[tuple[int, int]] = Counter()
    buy_changes: Counter[tuple[int, int, str, str]] = Counter()
    hold_changes: Counter[tuple[int, int, str, str]] = Counter()
    rule_changes: Counter[tuple[str, float, float]] = Counter()
    validation = Counter()
    examples: list[dict[str, Any]] = []

    for stock_rows in rows_by_sid.values():
        for index, row in enumerate(stock_rows):
            if index == 0 or row["date"] < row["date_start"]:
                continue
            previous = stock_rows[index - 1]
            rounds = float(previous["roll_rounds"] or 0)
            days = float(row["decision_days"] or 0)
            roi = float(row["decision_roi"] or 0)
            current = int(row["grade"])
            proposed = score_grade(rounds, days, roi)
            if rounds > 2 or days > 360:
                current_counts[current] += 1
                score_counts[proposed] += 1
                transitions[(current, proposed)] += 1
                if current != proposed:
                    examples.append(
                        {
                            "sample": args.sample,
                            "date": row["date"].strftime("%Y/%m/%d"),
                            "group": row["stock_group"],
                            "sid": row["sid"],
                            "name": row["name"],
                            "roi": round(roi, 4),
                            "days": round(days, 2),
                            "score": round(efficiency_score(roi, days), 4),
                            "current": GRADE_NAMES[current],
                            "proposed": GRADE_NAMES[proposed],
                        }
                    )

            history = stock_rows[:index]
            current_outputs = grade_rule_outputs(row, previous, current)
            proposed_outputs = grade_rule_outputs(row, previous, proposed)
            inventory_before = (
                float(previous["qty_inventory"] or 0) > 0
                or float(row["qty_sell"] or 0) > 0
            )
            for rule, current_output in current_outputs.items():
                prefix = rule[0]
                if prefix == "L" and row["sim_rule"] == "H":
                    continue
                if prefix in ("S", "A") and not inventory_before:
                    continue
                if prefix == "A" and float(row["qty_sell"] or 0) > 0:
                    continue
                proposed_output = proposed_outputs[rule]
                if current_output != proposed_output:
                    rule_changes[(rule, current_output, proposed_output)] += 1
            current_buy, current_hold = action_for(
                row, previous, history, current
            )
            proposed_buy, proposed_hold = action_for(
                row, previous, history, proposed
            )
            stored_buy = row["sim_rule"] or "none"
            stored_hold = (
                "sell"
                if float(row["qty_sell"] or 0) > 0
                else (
                    "add-candidate"
                    if row["sim_rule_invest"] == "A"
                    else "hold"
                )
            )
            validation["buy_rows"] += 1
            validation["buy_mismatch"] += int(current_buy != stored_buy)
            if inventory_before:
                validation["hold_rows"] += 1
                validation["hold_mismatch"] += int(current_hold != stored_hold)
            if current_buy != proposed_buy:
                buy_changes[(current, proposed, current_buy, proposed_buy)] += 1
            if inventory_before and current_hold != proposed_hold:
                hold_changes[(current, proposed, current_hold, proposed_hold)] += 1

    transition_rows = [
        {
            "sample": args.sample,
            "current": GRADE_NAMES[current],
            "proposed": GRADE_NAMES[proposed],
            "days": count,
        }
        for (current, proposed), count in sorted(transitions.items(), reverse=True)
    ]
    decision_rows = [
        {
            "sample": args.sample,
            "layer": layer,
            "currentGrade": GRADE_NAMES[key[0]],
            "proposedGrade": GRADE_NAMES[key[1]],
            "currentDecision": key[2],
            "proposedDecision": key[3],
            "days": count,
        }
        for layer, changes in (("buy", buy_changes), ("holding", hold_changes))
        for key, count in sorted(changes.items())
    ]
    rule_rows = [
        {
            "sample": args.sample,
            "rule": rule,
            "currentOutput": current_output,
            "proposedOutput": proposed_output,
            "days": count,
        }
        for (rule, current_output, proposed_output), count in sorted(
            rule_changes.items()
        )
    ]
    examples.sort(key=lambda item: abs(item["score"]), reverse=True)
    summary = {
        "runID": f"gsc01-{args.sample.lower()}-score-grade-diagnostic-20260802",
        "sample": args.sample,
        "sourceRunID": manifest["runID"],
        "sourceRuleCommit": manifest.get("ruleCommit"),
        "dataRuleVersion": manifest["dataRuleVersion"],
        "ruleVersion": manifest["ruleVersion"],
        "through": manifest["through"],
        "stockCount": len(stocks),
        "tradeCount": len(rows),
        "eligibleGradeDays": sum(current_counts.values()),
        "changedGradeDays": sum(
            count for (current, proposed), count in transitions.items()
            if current != proposed
        ),
        "currentDistribution": {
            GRADE_NAMES[grade]: current_counts[grade] for grade in sorted(GRADE_NAMES)
        },
        "proposedDistribution": {
            GRADE_NAMES[grade]: score_counts[grade] for grade in sorted(GRADE_NAMES)
        },
        "buyDecisionChangedDays": sum(buy_changes.values()),
        "holdingDecisionChangedDays": sum(hold_changes.values()),
        "ruleOutputChangedDays": {
            rule: sum(
                count
                for (changed_rule, _, _), count in rule_changes.items()
                if changed_rule == rule
            )
            for rule in sorted({key[0] for key in rule_changes})
        },
        "decisionReconstructionValidation": dict(validation),
        "candidateThresholds": {
            "wow": "> 30",
            "high": "> 15",
            "fine": "> 7",
            "none": "before activation only",
            "weak": "-10 through 7",
            "low": "-20 through < -10",
            "damn": "< -20",
        },
        "limitations": [
            "Same-day decision changes are diagnostic and do not replace simUpdate.",
            "Score-based Grade changes future trades, ROI, days, and later Grade recursively.",
        ],
    }

    args.output.mkdir(parents=True, exist_ok=True)
    write_csv(args.output / "grade-transitions.csv", transition_rows)
    write_csv(args.output / "decision-changes.csv", decision_rows)
    write_csv(args.output / "rule-output-changes.csv", rule_rows)
    write_csv(args.output / "largest-grade-changes.csv", examples[:200])
    (args.output / "manifest.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
