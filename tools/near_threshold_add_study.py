#!/usr/bin/env python3
"""Diagnose Baseline add-on decisions that were conservatively one vote short."""

from __future__ import annotations

import argparse
import bisect
import csv
import json
import math
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


def open_readonly(path: Path):
    import sqlite3

    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
    if integrity != "ok":
        connection.close()
        raise RuntimeError(f"SQLite integrity failed: {path}: {integrity}")
    return connection


def close_enough(value: float, target: float) -> bool:
    return math.isclose(value, target, abs_tol=1e-9)


def load_rows(path: Path, sample: str) -> tuple[list[dict[str, Any]], dict[str, str]]:
    connection = open_readonly(path)
    try:
        metadata = {row["key"]: row["value"] for row in connection.execute("SELECT key,value FROM metadata")}
        query = """
            SELECT e.event_id,e.window_id,w.start_date,w.end_date,
                   s.stock_id,s.name stock_name,s.group_name,e.trade_date,e.phase,
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
            WHERE e.phase IN (3,4)
            ORDER BY e.window_id,s.stock_id,e.trade_date,e.phase
        """
        return [dict(row) | {"sample": sample} for row in connection.execute(query)], metadata
    finally:
        connection.close()


def candidate_gate(row: dict[str, Any]) -> tuple[str, float] | None:
    if int(row["phase"]) != 4 or float(row["inventory_before"]) <= 0:
        return None
    if str(row["planned_action"]).upper() != "NONE" or str(row["executed_action"]).upper() != "NONE":
        return None
    score = float(row["decision_score"])
    roi = float(row["unit_roi_before"])
    days = float(row["holding_days_before"])
    grade = int(row["grade"])

    # A-T01 has multiple formal ROI routes. ROI below -32.5% is the conservative
    # common deep-loss region; at aWant 2 it is exactly one vote below >= 3.
    if roi < -32.5 and close_enough(score, 2.0):
        return "A-T01保守深虧", 3.0

    # Formal A-T02: L entry, under 60 days, ROI between -10% and 1%; low/damn
    # require 2 votes and all other Grades require 3.
    threshold = 2.0 if grade <= -2 else 3.0
    if (
        str(row["buy_rule_before"]).upper() == "L"
        and days < 60
        and -10 < roi < 1
        and close_enough(score, threshold - 1)
    ):
        return "A-T02早期小虧", threshold
    return None


