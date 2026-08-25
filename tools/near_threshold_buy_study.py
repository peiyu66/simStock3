#!/usr/bin/env python3
"""Diagnose Baseline buy decisions that were exactly one vote short."""

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

from grade_trend_price_study import PriceRow, load_prices


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


def load_buy_rows(path: Path, sample: str) -> tuple[list[dict[str, Any]], dict[str, str]]:
    connection = open_readonly(path)
    try:
        metadata = {row["key"]: row["value"] for row in connection.execute("SELECT key,value FROM metadata")}
        query = """
            SELECT e.event_id,e.window_id,w.start_date,w.end_date,
                   s.stock_id,s.name stock_name,s.group_name,e.trade_date,e.phase,
                   e.grade,e.decision_score,e.decision_threshold,
                   e.planned_action,e.executed_action,e.inventory_before,
                   e.balance_before,e.roll_roi_before,e.roll_days_before,
                   e.roll_rounds_before,e.buy_rule_before,
                   COALESCE(f.fit_trend_phase,0) fit_trend_phase
            FROM decision_events e
            JOIN windows w USING(window_id)
            JOIN stocks s USING(stock_key)
            LEFT JOIN event_strategy_fit_observations x USING(event_id)
            LEFT JOIN strategy_fit_observations f USING(observation_id)
            WHERE e.phase IN (1,2) AND e.inventory_before=0
            ORDER BY e.window_id,s.stock_id,e.trade_date,e.phase
        """
        return [dict(row) | {"sample": sample} for row in connection.execute(query)], metadata
    finally:
        connection.close()


def candidate_gate(row: dict[str, Any]) -> str | None:
    if str(row["planned_action"]).upper() != "NONE" or str(row["executed_action"]).upper() != "NONE":
        return None
    threshold = row["decision_threshold"]
    if threshold is None or not close_enough(float(row["decision_score"]), float(threshold) - 1):
        return None
    return {1: "H-T01", 2: "L-T01"}.get(int(row["phase"]))


def roll_round_bucket(value: float) -> str:
    if value <= 0:
        return "0輪"
    if value <= 2:
        return "1-2輪"
    if value <= 5:
        return "3-5輪"
    return ">=6輪"


def roll_roi_bucket(value: float) -> str:
    if value < 0:
        return "<0%"
    if value < 10:
        return "0-10%"
    if value < 30:
        return "10-30%"
    return ">=30%"


