#!/usr/bin/env python3
"""Analyze the first five eligible entry signals in the E-LC05 S2 path."""

from __future__ import annotations

import argparse
import csv
import json
import sqlite3
from collections import defaultdict
from pathlib import Path


FIELD_BITS = {
    "grade": 1 << 1,
    "score": 1 << 2,
    "threshold": 1 << 3,
    "planned": 1 << 4,
    "executed": 1 << 5,
    "inventory": 1 << 6,
    "roll_roi": 1 << 12,
    "roll_days": 1 << 13,
    "roll_rounds": 1 << 14,
}

CANDIDATE_COLUMNS = {
    "grade": "candidate_grade",
    "score": "candidate_score",
    "threshold": "candidate_threshold",
    "planned": "candidate_planned_action",
    "executed": "candidate_executed_action",
    "inventory": "candidate_inventory_before",
    "roll_roi": "candidate_roll_roi_before",
    "roll_days": "candidate_roll_days_before",
    "roll_rounds": "candidate_roll_rounds_before",
}


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline-db", type=Path, required=True)
    parser.add_argument("--baseline-manifest", type=Path, required=True)
    parser.add_argument("--s1-delta-db", type=Path, required=True)
    parser.add_argument("--s1-summary", type=Path, required=True)
    parser.add_argument("--s1-run-manifest", type=Path, required=True)
    parser.add_argument("--s2-delta-db", type=Path, required=True)
    parser.add_argument("--s2-summary", type=Path, required=True)
    parser.add_argument("--s2-run-manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def event_key(window_start: int, window_end: int, stock_id: str, trade_date: int, phase: int) -> tuple:
    return (window_start, window_end, stock_id, trade_date, phase)


def load_baseline(path: Path) -> tuple[dict[tuple, dict], dict[str, dict], dict[tuple, list[int]]]:
    connection = sqlite3.connect(path)
    connection.row_factory = sqlite3.Row
    stocks = {
        row["stock_id"]: {"name": row["name"], "group": row["group_name"]}
        for row in connection.execute("SELECT stock_id,name,group_name FROM stocks")
    }
    events: dict[tuple, dict] = {}
    dates: dict[tuple, set[int]] = defaultdict(set)
    for row in connection.execute(
        """
        SELECT e.event_id,w.start_date window_start,w.end_date window_end,s.stock_id,
               e.trade_date,e.phase,e.grade,e.decision_score score,e.decision_threshold threshold,
               e.planned_action planned,e.executed_action executed,e.inventory_before inventory,
               e.roll_roi_before roll_roi,e.roll_days_before roll_days,e.roll_rounds_before roll_rounds
        FROM decision_events e JOIN windows w USING(window_id) JOIN stocks s USING(stock_key)
        ORDER BY w.start_date,s.stock_id,e.trade_date,e.phase
        """
    ):
        key = event_key(row["window_start"], row["window_end"], row["stock_id"], row["trade_date"], row["phase"])
        events[key] = dict(row)
        dates[(row["window_start"], row["window_end"], row["stock_id"])].add(row["trade_date"])
    connection.close()
    return events, stocks, {key: sorted(value) for key, value in dates.items()}


def candidate_events(baseline: dict[tuple, dict], delta_path: Path) -> dict[tuple, dict]:
    events = {key: dict(value) for key, value in baseline.items()}
    connection = sqlite3.connect(delta_path)
    connection.row_factory = sqlite3.Row
    for row in connection.execute("SELECT * FROM event_deltas ORDER BY delta_id"):
        key = event_key(row["window_start"], row["window_end"], row["stock_id"], row["trade_date"], row["phase"])
        kind = row["kind"]
        if kind == 3:
            events.pop(key, None)
            continue
        base = {} if kind == 2 else dict(events[key])
        changed = row["changed_fields"]
        for field, bit in FIELD_BITS.items():
            if kind == 2 or changed & bit:
                base[field] = row[CANDIDATE_COLUMNS[field]]
        base.update(
            {
                "window_start": row["window_start"],
                "window_end": row["window_end"],
                "stock_id": row["stock_id"],
                "trade_date": row["trade_date"],
                "phase": row["phase"],
            }
        )
        events[key] = base
    connection.close()
    return events


def first_divergences(path: Path) -> list[dict]:
    connection = sqlite3.connect(path)
    connection.row_factory = sqlite3.Row
    rows = [dict(row) for row in connection.execute("SELECT * FROM first_divergences ORDER BY window_start,stock_id")]
    connection.close()
    return rows


def outcomes(path: Path) -> dict[tuple, dict]:
    connection = sqlite3.connect(path)
    connection.row_factory = sqlite3.Row
    values = {
        (row["window_start"], row["window_end"], row["stock_id"]): dict(row)
        for row in connection.execute("SELECT * FROM period_outcome_deltas")
    }
    connection.close()
    return values


def score(roi: float | None, days: float | None) -> float | None:
    if roi is None or days is None or days <= 0:
        return None
    return roi * 100.0 / days if roi >= 0 else roi * days / 100.0


def delta_score(row: dict) -> float:
    baseline = score(row["baseline_roi"], row["baseline_average_days"])
    candidate = score(row["candidate_roi"], row["candidate_average_days"])
    if baseline is None or candidate is None:
        raise RuntimeError("unexpected scoreless E-LC05 outcome")
    return candidate - baseline


def sign(value: float, epsilon: float = 1e-9) -> str:
    if value > epsilon:
        return "positive"
    if value < -epsilon:
        return "negative"
    return "zero"


def write_csv(path: Path, rows: list[dict]) -> None:
    if not rows:
        return
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def summarize_group(rows: list[dict], result_key: str) -> dict:
    return {
        "cases": len(rows),
        "positive": sum(sign(row[result_key]) == "positive" for row in rows),
        "negative": sum(sign(row[result_key]) == "negative" for row in rows),
        "zero": sum(sign(row[result_key]) == "zero" for row in rows),
        "meanDelta": sum(row[result_key] for row in rows) / len(rows),
        "stocks": len({row["stock_id"] for row in rows}),
        "windows": len({row["window_start"] for row in rows}),
    }


def main() -> None:
    args = arguments()
    args.output.mkdir(parents=True, exist_ok=True)
    manifest = read_json(args.baseline_manifest)
    s1_summary = read_json(args.s1_summary)
    s2_summary = read_json(args.s2_summary)
    s1_run = read_json(args.s1_run_manifest)
    s2_run = read_json(args.s2_run_manifest)

    identity = {
        "baselineComplete": args.baseline_manifest.parent.joinpath(".complete").read_text(encoding="utf-8").strip(),
        "baselineDecisionBaseID": manifest["decisionBaseID"],
        "s1CandidateID": s1_summary["candidateID"],
        "s1RunID": s1_run["runID"],
        "s2CandidateID": s2_summary["candidateID"],
        "s2RunID": s2_run["runID"],
    }
    for prefix, summary_path, run_path, summary, run in (
        ("s1", args.s1_summary, args.s1_run_manifest, s1_summary, s1_run),
        ("s2", args.s2_summary, args.s2_run_manifest, s2_summary, s2_run),
    ):
        delta_dir = summary_path.parent
        run_dir = run_path.parent
        identity[f"{prefix}DeltaComplete"] = delta_dir.joinpath(".complete").read_text(encoding="utf-8").strip()
        identity[f"{prefix}AnalysisComplete"] = delta_dir.joinpath(".analysis-complete").read_text(encoding="utf-8").strip()
        identity[f"{prefix}RunComplete"] = run_dir.joinpath(".complete").read_text(encoding="utf-8").strip()
        if identity[f"{prefix}DeltaComplete"] != summary["candidateID"]:
            raise RuntimeError(f"{prefix} delta completion mismatch")
        if identity[f"{prefix}AnalysisComplete"] != summary["candidateID"]:
            raise RuntimeError(f"{prefix} analysis completion mismatch")
        if identity[f"{prefix}RunComplete"] != run["runID"]:
            raise RuntimeError(f"{prefix} run completion mismatch")
        if summary["candidateRunID"] != run["runID"]:
            raise RuntimeError(f"{prefix} candidate run identity mismatch")
    if identity["baselineComplete"] != manifest["decisionBaseID"]:
        raise RuntimeError("baseline completion mismatch")

    baseline, stocks, date_lists = load_baseline(args.baseline_db)
    candidate = candidate_events(baseline, args.s2_delta_db)
    s1_first = first_divergences(args.s1_delta_db)
    s2_first = first_divergences(args.s2_delta_db)
    first_keys = [(row["window_start"], row["window_end"], row["stock_id"], row["trade_date"]) for row in s2_first]
    if first_keys != [(row["window_start"], row["window_end"], row["stock_id"], row["trade_date"]) for row in s1_first]:
        raise RuntimeError("S1 and S2 first-divergence identities differ")
    if any(not row["same_prestate"] for row in s1_first + s2_first):
        raise RuntimeError("prestate mismatch in E-LC05 evidence")

    s1_outcomes = outcomes(args.s1_delta_db)
    s2_outcomes = outcomes(args.s2_delta_db)
    case_rows: list[dict] = []
    signal_rows: list[dict] = []
    for divergence in s2_first:
        window_key = (divergence["window_start"], divergence["window_end"], divergence["stock_id"])
        relevant = [
            event for key, event in candidate.items()
            if key[:3] == window_key
            and event["trade_date"] >= divergence["trade_date"]
            and event["phase"] in (1, 2)
            and event["inventory"] == 0
            and event["threshold"] is not None
            and event["score"] >= event["threshold"]
        ]
        relevant.sort(key=lambda event: (event["trade_date"], event["phase"]))
        if len(relevant) < 6 or relevant[5]["executed"] != "BUY":
            raise RuntimeError(f"expected five skipped signals followed by BUY for {window_key}")
        first_five = relevant[:5]
        date_index = {value: index for index, value in enumerate(date_lists[window_key])}
        for ordinal, event in enumerate(first_five, 1):
            grade_event = candidate[event_key(*window_key, event["trade_date"], 0)]
            signal_rows.append(
                {
                    "window_start": window_key[0], "window_end": window_key[1],
                    "stock_id": window_key[2], "stock_name": stocks[window_key[2]]["name"],
                    "ordinal": ordinal, "trade_date": event["trade_date"],
                    "trading_day_offset": date_index[event["trade_date"]] - date_index[first_five[0]["trade_date"]],
                    "side": "H" if event["phase"] == 1 else "L", "grade": event["grade"],
                    "decision_score": event["score"], "decision_threshold": event["threshold"],
                    "decision_margin": event["score"] - event["threshold"],
                    "grade_efficiency_score": grade_event["score"],
                }
            )
        per_case = signal_rows[-5:]
        s1_delta = delta_score(s1_outcomes[window_key])
        s2_delta = delta_score(s2_outcomes[window_key])
        grade_first = per_case[0]["grade_efficiency_score"]
        grade_fifth = per_case[-1]["grade_efficiency_score"]
        margin_first = per_case[0]["decision_margin"]
        margin_fifth = per_case[-1]["decision_margin"]
        sides = "".join(row["side"] for row in per_case)
        grade_band = "<=-10" if grade_fifth <= -10 else ("(-10,0]" if grade_fifth <= 0 else ">0")
        case_rows.append(
            {
                "window_start": window_key[0], "window_end": window_key[1],
                "stock_id": window_key[2], "stock_name": stocks[window_key[2]]["name"],
                "group": stocks[window_key[2]]["group"], "signal_pattern": sides,
                "all_first5_h": sides == "HHHHH", "contains_l": "L" in sides,
                "signal_span_trading_days": per_case[-1]["trading_day_offset"],
                "margin_first": margin_first, "margin_fifth": margin_fifth,
                "margin_change": margin_fifth - margin_first,
                "margin_increased": margin_fifth > margin_first,
                "grade_score_first": grade_first, "grade_score_fifth": grade_fifth,
                "grade_score_change": grade_fifth - grade_first,
                "grade_score_increased": grade_fifth > grade_first + 1e-9,
                "crossed_minus10": grade_first <= -10 < grade_fifth,
                "crossed_zero": grade_first <= 0 < grade_fifth,
                "grade_score_fifth_band": grade_band,
                "s1_score_delta": s1_delta, "s1_direction": sign(s1_delta),
                "s2_score_delta": s2_delta, "s2_direction": sign(s2_delta),
                "s2_vs_s1_score_delta": s2_delta - s1_delta,
                "s2_vs_s1_direction": sign(s2_delta - s1_delta),
            }
        )

    partitions: list[dict] = []
    for feature in ("all_first5_h", "margin_increased", "grade_score_increased", "crossed_minus10", "crossed_zero", "grade_score_fifth_band"):
        for value in sorted({str(row[feature]) for row in case_rows}):
            members = [row for row in case_rows if str(row[feature]) == value]
            for result in ("s1_score_delta", "s2_score_delta", "s2_vs_s1_score_delta"):
                partitions.append({"feature": feature, "value": value, "result": result} | summarize_group(members, result))

    valid_boundaries: list[dict] = []
    for feature in ("all_first5_h", "margin_increased", "grade_score_increased", "crossed_minus10", "crossed_zero"):
        values = sorted({str(row[feature]) for row in case_rows})
        if len(values) != 2:
            continue
        for result in ("s1_score_delta", "s2_score_delta", "s2_vs_s1_score_delta"):
            groups = [[row for row in case_rows if str(row[feature]) == value] for value in values]
            summaries = [summarize_group(group, result) for group in groups]
            pure = all(summary["positive"] == 0 or summary["negative"] == 0 for summary in summaries)
            opposite = summaries[0]["positive"] > 0 and summaries[1]["negative"] > 0 or summaries[0]["negative"] > 0 and summaries[1]["positive"] > 0
            repeated = all(summary["cases"] >= 2 and summary["stocks"] >= 2 for summary in summaries)
            cross_window = max(summary["windows"] for summary in summaries) >= 2
            if pure and opposite and repeated and cross_window:
                valid_boundaries.append({"feature": feature, "result": result, "values": values, "summaries": summaries})

    write_csv(args.output / "signals.csv", signal_rows)
    write_csv(args.output / "cases.csv", case_rows)
    write_csv(args.output / "partitions.csv", partitions)
    summary = {
        "studyID": "E-LC06-D0-E",
        "identity": identity,
        "sampleID": manifest["sampleID"],
        "dataRuleVersion": manifest["dataRuleVersion"],
        "ruleVersion": manifest["ruleVersion"],
        "ruleCommit": manifest["ruleCommit"],
        "caseCount": len(case_rows),
        "stockCount": len({row["stock_id"] for row in case_rows}),
        "windowCount": len({row["window_start"] for row in case_rows}),
        "s1Directions": summarize_group(case_rows, "s1_score_delta"),
        "s2Directions": summarize_group(case_rows, "s2_score_delta"),
        "s2VersusS1Directions": summarize_group(case_rows, "s2_vs_s1_score_delta"),
        "validExplainableBoundaries": valid_boundaries,
    }
    (args.output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    lines = [
        "# E-LC06-D0-E 第 1～5 個進場訊號診斷", "",
        f"- DecisionBase：`{manifest['decisionBaseID']}`，Sample `{manifest['sampleID']}`，策略 `{manifest['ruleVersion']}`，資料 `{manifest['dataRuleVersion']}`。",
        f"- 案例：{len(case_rows)} 個差異股票窗口，{summary['stockCount']} 檔、{summary['windowCount']} 個窗口；S1／S2 首次分歧集合完全相同且前態一致。",
        "- 訊號：以 S2 候選空手時 H買／L買分數實際跨過正式門檻為準；前 5 次均被跳過，第 6 次恢復 BUY。", "",
        "## 結果", "",
        f"- S1：正向 {summary['s1Directions']['positive']}、反向 {summary['s1Directions']['negative']}；S2：正向 {summary['s2Directions']['positive']}、反向 {summary['s2Directions']['negative']}。",
        f"- S2 相對 S1：改善 {summary['s2VersusS1Directions']['positive']}、退步 {summary['s2VersusS1Directions']['negative']}。",
        "- 有限檢查 H/L 組成、買入門檻餘裕是否增加、Grade 連續效率分數是否增加或跨過 -10／0，以及第 5 次分數所在既有區段。",
        f"- 通過跨股票、正反純分離條件的可解釋分界：{len(valid_boundaries)}。", "",
        "## 邊界", "",
        "- 不生成任意分數門檻、不做網格搜尋；單一股票或單一窗口的漂亮切點不視為方向。",
        "- 個案期末分數由各候選 period outcome 的 ROI／平均週期依正式公式計算，不以 ROI 單獨代替。",
    ]
    (args.output / "report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