def select_first_per_investment_stage(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    selected: list[dict[str, Any]] = []
    seen: set[tuple[int, str, float, float, str]] = set()
    for row in rows:
        gate = candidate_gate(row)
        if gate is None:
            continue
        gate_name, threshold = gate
        key = (
            int(row["window_id"]),
            str(row["stock_id"]),
            round(float(row["roll_rounds_before"]), 6),
            round(float(row["invest_times_before"]), 6),
            gate_name,
        )
        if key in seen:
            continue
        seen.add(key)
        value = dict(row)
        value["candidate_gate"] = gate_name
        value["candidate_threshold"] = threshold
        value["grade_name"] = GRADE_NAMES.get(int(row["grade"]), "unknown")
        value["fit_phase_name"] = FIT_PHASE_NAMES.get(int(row["fit_trend_phase"]), "unknown")
        value["investment_stage"] = f"投入前次數{float(row['invest_times_before']):g}"
        selected.append(value)
    return selected


def price_indexes(prices: dict[str, list[PriceRow]]) -> dict[str, dict[int, int]]:
    return {
        stock_id: {item.trade_date: index for index, item in enumerate(series)}
        for stock_id, series in prices.items()
    }


def decorate_outcomes(
    events: list[dict[str, Any]],
    all_rows: list[dict[str, Any]],
    prices: dict[str, list[PriceRow]],
) -> None:
    indexes = price_indexes(prices)
    adds: dict[tuple[int, str], list[int]] = defaultdict(list)
    sells: dict[tuple[int, str], list[int]] = defaultdict(list)
    for row in all_rows:
        action = str(row["executed_action"]).upper()
        key = (int(row["window_id"]), str(row["stock_id"]))
        if int(row["phase"]) == 4 and action == "ADD":
            adds[key].append(int(row["trade_date"]))
        elif int(row["phase"]) == 3 and action == "SELL":
            sells[key].append(int(row["trade_date"]))

    for event in events:
        stock_id = str(event["stock_id"])
        key = (int(event["window_id"]), stock_id)
        series = prices[stock_id]
        index = indexes[stock_id].get(int(event["trade_date"]))
        if index is None:
            raise RuntimeError(f"Missing price for {event['sample']} {stock_id} {event['trade_date']}")
        event_price = series[index].close
        event["close_price"] = event_price

        add_position = bisect.bisect_right(adds[key], int(event["trade_date"]))
        sell_position = bisect.bisect_right(sells[key], int(event["trade_date"]))
        next_add = adds[key][add_position] if add_position < len(adds[key]) else None
        next_sell = sells[key][sell_position] if sell_position < len(sells[key]) else None
        if next_add is not None and next_sell is not None and next_add >= next_sell:
            next_add = None
        event["next_add_date"] = next_add
        event["next_sell_date"] = next_sell
        event["days_to_next_add"] = None
        event["return_to_next_add"] = None
        event["days_to_next_sell"] = None
        event["return_to_next_sell"] = None

        if next_add is not None and next_add in indexes[stock_id]:
            next_index = indexes[stock_id][next_add]
            event["days_to_next_add"] = next_index - index
            event["return_to_next_add"] = 100 * (series[next_index].close / event_price - 1)
        if next_sell is not None and next_sell in indexes[stock_id]:
            next_index = indexes[stock_id][next_sell]
            event["days_to_next_sell"] = next_index - index
            event["return_to_next_sell"] = 100 * (series[next_index].close / event_price - 1)

        for horizon in HORIZONS:
            prefix = f"h{horizon}"
            end_index = index + horizon
            if end_index >= len(series) or series[end_index].trade_date > int(event["end_date"]):
                for field in ("return", "minimum_return", "maximum_return", "sold_before"):
                    event[f"{prefix}_{field}"] = None
                continue
            path = series[index + 1 : end_index + 1]
            returns = [100 * (item.close / event_price - 1) for item in path]
            event[f"{prefix}_return"] = returns[-1]
            event[f"{prefix}_minimum_return"] = min(returns)
            event[f"{prefix}_maximum_return"] = max(returns)
            sell_days = event["days_to_next_sell"]
            event[f"{prefix}_sold_before"] = int(sell_days is not None and sell_days <= horizon)


def numeric(values: Iterable[Any]) -> list[float]:
    return [float(value) for value in values if value is not None and value != ""]


def metrics(rows: list[dict[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {
        "events": len(rows),
        "stocks": len({(row["sample"], row["stock_id"]) for row in rows}),
        "windows": len({(row["sample"], row["window_id"]) for row in rows}),
    }
    for label, field in (("next_add", "return_to_next_add"), ("next_sell", "return_to_next_sell")):
        returns = numeric(row.get(field) for row in rows)
        days = numeric(row.get(f"days_to_{label}") for row in rows)
        result[f"{label}_events"] = len(returns)
        result[f"mean_return_to_{label}"] = mean(returns) if returns else None
        result[f"median_return_to_{label}"] = median(returns) if returns else None
        result[f"positive_return_to_{label}_rate"] = (
            100 * sum(value > 0 for value in returns) / len(returns) if returns else None
        )
        result[f"mean_days_to_{label}"] = mean(days) if days else None
    for horizon in HORIZONS:
        returns = numeric(row.get(f"h{horizon}_return") for row in rows)
        minimums = numeric(row.get(f"h{horizon}_minimum_return") for row in rows)
        maximums = numeric(row.get(f"h{horizon}_maximum_return") for row in rows)
        result[f"valid_h{horizon}"] = len(returns)
        result[f"mean_return_h{horizon}"] = mean(returns) if returns else None
        result[f"median_return_h{horizon}"] = median(returns) if returns else None
        result[f"rise_rate_h{horizon}"] = 100 * sum(value > 0 for value in returns) / len(returns) if returns else None
        result[f"mean_minimum_h{horizon}"] = mean(minimums) if minimums else None
        result[f"mean_maximum_h{horizon}"] = mean(maximums) if maximums else None
    return result


def condition_groups(rows: list[dict[str, Any]]) -> dict[tuple[str, str], list[dict[str, Any]]]:
    groups: dict[tuple[str, str], list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        groups[("全部", "全部")].append(row)
        groups[("Gate", str(row["candidate_gate"]))].append(row)
        groups[("Grade", str(row["grade_name"]))].append(row)
        groups[("趨勢階段", str(row["fit_phase_name"]))].append(row)
        groups[("投入階段", str(row["investment_stage"]))].append(row)
        groups[("Gate×Grade", f"{row['candidate_gate']}×{row['grade_name']}")].append(row)
        groups[("Gate×趨勢", f"{row['candidate_gate']}×{row['fit_phase_name']}")].append(row)
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
    conditions = sorted({(row["dimension"], row["condition"]) for row in summary if row["scope"] == "全部"})
    output: list[dict[str, Any]] = []
    for dimension, condition in conditions:
        a = lookup.get((first, dimension, condition))
        b = lookup.get((second, dimension, condition))
        combined = lookup[("全部", dimension, condition)]
        if not a or not b:
            continue
        broad = a["events"] >= 3 and b["events"] >= 3 and combined["stocks"] >= 4 and combined["windows"] >= 4
        same_positive_sell = (
            a["mean_return_to_next_sell"] is not None
            and b["mean_return_to_next_sell"] is not None
            and a["mean_return_to_next_sell"] > 0
            and b["mean_return_to_next_sell"] > 0
        )
        same_positive_h20 = (
            a["mean_return_h20"] is not None
            and b["mean_return_h20"] is not None
            and a["mean_return_h20"] > 0
            and b["mean_return_h20"] > 0
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
            "a_mean_return_to_next_add": a["mean_return_to_next_add"],
            "b_mean_return_to_next_add": b["mean_return_to_next_add"],
            "a_mean_return_to_next_sell": a["mean_return_to_next_sell"],
            "b_mean_return_to_next_sell": b["mean_return_to_next_sell"],
            "a_mean_return_h20": a["mean_return_h20"],
            "b_mean_return_h20": b["mean_return_h20"],
            "combined_mean_return_h60": combined["mean_return_h60"],
            "broad_enough": int(broad),
            "same_positive_sell": int(same_positive_sell),
            "same_positive_h20": int(same_positive_h20),
            "diagnostic_shortlist": int(broad and same_positive_sell and same_positive_h20),
        })
    return sorted(
        output,
        key=lambda row: (
            -row["diagnostic_shortlist"],
            -(row["combined_mean_return_h60"] if row["combined_mean_return_h60"] is not None else -999),
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
        default=Path("exports/near-threshold-add-study/nr2-baseline-v10-t2s28-20260825"),
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
        rows, metadata = load_rows(decision_path, sample)
        events = select_first_per_investment_stage(rows)
        prices, _ = load_prices(price_path)
        decorate_outcomes(events, rows, prices)
        all_events.extend(events)
        sources[sample] = {
            "decisionBase": str(decision_path),
            "priceStore": str(price_path),
            "holdingAndAddEvents": len(rows),
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
        "definition": {
            "A-T01保守深虧": "inventory, no add, ROI < -32.5%, aWant = 2 (one below >= 3)",
            "A-T02早期小虧": "L entry, days < 60, -10% < ROI < 1%, aWant exactly one below Grade threshold",
        },
        "deduplication": "first near-miss in each baseline stock-window, completed-round, investment-count and gate stage",
        "sources": sources,
        "limitations": [
            "This is observational diagnosis of the formal baseline path, not a counterfactual replay.",
            "A-T01 uses a conservative deep-loss region to avoid guessing the formal multi-route Grade boundary.",
            "A-E execution limits are not assumed to pass; any proposed vote change must be tested by full replay.",
            "A positive return to the next sell means the event close was below the later baseline sell price.",
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