def select_first_near_miss_per_flat_period(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    selected: list[dict[str, Any]] = []
    grouped: dict[tuple[int, str], list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        grouped[(int(row["window_id"]), str(row["stock_id"]))].append(row)

    for series in grouped.values():
        by_date: dict[int, list[dict[str, Any]]] = defaultdict(list)
        for row in series:
            by_date[int(row["trade_date"])].append(row)
        flat_period = 0
        selected_periods: set[int] = set()
        for trade_date in sorted(by_date):
            daily = by_date[trade_date]
            if any(str(row["executed_action"]).upper() == "BUY" for row in daily):
                flat_period += 1
                continue
            gates = [(candidate_gate(row), row) for row in daily]
            gates = [(gate, row) for gate, row in gates if gate is not None]
            if flat_period in selected_periods or not gates:
                continue
            source = min((row for _, row in gates), key=lambda row: int(row["phase"]))
            value = dict(source)
            value["flat_period"] = flat_period
            value["candidate_gates"] = "+".join(gate for gate, _ in gates)
            value["gate_scores"] = "+".join(
                f"{gate}:{float(row['decision_score']):g}/{float(row['decision_threshold']):g}"
                for gate, row in gates
            )
            value["grade_name"] = GRADE_NAMES.get(int(source["grade"]), "unknown")
            value["fit_phase_name"] = FIT_PHASE_NAMES.get(int(source["fit_trend_phase"]), "unknown")
            value["roll_round_bucket"] = roll_round_bucket(float(source["roll_rounds_before"]))
            value["roll_roi_bucket"] = roll_roi_bucket(float(source["roll_roi_before"]))
            selected.append(value)
            selected_periods.add(flat_period)
    return selected


def price_indexes(prices: dict[str, list[PriceRow]]) -> dict[str, dict[int, int]]:
    return {
        stock_id: {item.trade_date: index for index, item in enumerate(series)}
        for stock_id, series in prices.items()
    }


def decorate_forward_outcomes(
    events: list[dict[str, Any]],
    all_buy_rows: list[dict[str, Any]],
    prices: dict[str, list[PriceRow]],
) -> None:
    indexes = price_indexes(prices)
    actual_buys: dict[tuple[int, str], list[tuple[int, str]]] = defaultdict(list)
    for row in all_buy_rows:
        if str(row["executed_action"]).upper() == "BUY":
            actual_buys[(int(row["window_id"]), str(row["stock_id"]))].append(
                (int(row["trade_date"]), str(row["planned_action"]).upper())
            )

    for event in events:
        stock_id = str(event["stock_id"])
        series = prices[stock_id]
        index = indexes[stock_id].get(int(event["trade_date"]))
        if index is None:
            raise RuntimeError(f"Missing price for {event['sample']} {stock_id} {event['trade_date']}")
        start_price = series[index].close
        event["close_price"] = start_price
        buys = actual_buys[(int(event["window_id"]), stock_id)]
        buy_dates = [item[0] for item in buys]
        position = bisect.bisect_right(buy_dates, int(event["trade_date"]))
        actual_buy = buys[position] if position < len(buys) else None
        event["actual_buy_date"] = actual_buy[0] if actual_buy else None
        event["actual_buy_rule"] = actual_buy[1] if actual_buy else None
        event["days_to_actual_buy"] = None
        event["return_to_actual_buy"] = None
        event["minimum_return_to_actual_buy"] = None
        event["maximum_return_to_actual_buy"] = None
        if actual_buy and actual_buy[0] in indexes[stock_id]:
            buy_index = indexes[stock_id][actual_buy[0]]
            event["days_to_actual_buy"] = buy_index - index
            path = series[index + 1 : buy_index + 1]
            returns = [100 * (item.close / start_price - 1) for item in path]
            if returns:
                event["return_to_actual_buy"] = returns[-1]
                event["minimum_return_to_actual_buy"] = min(returns)
                event["maximum_return_to_actual_buy"] = max(returns)

        for horizon in HORIZONS:
            end_index = index + horizon
            prefix = f"h{horizon}"
            if end_index >= len(series) or series[end_index].trade_date > int(event["end_date"]):
                for name in ("return", "minimum_return", "maximum_return", "actual_buy", "no_buy", "missed_rise"):
                    event[f"{prefix}_{name}"] = None
                continue
            path = series[index + 1 : end_index + 1]
            returns = [100 * (item.close / start_price - 1) for item in path]
            days_to_buy = event["days_to_actual_buy"]
            bought = days_to_buy is not None and 0 < days_to_buy <= horizon
            event[f"{prefix}_return"] = returns[-1]
            event[f"{prefix}_minimum_return"] = min(returns)
            event[f"{prefix}_maximum_return"] = max(returns)
            event[f"{prefix}_actual_buy"] = int(bought)
            event[f"{prefix}_no_buy"] = int(not bought)
            event[f"{prefix}_missed_rise"] = int(not bought and returns[-1] > 0)


def numeric(values: Iterable[Any]) -> list[float]:
    return [float(value) for value in values if value is not None and value != ""]


def metrics(rows: list[dict[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {
        "events": len(rows),
        "stocks": len({(row["sample"], row["stock_id"]) for row in rows}),
        "windows": len({(row["sample"], row["window_id"]) for row in rows}),
    }
    buy_returns = numeric(row.get("return_to_actual_buy") for row in rows)
    buy_days = numeric(row.get("days_to_actual_buy") for row in rows)
    result["actual_buy_events"] = len(buy_returns)
    result["mean_return_to_actual_buy"] = mean(buy_returns) if buy_returns else None
    result["median_return_to_actual_buy"] = median(buy_returns) if buy_returns else None
    result["earlier_buy_cheaper_rate"] = (
        100 * sum(value > 0 for value in buy_returns) / len(buy_returns) if buy_returns else None
    )
    result["mean_days_to_actual_buy"] = mean(buy_days) if buy_days else None
    for horizon in HORIZONS:
        returns = numeric(row.get(f"h{horizon}_return") for row in rows)
        minimums = numeric(row.get(f"h{horizon}_minimum_return") for row in rows)
        maximums = numeric(row.get(f"h{horizon}_maximum_return") for row in rows)
        valid_rows = [row for row in rows if row.get(f"h{horizon}_return") is not None]
        result[f"valid_h{horizon}"] = len(returns)
        result[f"mean_return_h{horizon}"] = mean(returns) if returns else None
        result[f"median_return_h{horizon}"] = median(returns) if returns else None
        result[f"rise_rate_h{horizon}"] = 100 * sum(value > 0 for value in returns) / len(returns) if returns else None
        result[f"mean_minimum_h{horizon}"] = mean(minimums) if minimums else None
        result[f"mean_maximum_h{horizon}"] = mean(maximums) if maximums else None
        result[f"no_buy_rate_h{horizon}"] = (
            100 * sum(int(row[f"h{horizon}_no_buy"]) for row in valid_rows) / len(valid_rows)
            if valid_rows else None
        )
        result[f"missed_rise_rate_h{horizon}"] = (
            100 * sum(int(row[f"h{horizon}_missed_rise"]) for row in valid_rows) / len(valid_rows)
            if valid_rows else None
        )
    return result


def condition_groups(rows: list[dict[str, Any]]) -> dict[tuple[str, str], list[dict[str, Any]]]:
    groups: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        groups[("全部", "全部")].append(row)
        groups[("Grade", str(row["grade_name"]))].append(row)
        groups[("趨勢階段", str(row["fit_phase_name"]))].append(row)
        groups[("既有輪次", str(row["roll_round_bucket"]))].append(row)
        groups[("既有累計ROI", str(row["roll_roi_bucket"]))].append(row)
        for gate in str(row["candidate_gates"]).split("+"):
            groups[("Gate", gate)].append(row)
            groups[("Gate×Grade", f"{gate}×{row['grade_name']}")].append(row)
            groups[("Gate×趨勢", f"{gate}×{row['fit_phase_name']}")].append(row)
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
        same_entry_advantage = (
            a["mean_return_to_actual_buy"] is not None and b["mean_return_to_actual_buy"] is not None
            and a["mean_return_to_actual_buy"] > 0 and b["mean_return_to_actual_buy"] > 0
        )
        same_positive_h20 = (
            a["mean_return_h20"] is not None and b["mean_return_h20"] is not None
            and a["mean_return_h20"] > 0 and b["mean_return_h20"] > 0
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
            "a_mean_return_to_actual_buy": a["mean_return_to_actual_buy"],
            "b_mean_return_to_actual_buy": b["mean_return_to_actual_buy"],
            "combined_earlier_buy_cheaper_rate": combined["earlier_buy_cheaper_rate"],
            "a_mean_return_h20": a["mean_return_h20"],
            "b_mean_return_h20": b["mean_return_h20"],
            "combined_mean_return_h20": combined["mean_return_h20"],
            "combined_mean_return_h60": combined["mean_return_h60"],
            "combined_missed_rise_rate_h20": combined["missed_rise_rate_h20"],
            "broad_enough": int(broad),
            "same_entry_advantage": int(same_entry_advantage),
            "same_positive_h20": int(same_positive_h20),
            "diagnostic_shortlist": int(broad and same_entry_advantage and same_positive_h20),
        })
    return sorted(
        output,
        key=lambda row: (
            -row["diagnostic_shortlist"],
            -(row["combined_mean_return_h20"] if row["combined_mean_return_h20"] is not None else -999),
            row["dimension"],
            row["condition"],
        ),
    )


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
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("exports/near-threshold-buy-study/nr1-baseline-v10-t2s28-20260825"),
    )
    parser.add_argument("--samples", nargs=2, default=["A", "B"])
    arguments = parser.parse_args()
    samples = [value.upper() for value in arguments.samples]

    all_events: list[dict[str, Any]] = []
    sources: dict[str, Any] = {}
    for sample in samples:
        base_id = DEFAULT_BASE_ID.format(sample=sample.lower())
        decision_path = Path("exports/backtest-decision-bases") / base_id / "decisions.sqlite"
        price_path = Path(f"/tmp/gt-p01-input/{sample.lower()}.store")
        rows, metadata = load_buy_rows(decision_path, sample)
        events = select_first_near_miss_per_flat_period(rows)
        prices, _ = load_prices(price_path)
        decorate_forward_outcomes(events, rows, prices)
        all_events.extend(events)
        sources[sample] = {
            "decisionBase": str(decision_path),
            "priceStore": str(price_path),
            "buyPhaseEvents": len(rows),
            "selectedNearMissEvents": len(events),
            "metadata": metadata,
        }

    summary = summary_rows(all_events, samples)
    cross = cross_sample_rows(summary, samples)
    output = arguments.output
    output.mkdir(parents=True, exist_ok=True)
    write_csv(output / "events.csv", all_events)
    write_csv(output / "condition-summary.csv", summary)
    write_csv(output / "cross-sample-screen.csv", cross)
    manifest = {
        "runID": output.name,
        "createdAt": datetime.now(TAIPEI).isoformat(),
        "baseline": "v10",
        "dataRuleVersion": "T2/S28",
        "strategyRuleVersion": "S24",
        "ruleCommit": "73003cf8f39cbf3a673792957324f508261bd731",
        "samples": samples,
        "horizons": list(HORIZONS),
        "selectedEventCount": len(all_events),
        "definition": "empty inventory, no buy that day, H-T01 or L-T01 score exactly one below its recorded formal threshold",
        "deduplication": "first exactly-one-vote-short event in each baseline flat period",
        "sources": sources,
        "limitations": [
            "This is observational diagnosis of the formal baseline path, not a counterfactual replay.",
            "A positive return to the later baseline buy means the near-miss date had a lower close.",
            "A shortlist is only a hypothesis; any rule must be replayed as one controlled candidate.",
        ],
        "files": ["manifest.json", "events.csv", "condition-summary.csv", "cross-sample-screen.csv"],
    }
    (output / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({
        "output": str(output),
        "events": len(all_events),
        "shortlist": sum(int(row["diagnostic_shortlist"]) for row in cross),
    }, ensure_ascii=False))


if __name__ == "__main__":
    main()
