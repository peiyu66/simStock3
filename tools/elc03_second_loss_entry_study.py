#!/usr/bin/env python3
"""Diagnose decision-time features of entries that become a second consecutive loss."""

from __future__ import annotations

import argparse
import csv
import itertools
import json
import math
import sqlite3
import statistics
from collections import defaultdict
from pathlib import Path


GRADE_NAMES = {-3: "damn", -2: "low", -1: "weak", 0: "none", 1: "fine", 2: "high", 3: "wow"}
PHASE_NAMES = {
    0: "unavailable",
    1: "neutral",
    2: "improvingWarning",
    3: "worseningWarning",
    4: "improvingConfirmedLegacy",
    5: "worseningConfirmedLegacy",
    6: "improvingCooldown",
    7: "worseningCooldown",
    8: "improvingSeekingPeak",
    9: "improvingPullingBack",
    10: "worseningSeekingBottom",
    11: "worseningRebounding",
}
TECH_COLUMNS = [
    "close_change_percent",
    "high_diff",
    "low_diff",
    "high_diff_z125",
    "high_diff_z250",
    "low_diff_z125",
    "low_diff_z250",
    "ma20_days",
    "ma20_diff",
    "ma20_diff_z125",
    "ma20_diff_z250",
    "ma60_days",
    "ma60_diff",
    "ma60_diff_z125",
    "ma60_diff_z250",
    "price_z125",
    "price_z250",
    "kd_k",
    "kd_k_z125",
    "kd_k_z250",
    "kd_d",
    "kd_d_z125",
    "kd_d_z250",
    "kd_j",
    "kd_j_z125",
    "kd_j_z250",
    "osc",
    "osc_z125",
    "osc_z250",
    "volume_ma20_days",
    "volume_ma20_diff",
    "volume_ma20_diff_z125",
    "volume_ma20_diff_z250",
    "volume_ma60_days",
    "volume_ma60_diff",
    "volume_ma60_diff_z125",
    "volume_ma60_diff_z250",
    "volume_z125",
    "volume_z250",
    "minimum9_mask",
    "maximum9_mask",
]
FIT_COLUMNS = [
    "fit_level",
    "fit_fast",
    "fit_slow",
    "fit_trend",
    "fit_trend_phase",
    "fit_trend_phase_extreme",
    "fit_evidence_rounds",
    "fit_evidence_days",
    "fit_observation_count",
    "roi_trend",
    "days_trend",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--decision-db", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--browse-store", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def round_currency(value: float) -> float:
    return math.floor(value + 0.5)


def realized_roi(sell: sqlite3.Row) -> float:
    qty = float(sell["inventory_before"])
    unit_cost = float(sell["unit_cost_before"])
    unit_roi = float(sell["unit_roi_before"])
    close = unit_cost * (1.0 + unit_roi / 100.0)
    proceeds = close * qty * 1000.0
    fee = max(20.0, round_currency(proceeds * 0.001425))
    tax = round_currency(proceeds * 0.003)
    cost = unit_cost * qty * 1000.0
    return 100.0 * (proceeds - cost - fee - tax) / cost


def fit_class(phase: int | None) -> str:
    if phase in (2, 8, 9):
        return "improving"
    if phase in (3, 10, 11):
        return "worsening"
    return "stable"


def loss_roi_bucket(value: float) -> str:
    if value <= -17.5:
        return "<=-17.5"
    if value <= -10.0:
        return "(-17.5,-10]"
    return ">-10"


def loss_days_bucket(value: float) -> str:
    if value <= 90:
        return "<=90"
    if value <= 240:
        return "91-240"
    return ">240"


def gap_bucket(value: int) -> str:
    if value <= 7:
        return "<=7"
    if value <= 20:
        return "8-20"
    if value <= 40:
        return "21-40"
    return ">40"


def median(values: list[float]) -> float | None:
    return statistics.median(values) if values else None


def cliffs_delta(losses: list[float], recoveries: list[float]) -> float | None:
    if not losses or not recoveries:
        return None
    greater = 0
    less = 0
    for left in losses:
        for right in recoveries:
            if left > right:
                greater += 1
            elif left < right:
                less += 1
    return (greater - less) / (len(losses) * len(recoveries))


def write_csv(path: Path, rows: list[dict], columns: list[str] | None = None) -> None:
    if not rows and not columns:
        return
    fieldnames = columns or list(rows[0].keys())
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def categorical_rows(events: list[dict], definitions: list[tuple[str, tuple[str, ...]]]) -> list[dict]:
    rows: list[dict] = []
    completed = [event for event in events if event["outcome"] != "censored"]
    for feature, keys in definitions:
        groups: dict[str, list[dict]] = defaultdict(list)
        for event in completed:
            value = " × ".join(str(event[key]) for key in keys)
            groups[value].append(event)
        for value, members in groups.items():
            losses = sum(event["outcome"] == "second_loss" for event in members)
            stocks = {event["stock_id"] for event in members}
            windows = {event["window_start"] for event in members}
            rows.append(
                {
                    "feature": feature,
                    "value": value,
                    "events": len(members),
                    "second_losses": losses,
                    "recoveries": len(members) - losses,
                    "second_loss_rate": losses / len(members),
                    "stock_count": len(stocks),
                    "window_count": len(windows),
                    "stocks": ",".join(sorted(stocks)),
                    "windows": ",".join(sorted(windows)),
                }
            )
    return sorted(rows, key=lambda row: (row["feature"], -row["second_loss_rate"], -row["events"], row["value"]))


def token_rows(events: list[dict], token_key: str, kind: str, pair: bool = False, contextual: str | None = None) -> list[dict]:
    groups: dict[str, list[dict]] = defaultdict(list)
    completed = [event for event in events if event["outcome"] != "censored"]
    for event in completed:
        tokens = event[token_key]
        values = itertools.combinations(tokens, 2) if pair else ((token,) for token in tokens)
        for value_tuple in values:
            value = " + ".join(value_tuple)
            if contextual:
                value = f"{event[contextual]} × {value}"
            groups[value].append(event)
    rows: list[dict] = []
    for value, members in groups.items():
        losses = sum(event["outcome"] == "second_loss" for event in members)
        rows.append(
            {
                "feature": kind,
                "value": value,
                "events": len(members),
                "second_losses": losses,
                "recoveries": len(members) - losses,
                "second_loss_rate": losses / len(members),
                "stock_count": len({event["stock_id"] for event in members}),
                "window_count": len({event["window_start"] for event in members}),
                "stocks": ",".join(sorted({event["stock_id"] for event in members})),
                "windows": ",".join(sorted({event["window_start"] for event in members})),
            }
        )
    return sorted(rows, key=lambda row: (-row["second_loss_rate"], -row["events"], row["value"]))


def numeric_rows(events: list[dict], numeric_keys: list[str]) -> list[dict]:
    rows: list[dict] = []
    for key in numeric_keys:
        losses = [float(event[key]) for event in events if event["outcome"] == "second_loss" and event.get(key) is not None]
        recoveries = [float(event[key]) for event in events if event["outcome"] == "recovery" and event.get(key) is not None]
        if not losses or not recoveries:
            continue
        clean = "none"
        if max(losses) < min(recoveries):
            clean = "second_loss_lower"
        elif min(losses) > max(recoveries):
            clean = "second_loss_higher"
        rows.append(
            {
                "feature": key,
                "second_loss_count": len(losses),
                "recovery_count": len(recoveries),
                "second_loss_median": median(losses),
                "recovery_median": median(recoveries),
                "second_loss_min": min(losses),
                "second_loss_max": max(losses),
                "recovery_min": min(recoveries),
                "recovery_max": max(recoveries),
                "cliffs_delta": cliffs_delta(losses, recoveries),
                "clean_separation": clean,
            }
        )
    return sorted(rows, key=lambda row: (-abs(row["cliffs_delta"] or 0.0), row["feature"]))


def gini(rows: list[dict]) -> float:
    if not rows:
        return 0.0
    positive = sum(row["outcome"] == "second_loss" for row in rows) / len(rows)
    return 1.0 - positive * positive - (1.0 - positive) * (1.0 - positive)


def best_tree_split(rows: list[dict], features: list[str], minimum_leaf: int) -> tuple[str, float, float] | None:
    parent_impurity = gini(rows)
    best: tuple[str, float, float] | None = None
    for feature in features:
        if any(row.get(feature) is None for row in rows):
            continue
        values = sorted({float(row[feature]) for row in rows})
        for left_value, right_value in zip(values, values[1:]):
            threshold = (left_value + right_value) / 2.0
            left = [row for row in rows if float(row[feature]) <= threshold]
            right = [row for row in rows if float(row[feature]) > threshold]
            if len(left) < minimum_leaf or len(right) < minimum_leaf:
                continue
            weighted = (len(left) * gini(left) + len(right) * gini(right)) / len(rows)
            gain = parent_impurity - weighted
            if best is None or gain > best[2] + 1e-12:
                best = (feature, threshold, gain)
    return best


def build_shallow_tree(rows: list[dict], features: list[str], depth: int = 0, maximum_depth: int = 2) -> dict:
    node = {
        "events": len(rows),
        "secondLosses": sum(row["outcome"] == "second_loss" for row in rows),
        "stocks": sorted({row["stock_id"] for row in rows}),
    }
    node["secondLossRate"] = node["secondLosses"] / node["events"] if node["events"] else None
    if depth >= maximum_depth or node["secondLosses"] in (0, node["events"]):
        return node
    split = best_tree_split(rows, features, minimum_leaf=3)
    if split is None or split[2] <= 0:
        return node
    feature, threshold, gain = split
    left = [row for row in rows if float(row[feature]) <= threshold]
    right = [row for row in rows if float(row[feature]) > threshold]
    node.update(
        {
            "feature": feature,
            "threshold": threshold,
            "giniGain": gain,
            "left": build_shallow_tree(left, features, depth + 1, maximum_depth),
            "right": build_shallow_tree(right, features, depth + 1, maximum_depth),
        }
    )
    return node


def collect_tree_leaves(node: dict, conditions: list[dict] | None = None) -> list[dict]:
    conditions = list(conditions or [])
    if "feature" not in node:
        return [{"conditions": conditions} | node]
    left_condition = {"feature": node["feature"], "operator": "<=", "threshold": node["threshold"]}
    right_condition = {"feature": node["feature"], "operator": ">", "threshold": node["threshold"]}
    return collect_tree_leaves(node["left"], conditions + [left_condition]) + collect_tree_leaves(
        node["right"], conditions + [right_condition]
    )


def matches_conditions(row: dict, conditions: list[dict]) -> bool:
    for condition in conditions:
        value = row.get(condition["feature"])
        if value is None:
            return False
        if condition["operator"] == "<=" and not float(value) <= condition["threshold"]:
            return False
        if condition["operator"] == ">" and not float(value) > condition["threshold"]:
            return False
    return True


def condition_text(conditions: list[dict]) -> str:
    return " and ".join(
        f"{condition['feature']} {condition['operator']} {condition['threshold']:.6f}" for condition in conditions
    )


def browse_data(path: Path) -> tuple[dict[tuple[str, int], float], dict[tuple[str, int], dict]]:
    connection = sqlite3.connect(path)
    connection.row_factory = sqlite3.Row
    outcome_rows = connection.execute(
        """
        SELECT s.ZSID AS stock_id,
               CAST(strftime('%Y%m%d', t.ZDATETIME + 978307200, 'unixepoch') AS INTEGER) AS trade_date,
               t.ZSIMAMTROI AS realized_roi
        FROM ZTRADE t
        JOIN ZSTOCK s ON s.Z_PK = t.ZSTOCK
        WHERE t.ZSIMQTYSELL > 0
        """
    ).fetchall()
    technical_rows = connection.execute(
        """
        WITH raw AS (
            SELECT s.ZSID AS stock_id,
                   CAST(strftime('%Y%m%d', t.ZDATETIME + 978307200, 'unixepoch') AS INTEGER) AS trade_date,
                   t.*,
                   LAG(t.ZPRICECLOSE) OVER (PARTITION BY s.ZSID ORDER BY t.ZDATETIME) AS previous_close
            FROM ZTRADE t
            JOIN ZSTOCK s ON s.Z_PK = t.ZSTOCK
        )
        SELECT stock_id, trade_date,
               CASE WHEN previous_close > 0
                    THEN 100.0 * (ZPRICECLOSE - previous_close) / previous_close END AS close_change_percent,
               ZTHIGHDIFF AS high_diff,
               ZTLOWDIFF AS low_diff,
               ZTHIGHDIFFZ125 AS high_diff_z125,
               ZTHIGHDIFFZ250 AS high_diff_z250,
               ZTLOWDIFFZ125 AS low_diff_z125,
               ZTLOWDIFFZ250 AS low_diff_z250,
               ZTMA20DAYS AS ma20_days,
               ZTMA20DIFF AS ma20_diff,
               ZTMA20DIFFZ125 AS ma20_diff_z125,
               ZTMA20DIFFZ250 AS ma20_diff_z250,
               ZTMA60DAYS AS ma60_days,
               ZTMA60DIFF AS ma60_diff,
               ZTMA60DIFFZ125 AS ma60_diff_z125,
               ZTMA60DIFFZ250 AS ma60_diff_z250,
               ZTZ125 AS price_z125,
               ZTZ250 AS price_z250,
               ZTKDK AS kd_k,
               ZTKDKZ125 AS kd_k_z125,
               ZTKDKZ250 AS kd_k_z250,
               ZTKDD AS kd_d,
               ZTKDDZ125 AS kd_d_z125,
               ZTKDDZ250 AS kd_d_z250,
               ZTKDJ AS kd_j,
               ZTKDJZ125 AS kd_j_z125,
               ZTKDJZ250 AS kd_j_z250,
               ZTOSC AS osc,
               ZTOSCZ125 AS osc_z125,
               ZTOSCZ250 AS osc_z250,
               ZVMA20DAYS AS volume_ma20_days,
               ZVMA20DIFF AS volume_ma20_diff,
               ZVMA20DIFFZ125 AS volume_ma20_diff_z125,
               ZVMA20DIFFZ250 AS volume_ma20_diff_z250,
               ZVMA60DAYS AS volume_ma60_days,
               ZVMA60DIFF AS volume_ma60_diff,
               ZVMA60DIFFZ125 AS volume_ma60_diff_z125,
               ZVMA60DIFFZ250 AS volume_ma60_diff_z250,
               ZVZ125 AS volume_z125,
               ZVZ250 AS volume_z250,
               (CASE WHEN ZTMA20DIFF = ZTMA20DIFFMIN9 THEN 1 ELSE 0 END)
                 + (CASE WHEN ZTMA60DIFF = ZTMA60DIFFMIN9 THEN 2 ELSE 0 END)
                 + (CASE WHEN ZTOSC = ZTOSCMIN9 THEN 4 ELSE 0 END)
                 + (CASE WHEN ZTKDK = ZTKDKMIN9 THEN 8 ELSE 0 END)
                 + (CASE WHEN ZVOLUMECLOSE = ZVMIN9 THEN 16 ELSE 0 END) AS minimum9_mask,
               (CASE WHEN ZTMA20DIFF = ZTMA20DIFFMAX9 THEN 1 ELSE 0 END)
                 + (CASE WHEN ZTMA60DIFF = ZTMA60DIFFMAX9 THEN 2 ELSE 0 END)
                 + (CASE WHEN ZTOSC = ZTOSCMAX9 THEN 4 ELSE 0 END)
                 + (CASE WHEN ZTKDK = ZTKDKMAX9 THEN 8 ELSE 0 END)
                 + (CASE WHEN ZVOLUMECLOSE = ZVMAX9 THEN 16 ELSE 0 END) AS maximum9_mask
        FROM raw
        """
    ).fetchall()
    connection.close()
    outcomes = {(row["stock_id"], row["trade_date"]): row["realized_roi"] for row in outcome_rows}
    technical = {
        (row["stock_id"], row["trade_date"]): {column: row[column] for column in TECH_COLUMNS}
        for row in technical_rows
    }
    return outcomes, technical


def main() -> None:
    args = parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    connection = sqlite3.connect(args.decision_db)
    connection.row_factory = sqlite3.Row

    windows = {row["window_id"]: str(row["start_date"]) for row in connection.execute("SELECT * FROM windows")}
    stocks = {
        row["stock_key"]: {"stock_id": row["stock_id"], "stock_name": row["name"], "group": row["group_name"]}
        for row in connection.execute("SELECT * FROM stocks")
    }
    action_rows = connection.execute(
        """
        SELECT * FROM decision_events
        WHERE (executed_action = 'BUY' AND inventory_before = 0)
           OR (executed_action = 'SELL' AND phase = 3)
        ORDER BY window_id, stock_key, trade_date, event_id
        """
    ).fetchall()
    all_dates: dict[tuple[int, int], list[int]] = defaultdict(list)
    for row in connection.execute("SELECT DISTINCT window_id, stock_key, trade_date FROM decision_events ORDER BY window_id, stock_key, trade_date"):
        all_dates[(row["window_id"], row["stock_key"])].append(row["trade_date"])
    date_indices = {key: {date: index for index, date in enumerate(dates)} for key, dates in all_dates.items()}

    votes: dict[int, list[str]] = defaultdict(list)
    for row in connection.execute(
        """
        SELECT v.event_id, r.rule_id, v.contribution
        FROM event_votes v JOIN rules r USING(rule_key)
        WHERE ABS(v.contribution) > 0.0000001
        ORDER BY v.event_id, r.rule_id
        """
    ):
        contribution = f"{row['contribution']:+g}"
        votes[row["event_id"]].append(f"{row['rule_id']}({contribution})")
    gates: dict[int, list[str]] = defaultdict(list)
    for row in connection.execute(
        "SELECT g.event_id, r.rule_id FROM event_gates g JOIN rules r USING(rule_key) ORDER BY g.event_id, r.rule_id"
    ):
        gates[row["event_id"]].append(row["rule_id"])

    tech_by_event: dict[int, dict] = {}
    tech_sql = ", ".join(f"t.{column}" for column in TECH_COLUMNS)
    for row in connection.execute(
        f"""
        SELECT eo.event_id, {tech_sql}
        FROM event_observations eo
        JOIN technical_observations t USING(observation_id)
        """
    ):
        tech_by_event[row["event_id"]] = {column: row[column] for column in TECH_COLUMNS}
    fit_by_event: dict[int, dict] = {}
    fit_sql = ", ".join(f"o.{column}" for column in FIT_COLUMNS)
    for row in connection.execute(
        f"""
        SELECT l.event_id, {fit_sql}, o.grade_name
        FROM event_strategy_fit_observations l
        JOIN strategy_fit_observations o USING(observation_id)
        """
    ):
        fit_by_event[row["event_id"]] = {column: row[column] for column in FIT_COLUMNS} | {"grade_name": row["grade_name"]}

    grouped: dict[tuple[int, int], list[sqlite3.Row]] = defaultdict(list)
    for row in action_rows:
        grouped[(row["window_id"], row["stock_key"])].append(row)

    cycles: list[dict] = []
    for key, rows in grouped.items():
        current_buy: sqlite3.Row | None = None
        stock_cycles: list[dict] = []
        for row in rows:
            if row["executed_action"] == "BUY":
                if current_buy is not None:
                    raise RuntimeError(f"overlapping initial buys for {key}")
                current_buy = row
            elif row["executed_action"] == "SELL" and current_buy is not None:
                roi = realized_roi(row)
                stock_cycles.append({"buy": current_buy, "sell": row, "realized_roi": roi, "is_loss": roi < 0})
                current_buy = None
        if current_buy is not None:
            stock_cycles.append({"buy": current_buy, "sell": None, "realized_roi": None, "is_loss": None})
        for index, cycle in enumerate(stock_cycles):
            cycle["cycle_index"] = index
            cycle["key"] = key
            cycles.append(cycle)

    cycles_by_key: dict[tuple[int, int], list[dict]] = defaultdict(list)
    for cycle in cycles:
        cycles_by_key[cycle["key"]].append(cycle)

    study_events: list[dict] = []
    for key, stock_cycles in cycles_by_key.items():
        for index in range(1, len(stock_cycles)):
            previous = stock_cycles[index - 1]
            current = stock_cycles[index]
            if previous["is_loss"] is not True:
                continue
            prior_was_loss = index >= 2 and stock_cycles[index - 2]["is_loss"] is True
            if prior_was_loss:
                continue
            buy = current["buy"]
            sell = current["sell"]
            previous_sell = previous["sell"]
            window_id, stock_key = key
            stock = stocks[stock_key]
            fit = fit_by_event.get(buy["event_id"], {})
            tech = tech_by_event.get(buy["event_id"], {})
            phase = fit.get("fit_trend_phase")
            outcome = "censored" if sell is None else ("second_loss" if current["is_loss"] else "recovery")
            gap = date_indices[key][buy["trade_date"]] - date_indices[key][previous_sell["trade_date"]]
            event = {
                "window_start": windows[window_id],
                "stock_id": stock["stock_id"],
                "stock_name": stock["stock_name"],
                "group": stock["group"],
                "previous_loss_date": previous_sell["trade_date"],
                "previous_loss_roi": previous["realized_roi"],
                "previous_loss_days": previous_sell["holding_days_before"],
                "entry_date": buy["trade_date"],
                "entry_side": buy["planned_action"],
                "grade": fit.get("grade_name", GRADE_NAMES.get(buy["grade"], str(buy["grade"]))),
                "decision_score": buy["decision_score"],
                "decision_threshold": buy["decision_threshold"],
                "decision_margin": buy["decision_score"] - (buy["decision_threshold"] or 0.0),
                "trading_day_gap": gap,
                "previous_loss_roi_bucket": loss_roi_bucket(previous["realized_roi"]),
                "previous_loss_days_bucket": loss_days_bucket(previous_sell["holding_days_before"]),
                "gap_bucket": gap_bucket(gap),
                "fit_phase": PHASE_NAMES.get(phase, str(phase)),
                "fit_class": fit_class(phase),
                "outcome": outcome,
                "current_sell_date": sell["trade_date"] if sell is not None else None,
                "current_realized_roi": current["realized_roi"],
                "current_holding_days": sell["holding_days_before"] if sell is not None else None,
                "vote_tokens": votes.get(buy["event_id"], []),
                "gate_tokens": gates.get(buy["event_id"], []),
            }
            event.update(fit)
            event.update(tech)
            study_events.append(event)

    connection.close()

    browse_validation = {
        "checked": 0,
        "sign_mismatches": 0,
        "max_abs_roi_difference": 0.0,
        "technicalEventsMatched": 0,
        "technicalEventsMissing": 0,
    }
    if args.browse_store:
        actual, browse_technical = browse_data(args.browse_store)
        for key, stock_cycles in cycles_by_key.items():
            if key[0] != 1:
                continue
            stock_id = stocks[key[1]]["stock_id"]
            for cycle in stock_cycles:
                if cycle["sell"] is None:
                    continue
                lookup = (stock_id, cycle["sell"]["trade_date"])
                if lookup not in actual:
                    continue
                browse_validation["checked"] += 1
                difference = abs(actual[lookup] - cycle["realized_roi"])
                browse_validation["max_abs_roi_difference"] = max(browse_validation["max_abs_roi_difference"], difference)
                if (actual[lookup] < 0) != cycle["is_loss"]:
                    browse_validation["sign_mismatches"] += 1
        for event in study_events:
            lookup = (event["stock_id"], event["entry_date"])
            technical = browse_technical.get(lookup)
            if technical is None:
                browse_validation["technicalEventsMissing"] += 1
            else:
                browse_validation["technicalEventsMatched"] += 1
                event.update(technical)

    categorical_definitions = [
        ("entry_side", ("entry_side",)),
        ("grade", ("grade",)),
        ("fit_phase", ("fit_phase",)),
        ("fit_class", ("fit_class",)),
        ("decision_margin", ("decision_margin",)),
        ("previous_loss_roi_bucket", ("previous_loss_roi_bucket",)),
        ("previous_loss_days_bucket", ("previous_loss_days_bucket",)),
        ("gap_bucket", ("gap_bucket",)),
        ("entry_side_x_grade", ("entry_side", "grade")),
        ("grade_x_fit_class", ("grade", "fit_class")),
        ("grade_x_fit_phase", ("grade", "fit_phase")),
        ("grade_x_margin", ("grade", "decision_margin")),
        ("entry_side_x_fit_class", ("entry_side", "fit_class")),
        ("previous_loss_roi_x_grade", ("previous_loss_roi_bucket", "grade")),
        ("previous_loss_days_x_grade", ("previous_loss_days_bucket", "grade")),
        ("gap_x_grade", ("gap_bucket", "grade")),
    ]
    category_summary = categorical_rows(study_events, categorical_definitions)
    rule_summary = token_rows(study_events, "vote_tokens", "rule")
    rule_pair_summary = token_rows(study_events, "vote_tokens", "rule_pair", pair=True)
    grade_rule_summary = token_rows(study_events, "vote_tokens", "grade_x_rule", contextual="grade")
    numeric_keys = [
        "previous_loss_roi",
        "previous_loss_days",
        "trading_day_gap",
        "decision_score",
        "decision_threshold",
        "decision_margin",
    ] + FIT_COLUMNS + TECH_COLUMNS
    numeric_summary = numeric_rows(study_events, numeric_keys)
    completed = [event for event in study_events if event["outcome"] != "censored"]
    second_losses = [event for event in completed if event["outcome"] == "second_loss"]
    recoveries = [event for event in completed if event["outcome"] == "recovery"]

    repeated_perfect = [
        row
        for row in category_summary + rule_summary + rule_pair_summary + grade_rule_summary
        if row["events"] >= 3
        and row["stock_count"] >= 2
        and row["window_count"] >= 2
        and row["second_loss_rate"] == 1.0
    ]
    repeated_high = [
        row
        for row in category_summary + rule_summary + rule_pair_summary + grade_rule_summary
        if row["events"] >= 4
        and row["stock_count"] >= 2
        and row["window_count"] >= 2
        and row["second_loss_rate"] >= 0.75
    ]
    clean_numeric = [
        row
        for row in numeric_summary
        if row["clean_separation"] != "none"
        and row["second_loss_count"] == len(second_losses)
        and row["recovery_count"] == len(recoveries)
    ]
    tree_features = [
        key
        for key in numeric_keys
        if key not in ("fit_trend_phase", "minimum9_mask", "maximum9_mask")
    ]
    generation_events = [event for event in completed if event["window_start"] == "20170722"]
    validation_events = [event for event in completed if event["window_start"] != "20170722"]
    shallow_tree = build_shallow_tree(generation_events, tree_features)
    high_risk_leaves = []
    for leaf in collect_tree_leaves(shallow_tree):
        if leaf["events"] < 3 or leaf["secondLossRate"] < 0.5:
            continue
        matched = [event for event in validation_events if matches_conditions(event, leaf["conditions"])]
        losses = sum(event["outcome"] == "second_loss" for event in matched)
        windows = sorted({event["window_start"] for event in matched})
        stocks = sorted({event["stock_id"] for event in matched})
        high_risk_leaves.append(
            leaf
            | {
                "conditionText": condition_text(leaf["conditions"]),
                "validationEvents": len(matched),
                "validationSecondLosses": losses,
                "validationSecondLossRate": losses / len(matched) if matched else None,
                "validationStocks": stocks,
                "validationWindows": windows,
            }
        )
    validated_tree_signatures = [
        leaf
        for leaf in high_risk_leaves
        if leaf["validationEvents"] >= 4
        and len(leaf["validationStocks"]) >= 2
        and len(leaf["validationWindows"]) == 2
        and leaf["validationSecondLossRate"] >= 0.75
    ]

    flat_events = []
    for event in sorted(study_events, key=lambda item: (item["window_start"], item["stock_id"], item["entry_date"])):
        row = {key: value for key, value in event.items() if key not in ("vote_tokens", "gate_tokens")}
        row["vote_tokens"] = "|".join(event["vote_tokens"])
        row["gate_tokens"] = "|".join(event["gate_tokens"])
        flat_events.append(row)
    write_csv(args.output / "events.csv", flat_events)
    write_csv(args.output / "categorical-summary.csv", category_summary)
    write_csv(args.output / "rule-summary.csv", rule_summary)
    write_csv(args.output / "rule-pair-summary.csv", rule_pair_summary)
    write_csv(args.output / "grade-rule-summary.csv", grade_rule_summary)
    write_csv(args.output / "numeric-summary.csv", numeric_summary)

    summary = {
        "studyID": "E-LC03-D0-E",
        "baselineRunID": manifest["runID"],
        "sampleID": manifest["sampleID"],
        "dataRuleVersion": manifest["dataRuleVersion"],
        "ruleVersion": manifest["ruleVersion"],
        "ruleCommit": manifest["ruleCommit"],
        "eventDefinition": "next initial buy after exactly one consecutive automatic loss close",
        "eventCount": len(study_events),
        "completedCount": len(completed),
        "secondLossCount": len(second_losses),
        "recoveryCount": len(recoveries),
        "censoredCount": sum(event["outcome"] == "censored" for event in study_events),
        "secondLossRate": len(second_losses) / len(completed) if completed else None,
        "stockCount": len({event["stock_id"] for event in study_events}),
        "windowCount": len({event["window_start"] for event in study_events}),
        "tradingDayGap": {
            "median": median([event["trading_day_gap"] for event in study_events]),
            "min": min((event["trading_day_gap"] for event in study_events), default=None),
            "max": max((event["trading_day_gap"] for event in study_events), default=None),
            "nextDayOrSoonerCount": sum(event["trading_day_gap"] <= 1 for event in study_events),
            "within7Count": sum(event["trading_day_gap"] <= 7 for event in study_events),
        },
        "browseValidation": browse_validation,
        "repeatedPerfectSignatures": repeated_perfect,
        "repeatedHighRiskSignatures": repeated_high,
        "cleanNumericSeparations": clean_numeric,
        "earliestWindowShallowTree": {
            "generationWindow": "20170722",
            "maximumDepth": 2,
            "minimumLeaf": 3,
            "tree": shallow_tree,
            "highRiskGenerationLeaves": high_risk_leaves,
            "validatedSignatures": validated_tree_signatures,
        },
    }
    (args.output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    lines = [
        "# E-LC03-D0-E 第二次連續認賠進場特徵診斷",
        "",
        f"- Baseline：`{manifest['runID']}`",
        f"- Sample／資料規則：`{manifest['sampleID']}`／`{manifest['dataRuleVersion']}`",
        f"- 策略／commit：`{manifest['ruleVersion']}`／`{manifest['ruleCommit']}`",
        "- 事件定義：先前恰有一次連續自動認賠後的下一輪首次買入；更早已連續兩次以上者排除。",
        f"- 事件：{len(study_events)}；已結案 {len(completed)}（第二次認賠 {len(second_losses)}、非認賠 {len(recoveries)}）；期末截尾 {summary['censoredCount']}。",
        f"- 涵蓋：{summary['stockCount']} 檔、{summary['windowCount']} 個窗口；已結案第二次認賠率 {summary['secondLossRate']:.1%}。" if completed else "- 無已結案事件。",
        f"- 重新進場交易日間隔：中位 {summary['tradingDayGap']['median']}、範圍 {summary['tradingDayGap']['min']}～{summary['tradingDayGap']['max']}；7 日內 {summary['tradingDayGap']['within7Count']} 件。",
        f"- 賣出 ROI 重建核對：window 1 對 browse.store 共 {browse_validation['checked']} 件，正負號不一致 {browse_validation['sign_mismatches']}，最大 ROI 誤差 {browse_validation['max_abs_roi_difference']:.9f}。",
        f"- 進場技術值：同版 browse.store 補齊 {browse_validation['technicalEventsMatched']} 件，缺少 {browse_validation['technicalEventsMissing']} 件。",
        "",
        "## 跨股票、跨窗口的完整辨識",
        "",
    ]
    if repeated_perfect:
        lines.append("符合至少 3 件、2 檔、2 窗口且已觀察事件全部成為第二次認賠的組合：")
        lines.append("")
        for row in repeated_perfect:
            lines.append(
                f"- `{row['feature']}` = `{row['value']}`：{row['events']} 件，{row['stock_count']} 檔、{row['window_count']} 窗口。"
            )
    else:
        lines.append("沒有任何離散狀態、規則票、規則票配對或 Grade × 規則票，同時符合至少 3 件、2 檔、2 窗口且 100% 第二次認賠。")
    lines.extend(["", "## 高風險但非完整辨識", ""])
    if repeated_high:
        for row in repeated_high:
            lines.append(
                f"- `{row['feature']}` = `{row['value']}`：{row['second_losses']}/{row['events']}（{row['second_loss_rate']:.1%}），{row['stock_count']} 檔、{row['window_count']} 窗口。"
            )
    else:
        lines.append("沒有至少 4 件、2 檔、2 窗口且第二次認賠率達 75% 的離散或規則組合。")
    lines.extend(["", "## 連續數值", ""])
    if clean_numeric:
        for row in clean_numeric:
            lines.append(
                f"- `{row['feature']}`：{row['clean_separation']}；第二次認賠範圍 {row['second_loss_min']:.6f}～{row['second_loss_max']:.6f}，非認賠 {row['recovery_min']:.6f}～{row['recovery_max']:.6f}。"
            )
    else:
        lines.append("全部比較的決策前連續數值在第二次認賠與非認賠之間都有重疊，沒有單一乾淨分界。")
    lines.extend(["", "## 最早窗口生成、後兩窗口驗證的淺層組合", ""])
    if high_risk_leaves:
        for leaf in high_risk_leaves:
            validation_rate = (
                f"{leaf['validationSecondLossRate']:.1%}" if leaf["validationSecondLossRate"] is not None else "無事件"
            )
            lines.append(
                f"- `{leaf['conditionText']}`：2017 生成窗 {leaf['secondLosses']}/{leaf['events']}；"
                f"2020／2023 驗證 {leaf['validationSecondLosses']}/{leaf['validationEvents']}（{validation_rate}），"
                f"{len(leaf['validationStocks'])} 檔、{len(leaf['validationWindows'])} 窗口。"
            )
    else:
        lines.append("最早窗口沒有至少 3 件且第二次認賠率達 50% 的兩層以內連續數值組合。")
    if validated_tree_signatures:
        lines.append("")
        lines.append("其中有組合通過後兩窗口至少 4 件、2 檔、兩窗口且認賠率至少 75% 的驗證條件。")
    else:
        lines.append("")
        lines.append("沒有任何最早窗口生成的兩層組合通過後兩窗口驗證條件。")
    lines.extend(
        [
            "",
            "## 邊界",
            "",
            "- 第二次認賠標籤只用於事後診斷；任何正式候選都只能使用買入當下已知特徵。",
            "- 期末未結案事件保留但不當成非認賠。",
            "- 離散組合只使用既有 Grade、趨勢、決策 margin、規則票及有語意的前次認賠分段；不做任意數字網格。",
        ]
    )
    (args.output / "report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
