#!/usr/bin/env python3
"""Diagnose Baseline sell decisions that were exactly one vote short."""

from __future__ import annotations

import argparse
import bisect
import csv
import json
import math
import sqlite3
from collections import defaultdict
from datetime import datetime
from pathlib import Path
from statistics import mean, median
from typing import Any, Iterable
from zoneinfo import ZoneInfo

from grade_trend_price_study import PriceRow, apple_date, load_prices


TAIPEI = ZoneInfo("Asia/Taipei")
HORIZONS = (20, 60)
GRADE_NAMES = {3: "wow", 2: "high", 1: "fine", 0: "none", -1: "weak", -2: "low", -3: "damn"}
FIT_PHASE_NAMES = {
    0: "初始",
    1: "穩定",
    2: "改善預警",
    3: "惡化預警",
    4: "改善確認",
    5: "惡化確認",
    6: "改善退回",
    7: "惡化退回",
}
DEFAULT_BASE_ID = "{sample}-abcd9-v2-s24-sn05-wow-worsening-20260824-t2-s28-73003cf8f39c-fixed3y-20260722-v5"


def open_readonly(path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
    if integrity != "ok":
        connection.close()
        raise RuntimeError(f"SQLite integrity failed: {path}: {integrity}")
    return connection


def close_enough(value: float, target: float) -> bool:
    return math.isclose(value, target, abs_tol=1e-9)


def roi_threshold_for_st01c(grade: int) -> float:
    if grade <= -1:
        return 1.5
    if grade >= 3:
        return 2.25
    return 2.0


def one_vote_short_gates(row: dict[str, Any]) -> list[str]:
    """Mirror only formal sell gates fully reconstructable from DecisionBase v5."""
    score = float(row["decision_score"])
    roi = float(row["unit_roi_before"])
    days = float(row["holding_days_before"])
    grade = int(row["grade"])
    upper = grade >= 2
    gates: list[str] = []

    st01a_score = 0.0 if upper else 1.0
    if roi > 22.5 and close_enough(score, st01a_score):
        gates.append("S-T01a")
    if roi > 0.45 and days > 1 and close_enough(score, 5.0):
        gates.append("S-T01b")
    if roi > roi_threshold_for_st01c(grade) and close_enough(score, 3.0):
        gates.append("S-T01c")
    if roi > 0.45 and days > 68 and close_enough(score, 3.0):
        gates.append("S-T01e")
    if roi > 15.5 and days < (60 if upper else 40) and close_enough(score, 2.0):
        gates.append("S-T01f")
    if roi > 9.5 and days < (30 if upper else 20) and close_enough(score, 2.0):
        gates.append("S-T01g")
    if roi > 6.5 and days < (10 if grade > -1 else 45) and close_enough(score, 2.0):
        gates.append("S-T01h")
    range_is_narrow = float(row["range_125"]) < 30
    st02b = days > 240 and range_is_narrow and (
        (grade > -1 and roi > -15) or ((days > 300 or grade <= -1) and roi > -20)
    )
    st02c = days > 400 and roi > (-20 if grade <= -1 else -15)
    st02_threshold = 1.0 if grade >= 0 and days < 400 else 2.0
    if bool(row["no_recent_investment"]) and close_enough(score, st02_threshold - 1):
        if st02b:
            gates.append("S-T02b")
        if st02c:
            gates.append("S-T02c")
    return gates


def holding_bucket(days: float) -> str:
    if days < 20:
        return "<20日"
    if days < 68:
        return "20-67日"
    if days < 240:
        return "68-239日"
    if days < 400:
        return "240-399日"
    return ">=400日"


def roi_bucket(roi: float) -> str:
    if roi < 0:
        return "<0%"
    if roi < 2.25:
        return "0-2.25%"
    if roi < 6.5:
        return "2.25-6.5%"
    if roi < 15.5:
        return "6.5-15.5%"
    return ">=15.5%"


def invest_bucket(value: float) -> str:
    if value <= 1:
        return "<=1次"
    if value <= 2:
        return "2次"
    return ">=3次"


def load_sell_rows(path: Path, sample: str) -> tuple[list[dict[str, Any]], dict[str, str]]:
    connection = open_readonly(path)
    try:
        metadata = {row["key"]: row["value"] for row in connection.execute("SELECT key,value FROM metadata")}
        query = """
            SELECT e.event_id,e.window_id,w.start_date,w.end_date,
                   s.stock_id,s.name stock_name,s.group_name,e.trade_date,
                   e.grade,e.decision_score,e.planned_action,e.executed_action,
                   e.inventory_before,e.unit_cost_before,e.unit_roi_before,
                   e.holding_days_before,e.invest_times_before,e.balance_before,
                   e.roll_roi_before,e.roll_days_before,e.roll_rounds_before,
                   e.buy_rule_before,COALESCE(f.fit_trend_phase,0) fit_trend_phase
            FROM decision_events e
            JOIN windows w USING(window_id)
            JOIN stocks s USING(stock_key)
            LEFT JOIN event_strategy_fit_observations x USING(event_id)
            LEFT JOIN strategy_fit_observations f USING(observation_id)
            WHERE e.phase=3 AND e.inventory_before>0
            ORDER BY e.window_id,s.stock_id,e.trade_date
        """
        rows = [dict(row) | {"sample": sample} for row in connection.execute(query)]
        return rows, metadata
    finally:
        connection.close()


def load_add_dates(path: Path) -> dict[tuple[int, str], list[int]]:
    connection = open_readonly(path)
    try:
        query = """
            SELECT e.window_id,s.stock_id,e.trade_date
            FROM decision_events e JOIN stocks s USING(stock_key)
            WHERE e.phase=4 AND e.executed_action='ADD'
            ORDER BY e.window_id,s.stock_id,e.trade_date
        """
        result: dict[tuple[int, str], list[int]] = defaultdict(list)
        for row in connection.execute(query):
            result[(int(row["window_id"]), str(row["stock_id"]))].append(int(row["trade_date"]))
        return result
    finally:
        connection.close()


def load_range_context(path: Path) -> dict[tuple[str, int], float]:
    connection = open_readonly(path)
    try:
        query = """
            SELECT s.ZSID stock_id,t.ZDATETIME trade_time,
                   t.ZTLOWDIFF125 low_diff_125,t.ZTHIGHDIFF125 high_diff_125
            FROM ZTRADE t JOIN ZSTOCK s ON s.Z_PK=t.ZSTOCK
            ORDER BY s.ZSID,t.ZDATETIME
        """
        result: dict[tuple[str, int], float] = {}
        for row in connection.execute(query):
            key = (str(row["stock_id"]), apple_date(row["trade_time"]))
            result[key] = float(row["low_diff_125"] or 0) - float(row["high_diff_125"] or 0)
        return result
    finally:
        connection.close()


def attach_reconstruction_context(
    rows: list[dict[str, Any]],
    decision_path: Path,
    price_path: Path,
    prices: dict[str, list[PriceRow]],
) -> None:
    indexes = price_indexes(prices)
    ranges = load_range_context(price_path)
    add_dates = load_add_dates(decision_path)
    for row in rows:
        stock_id = str(row["stock_id"])
        trade_date = int(row["trade_date"])
        row["range_125"] = ranges[(stock_id, trade_date)]
        dates = add_dates[(int(row["window_id"]), stock_id)]
        position = bisect.bisect_left(dates, trade_date) - 1
        recent = False
        if position >= 0:
            add_date = dates[position]
            current_index = indexes[stock_id][trade_date]
            add_index = indexes[stock_id].get(add_date)
            recent = add_index is not None and 0 < current_index - add_index <= 60
        row["no_recent_investment"] = int(not recent)


def price_indexes(prices: dict[str, list[PriceRow]]) -> dict[str, dict[int, int]]:
    return {
        stock_id: {item.trade_date: index for index, item in enumerate(series)}
        for stock_id, series in prices.items()
    }


def select_first_near_miss_per_round(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    selected: list[dict[str, Any]] = []
    grouped: dict[tuple[int, str], list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        grouped[(int(row["window_id"]), str(row["stock_id"]))].append(row)

    for key, series in grouped.items():
        round_id = 0
        selected_rounds: set[int] = set()
        for row in series:
            planned = str(row["planned_action"]).upper()
            executed = str(row["executed_action"]).upper()
            gates = one_vote_short_gates(row)
            if round_id not in selected_rounds and planned == "HOLD" and executed == "NONE" and gates:
                value = dict(row)
                value["round_id"] = round_id
                value["candidate_gates"] = "+".join(gates)
                value["grade_name"] = GRADE_NAMES.get(int(row["grade"]), "unknown")
                value["fit_phase_name"] = FIT_PHASE_NAMES.get(int(row["fit_trend_phase"]), "unknown")
                value["holding_bucket"] = holding_bucket(float(row["holding_days_before"]))
                value["roi_bucket"] = roi_bucket(float(row["unit_roi_before"]))
                value["invest_bucket"] = invest_bucket(float(row["invest_times_before"]))
                selected.append(value)
                selected_rounds.add(round_id)
            if executed == "SELL":
                round_id += 1
    return selected


def decorate_forward_outcomes(
    events: list[dict[str, Any]],
    all_sell_rows: list[dict[str, Any]],
    prices: dict[str, list[PriceRow]],
) -> None:
    indexes = price_indexes(prices)
    actual_exits: dict[tuple[int, str], list[int]] = defaultdict(list)
    for row in all_sell_rows:
        if str(row["executed_action"]).upper() == "SELL":
            actual_exits[(int(row["window_id"]), str(row["stock_id"]))].append(int(row["trade_date"]))

    for event in events:
        stock_id = str(event["stock_id"])
        series = prices[stock_id]
        index = indexes[stock_id].get(int(event["trade_date"]))
        if index is None:
            raise RuntimeError(f"Missing price for {event['sample']} {stock_id} {event['trade_date']}")
        start_price = series[index].close
        event["close_price"] = start_price
        future_exits = actual_exits[(int(event["window_id"]), stock_id)]
        exit_position = bisect.bisect_right(future_exits, int(event["trade_date"]))
        exit_date = future_exits[exit_position] if exit_position < len(future_exits) else None
        event["actual_exit_date"] = exit_date
        event["days_to_actual_exit"] = None
        event["return_to_actual_exit"] = None
        event["minimum_return_to_actual_exit"] = None
        if exit_date is not None and exit_date in indexes[stock_id]:
            exit_index = indexes[stock_id][exit_date]
            event["days_to_actual_exit"] = exit_index - index
            exit_path = series[index + 1 : exit_index + 1]
            exit_returns = [100 * (item.close / start_price - 1) for item in exit_path]
            if exit_returns:
                event["return_to_actual_exit"] = exit_returns[-1]
                event["minimum_return_to_actual_exit"] = min(exit_returns)

        for horizon in HORIZONS:
            end_index = index + horizon
            prefix = f"h{horizon}"
            if end_index >= len(series) or series[end_index].trade_date > int(event["end_date"]):
                for name in ("return", "minimum_return", "maximum_return", "actual_exit", "no_exit", "unrecovered_cost", "capital_locked"):
                    event[f"{prefix}_{name}"] = None
                continue
            path = series[index + 1 : end_index + 1]
            returns = [100 * (item.close / start_price - 1) for item in path]
            days_to_exit = event["days_to_actual_exit"]
            actual_exit = days_to_exit is not None and 0 < days_to_exit <= horizon
            unrecovered = max(item.close for item in path) < float(event["unit_cost_before"])
            event[f"{prefix}_return"] = returns[-1]
            event[f"{prefix}_minimum_return"] = min(returns)
            event[f"{prefix}_maximum_return"] = max(returns)
            event[f"{prefix}_actual_exit"] = int(actual_exit)
            event[f"{prefix}_no_exit"] = int(not actual_exit)
            event[f"{prefix}_unrecovered_cost"] = int(unrecovered)
            event[f"{prefix}_capital_locked"] = int(not actual_exit and unrecovered)


def numeric(values: Iterable[Any]) -> list[float]:
    return [float(value) for value in values if value is not None and value != ""]


def metrics(rows: list[dict[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {
        "events": len(rows),
        "stocks": len({(row["sample"], row["stock_id"]) for row in rows}),
        "windows": len({(row["sample"], row["window_id"]) for row in rows}),
    }
    exit_returns = numeric(row.get("return_to_actual_exit") for row in rows)
    exit_days = numeric(row.get("days_to_actual_exit") for row in rows)
    result["actual_exit_events"] = len(exit_returns)
    result["mean_return_to_actual_exit"] = mean(exit_returns) if exit_returns else None
    result["median_return_to_actual_exit"] = median(exit_returns) if exit_returns else None
    result["earlier_sale_better_rate"] = (
        100 * sum(value < 0 for value in exit_returns) / len(exit_returns) if exit_returns else None
    )
    result["mean_days_to_actual_exit"] = mean(exit_days) if exit_days else None
    for horizon in HORIZONS:
        returns = numeric(row.get(f"h{horizon}_return") for row in rows)
        minimums = numeric(row.get(f"h{horizon}_minimum_return") for row in rows)
        valid_rows = [row for row in rows if row.get(f"h{horizon}_return") is not None]
        result[f"valid_h{horizon}"] = len(returns)
        result[f"mean_return_h{horizon}"] = mean(returns) if returns else None
        result[f"median_return_h{horizon}"] = median(returns) if returns else None
        result[f"fall_rate_h{horizon}"] = 100 * sum(value < 0 for value in returns) / len(returns) if returns else None
        result[f"mean_minimum_h{horizon}"] = mean(minimums) if minimums else None
        result[f"no_exit_rate_h{horizon}"] = (
            100 * sum(int(row[f"h{horizon}_no_exit"]) for row in valid_rows) / len(valid_rows)
            if valid_rows else None
        )
        result[f"capital_locked_rate_h{horizon}"] = (
            100 * sum(int(row[f"h{horizon}_capital_locked"]) for row in valid_rows) / len(valid_rows)
            if valid_rows else None
        )
    return result


def condition_groups(rows: list[dict[str, Any]]) -> dict[tuple[str, str], list[dict[str, Any]]]:
    groups: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        groups[("全部", "全部")].append(row)
        groups[("Grade", str(row["grade_name"]))].append(row)
        groups[("持股期", str(row["holding_bucket"]))].append(row)
        groups[("買入次數", str(row["invest_bucket"]))].append(row)
        groups[("事件ROI", str(row["roi_bucket"]))].append(row)
        groups[("趨勢階段", str(row["fit_phase_name"]))].append(row)
        for gate in str(row["candidate_gates"]).split("+"):
            groups[("Gate", gate)].append(row)
            groups[("Gate×Grade", f"{gate}×{row['grade_name']}")].append(row)
    return groups


def summary_rows(events: list[dict[str, Any]], samples: list[str]) -> list[dict[str, Any]]:
    output: list[dict[str, Any]] = []
    for scope in (*samples, "全部"):
        scoped = events if scope == "全部" else [row for row in events if row["sample"] == scope]
        for (dimension, condition), rows in sorted(condition_groups(scoped).items()):
            output.append({"scope": scope, "dimension": dimension, "condition": condition} | metrics(rows))
    return output


def cross_sample_rows(summary: list[dict[str, Any]], samples: list[str]) -> list[dict[str, Any]]:
    first, second = samples
    lookup = {(row["scope"], row["dimension"], row["condition"]): row for row in summary}
    output: list[dict[str, Any]] = []
    conditions = sorted({(row["dimension"], row["condition"]) for row in summary if row["scope"] == "全部"})
    for dimension, condition in conditions:
        a = lookup.get((first, dimension, condition))
        b = lookup.get((second, dimension, condition))
        combined = lookup[("全部", dimension, condition)]
        if not a or not b:
            continue
        broad = a["events"] >= 3 and b["events"] >= 3 and combined["stocks"] >= 4 and combined["windows"] >= 4
        same_negative = (
            a["mean_return_h60"] is not None and b["mean_return_h60"] is not None
            and a["mean_return_h60"] < 0 and b["mean_return_h60"] < 0
        )
        output.append({
            "sample_1": first,
            "sample_2": second,
            "dimension": dimension,
            "condition": condition,
            "a_events": a["events"],
            "b_events": b["events"],
            "stocks": combined["stocks"],
            "windows": combined["windows"],
            "a_mean_return_h60": a["mean_return_h60"],
            "b_mean_return_h60": b["mean_return_h60"],
            "combined_mean_return_h60": combined["mean_return_h60"],
            "a_fall_rate_h60": a["fall_rate_h60"],
            "b_fall_rate_h60": b["fall_rate_h60"],
            "capital_locked_rate_h60": combined["capital_locked_rate_h60"],
            "broad_enough": int(broad),
            "same_negative_direction": int(same_negative),
            "diagnostic_shortlist": int(broad and same_negative),
        })
    return sorted(output, key=lambda row: (-row["diagnostic_shortlist"], row["combined_mean_return_h60"] or 999, row["dimension"], row["condition"]))


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    with path.open("w", newline="", encoding="utf-8-sig") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("exports/near-threshold-sell-study/nr0-baseline-v10-t2s28-20260825"))
    parser.add_argument("--price-root", type=Path, default=Path("/tmp/gt-p01-input"))
    parser.add_argument("--decision-root", type=Path, default=Path("exports/backtest-decision-bases"))
    parser.add_argument("--samples", nargs=2, default=["A", "B"])
    args = parser.parse_args()
    samples = [value.upper() for value in args.samples]

    all_events: list[dict[str, Any]] = []
    sources: dict[str, Any] = {}
    for sample in samples:
        base_id = DEFAULT_BASE_ID.format(sample=sample.lower())
        decision_path = args.decision_root / base_id / "decisions.sqlite"
        price_path = args.price_root / f"{sample.lower()}.store"
        if not decision_path.exists() or not price_path.exists():
            raise FileNotFoundError(f"Missing NR0 input: {decision_path} or {price_path}")
        rows, metadata = load_sell_rows(decision_path, sample)
        prices, _ = load_prices(price_path)
        attach_reconstruction_context(rows, decision_path, price_path, prices)
        selected = select_first_near_miss_per_round(rows)
        decorate_forward_outcomes(selected, rows, prices)
        all_events.extend(selected)
        sources[sample] = {
            "decisionBase": str(decision_path),
            "priceStore": str(price_path),
            "sellEvents": len(rows),
            "selectedNearMissEvents": len(selected),
            "metadata": metadata,
        }

    summaries = summary_rows(all_events, samples)
    cross_sample = cross_sample_rows(summaries, samples)
    args.output.mkdir(parents=True, exist_ok=True)
    write_csv(args.output / "events.csv", all_events)
    write_csv(args.output / "condition-summary.csv", summaries)
    write_csv(args.output / "cross-sample-screen.csv", cross_sample)
    manifest = {
        "runID": args.output.name,
        "createdAt": datetime.now(TAIPEI).isoformat(),
        "baseline": "v10",
        "dataRuleVersion": "T2/S28",
        "strategyRuleVersion": "S24",
        "ruleCommit": "73003cf8f39cbf3a673792957324f508261bd731",
        "samples": samples,
        "horizons": list(HORIZONS),
        "selectedEventCount": len(all_events),
        "reconstructableGates": [
            "S-T01a", "S-T01b", "S-T01c", "S-T01e", "S-T01f", "S-T01g", "S-T01h",
            "S-T02b", "S-T02c",
        ],
        "excludedGates": {
            "S-T01d": "SELL events do not retain the required K/D observation for every date",
        },
        "deduplication": "first exactly-one-vote-short event in each baseline holding round",
        "sources": sources,
        "limitations": [
            "This is observational diagnosis of the formal baseline path, not a counterfactual replay.",
            "Future returns start after the near-miss event close.",
            "A shortlist is only a hypothesis; any rule must be replayed as one controlled candidate.",
        ],
        "files": ["manifest.json", "events.csv", "condition-summary.csv", "cross-sample-screen.csv"],
    }
    (args.output / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({
        "output": str(args.output),
        "events": len(all_events),
        "shortlist": sum(int(row["diagnostic_shortlist"]) for row in cross_sample),
    }, ensure_ascii=False))


if __name__ == "__main__":
    main()
