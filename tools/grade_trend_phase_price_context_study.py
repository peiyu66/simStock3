#!/usr/bin/env python3
"""GT-P07-D0: relate S33 Grade-trend subphases to later price context.

This is an observational event study. It does not change a trading rule,
rebuild a Baseline, or claim that a phase transition causes a price move.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import sqlite3
import statistics
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


CORE_DATA_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)
MINIMUM_OBSERVATIONS = 125
MINIMUM_INTERVAL_DAYS = 4
HORIZONS = (1, 3, 5, 10, 20)

IMPROVING_PROBING_TOP = 8
IMPROVING_PULLBACK = 9
WORSENING_PROBING_BOTTOM = 10
WORSENING_REBOUND = 11

PHASE_NAMES = {
    IMPROVING_PROBING_TOP: "改善探頂",
    IMPROVING_PULLBACK: "改善拉回",
    WORSENING_PROBING_BOTTOM: "惡化探底",
    WORSENING_REBOUND: "惡化反彈",
}

TRANSITIONS = {
    (WORSENING_PROBING_BOTTOM, WORSENING_REBOUND): {
        "id": "worsening_rebound",
        "name": "探底轉反彈",
        "expected_direction": 1,
    },
    (WORSENING_REBOUND, WORSENING_PROBING_BOTTOM): {
        "id": "worsening_reprobe",
        "name": "反彈重回探底",
        "expected_direction": -1,
    },
    (IMPROVING_PROBING_TOP, IMPROVING_PULLBACK): {
        "id": "improving_pullback",
        "name": "探頂轉拉回",
        "expected_direction": -1,
    },
    (IMPROVING_PULLBACK, IMPROVING_PROBING_TOP): {
        "id": "improving_retop",
        "name": "拉回重回探頂",
        "expected_direction": 1,
    },
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--sample",
        action="append",
        required=True,
        metavar="ID:DECISIONS_SQLITE:PRICE_STORE",
    )
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args()


def parse_sample(value: str) -> tuple[str, Path, Path]:
    parts = value.split(":", 2)
    if len(parts) != 3:
        raise ValueError(f"invalid --sample: {value}")
    return parts[0].upper(), Path(parts[1]), Path(parts[2])


def ensure_integrity(connection: sqlite3.Connection, label: str) -> None:
    result = connection.execute("PRAGMA integrity_check").fetchone()[0]
    if result != "ok":
        raise RuntimeError(f"{label} integrity_check failed: {result}")


def ymd_from_core_data(value: float) -> int:
    return int((CORE_DATA_EPOCH + timedelta(seconds=value)).strftime("%Y%m%d"))


def mean_or_none(values: list[float]) -> float | None:
    return statistics.fmean(values) if values else None


def median_or_none(values: list[float]) -> float | None:
    return statistics.median(values) if values else None


def percent(numerator: int, denominator: int) -> float | None:
    return numerator / denominator * 100.0 if denominator else None


def rounded(value: Any, digits: int = 6) -> Any:
    if isinstance(value, float):
        if not math.isfinite(value):
            return None
        return round(value, digits)
    return value


def load_decision_base(
    sample: str, database: Path
) -> tuple[list[dict[str, Any]], dict[tuple[int, str, int], set[str]], dict[str, str]]:
    connection = sqlite3.connect(database)
    connection.row_factory = sqlite3.Row
    try:
        ensure_integrity(connection, f"Sample {sample} DecisionBase")
        metadata = dict(connection.execute("SELECT key, value FROM metadata"))
        observations = [
            dict(row) | {"sample": sample}
            for row in connection.execute(
                """
                SELECT o.window_id, w.start_date AS window_start,
                       w.end_date AS window_end, s.stock_key, s.stock_id,
                       s.name AS stock_name, s.group_name, o.trade_date,
                       o.fit_trend, o.fit_trend_phase,
                       o.fit_trend_phase_extreme, o.fit_observation_count,
                       o.grade_name, o.is_valid, o.is_finite
                FROM strategy_fit_observations o
                JOIN windows w USING(window_id)
                JOIN stocks s USING(stock_key)
                ORDER BY o.window_id, s.stock_id, o.trade_date
                """
            )
        ]
        vote_rows = connection.execute(
            """
            SELECT e.window_id, s.stock_id, e.trade_date, r.rule_id
            FROM decision_events e
            JOIN stocks s USING(stock_key)
            JOIN event_votes v USING(event_id)
            JOIN rules r USING(rule_key)
            GROUP BY e.window_id, s.stock_id, e.trade_date, r.rule_id
            ORDER BY e.window_id, s.stock_id, e.trade_date, r.rule_id
            """
        ).fetchall()
    finally:
        connection.close()

    votes: dict[tuple[int, str, int], set[str]] = defaultdict(set)
    for row in vote_rows:
        votes[(row["window_id"], row["stock_id"], row["trade_date"])].add(
            row["rule_id"]
        )
    return observations, votes, metadata


def load_prices(store: Path) -> dict[str, tuple[list[int], list[float], dict[int, int]]]:
    connection = sqlite3.connect(store)
    connection.row_factory = sqlite3.Row
    try:
        ensure_integrity(connection, f"{store.name}")
        rows = connection.execute(
            """
            SELECT s.ZSID AS stock_id, t.ZDATETIME AS timestamp,
                   t.ZPRICECLOSE AS close
            FROM ZTRADE t JOIN ZSTOCK s ON s.Z_PK = t.ZSTOCK
            WHERE t.ZDATASOURCE = 'TWSE'
              AND t.ZPRICECLOSE IS NOT NULL AND t.ZPRICECLOSE > 0
            ORDER BY s.ZSID, t.ZDATETIME
            """
        ).fetchall()
    finally:
        connection.close()

    grouped: dict[str, list[tuple[int, float]]] = defaultdict(list)
    for row in rows:
        grouped[str(row["stock_id"])].append(
            (ymd_from_core_data(row["timestamp"]), float(row["close"]))
        )
    output = {}
    for stock_id, values in grouped.items():
        dates = [item[0] for item in values]
        if len(dates) != len(set(dates)):
            raise RuntimeError(f"duplicate TWSE dates for {stock_id} in {store}")
        closes = [item[1] for item in values]
        output[stock_id] = (dates, closes, {date: index for index, date in enumerate(dates)})
    return output


def valid_observation(row: dict[str, Any]) -> bool:
    return (
        row["is_valid"] == 1
        and row["is_finite"] == 1
        and row["fit_trend"] is not None
        and row["fit_observation_count"] >= MINIMUM_OBSERVATIONS
        and row["fit_trend_phase"] in PHASE_NAMES
    )


def group_observations(
    observations: list[dict[str, Any]],
) -> dict[tuple[str, int, str], list[dict[str, Any]]]:
    grouped: dict[tuple[str, int, str], list[dict[str, Any]]] = defaultdict(list)
    for row in observations:
        grouped[(row["sample"], row["window_id"], row["stock_id"])].append(row)
    return grouped


def add_forward_price_metrics(
    event: dict[str, Any],
    context: tuple[list[int], list[float], dict[int, int]],
) -> bool:
    dates, closes, indexes = context
    index = indexes.get(event["trade_date"])
    if index is None:
        return False
    close = closes[index]
    event["close"] = close
    for horizon in HORIZONS:
        key = f"return_{horizon}d_pct"
        if index + horizon < len(closes):
            event[key] = (closes[index + horizon] / close - 1.0) * 100.0
            event[f"aligned_{horizon}d_pct"] = (
                event[key] * event["expected_direction"]
            )
        else:
            event[key] = None
            event[f"aligned_{horizon}d_pct"] = None
    future = closes[index + 1 : min(index + 21, len(closes))]
    event["mfe_20d_pct"] = (max(future) / close - 1.0) * 100.0 if future else None
    event["mae_20d_pct"] = (min(future) / close - 1.0) * 100.0 if future else None
    event["price_index"] = index
    event["price_year"] = event["trade_date"] // 10000
    return True


def build_transition_events(
    grouped: dict[tuple[str, int, str], list[dict[str, Any]]],
    prices_by_sample: dict[str, dict[str, tuple[list[int], list[float], dict[int, int]]]],
    votes_by_sample: dict[str, dict[tuple[int, str, int], set[str]]],
) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    for (sample, window_id, stock_id), rows in grouped.items():
        previous: dict[str, Any] | None = None
        sequence = 0
        for row in rows:
            if not valid_observation(row):
                previous = None
                continue
            if previous is None:
                previous = row
                continue
            definition = TRANSITIONS.get(
                (previous["fit_trend_phase"], row["fit_trend_phase"])
            )
            if definition is not None:
                sequence += 1
                event = {
                    "study_id": "GT-P07-D0",
                    "event_id": f"{sample}-{window_id}-{stock_id}-{sequence}",
                    "sample": sample,
                    "window_id": window_id,
                    "window_start": row["window_start"],
                    "window_end": row["window_end"],
                    "stock_id": stock_id,
                    "stock_name": row["stock_name"],
                    "group_name": row["group_name"],
                    "trade_date": row["trade_date"],
                    "grade_name": row["grade_name"],
                    "from_phase": PHASE_NAMES[previous["fit_trend_phase"]],
                    "to_phase": PHASE_NAMES[row["fit_trend_phase"]],
                    "transition_id": definition["id"],
                    "transition_name": definition["name"],
                    "expected_direction": definition["expected_direction"],
                    "previous_fit_trend": previous["fit_trend"],
                    "fit_trend": row["fit_trend"],
                    "fit_trend_change": row["fit_trend"] - previous["fit_trend"],
                    "fit_trend_phase_extreme": row["fit_trend_phase_extreme"],
                    "rule_ids": sorted(
                        votes_by_sample[sample].get(
                            (window_id, stock_id, row["trade_date"]), set()
                        )
                    ),
                }
                context = prices_by_sample[sample].get(stock_id)
                if context is not None and add_forward_price_metrics(event, context):
                    events.append(event)
            previous = row
    return events


def build_interval_events(
    grouped: dict[tuple[str, int, str], list[dict[str, Any]]],
    prices_by_sample: dict[str, dict[str, tuple[list[int], list[float], dict[int, int]]]],
) -> tuple[list[dict[str, Any]], Counter[str]]:
    events: list[dict[str, Any]] = []
    counters: Counter[str] = Counter()
    definitions = {
        "worsening": {
            "start_phase": WORSENING_PROBING_BOTTOM,
            "turn_phase": WORSENING_REBOUND,
            "name": "惡化確認至首次反彈",
            "extreme": "low",
        },
        "improving": {
            "start_phase": IMPROVING_PROBING_TOP,
            "turn_phase": IMPROVING_PULLBACK,
            "name": "改善確認至首次拉回",
            "extreme": "high",
        },
    }
    for (sample, window_id, stock_id), rows in grouped.items():
        for direction, definition in definitions.items():
            active: dict[str, Any] | None = None
            previous_phase: int | None = None
            sequence = 0
            for row in rows:
                if not valid_observation(row):
                    if active is not None:
                        counters[f"{direction}_censored"] += 1
                    active = None
                    previous_phase = None
                    continue
                phase = row["fit_trend_phase"]
                family = {definition["start_phase"], definition["turn_phase"]}
                if active is None:
                    if phase == definition["start_phase"] and previous_phase not in family:
                        sequence += 1
                        active = {
                            "study_id": "GT-P07-D0",
                            "interval_id": f"{sample}-{direction}-{window_id}-{stock_id}-{sequence}",
                            "sample": sample,
                            "window_id": window_id,
                            "window_start": row["window_start"],
                            "window_end": row["window_end"],
                            "stock_id": stock_id,
                            "stock_name": row["stock_name"],
                            "group_name": row["group_name"],
                            "direction": direction,
                            "interval_name": definition["name"],
                            "extreme_kind": definition["extreme"],
                            "start_date": row["trade_date"],
                            "start_fit_trend": row["fit_trend"],
                        }
                    previous_phase = phase
                    continue
                if phase == definition["turn_phase"]:
                    active["turn_date"] = row["trade_date"]
                    active["turn_fit_trend"] = row["fit_trend"]
                    attached = attach_interval_price_metrics(
                        active, prices_by_sample[sample].get(stock_id)
                    )
                    if attached is not None:
                        events.append(attached)
                    else:
                        counters[f"{direction}_missing_price"] += 1
                    active = None
                elif phase != definition["start_phase"]:
                    counters[f"{direction}_left_before_turn"] += 1
                    active = None
                previous_phase = phase
            if active is not None:
                counters[f"{direction}_censored"] += 1
    return events, counters


def attach_interval_price_metrics(
    event: dict[str, Any],
    context: tuple[list[int], list[float], dict[int, int]] | None,
) -> dict[str, Any] | None:
    if context is None:
        return None
    dates, closes, indexes = context
    start = indexes.get(event["start_date"])
    turn = indexes.get(event["turn_date"])
    if start is None or turn is None or turn <= start:
        return None
    end = turn - 1
    interval = closes[start : end + 1]
    if not interval:
        return None
    extreme = min(interval) if event["extreme_kind"] == "low" else max(interval)
    tied = [offset for offset, close in enumerate(interval) if close == extreme]
    denominator = max(end - start, 1)
    start_close = closes[start]
    event |= {
        "interval_end_date": dates[end],
        "turn_close": closes[turn],
        "start_close": start_close,
        "trading_day_count": len(interval),
        "is_primary_duration": len(interval) >= MINIMUM_INTERVAL_DAYS,
        "extreme_close": extreme,
        "extreme_first_date": dates[start + tied[0]],
        "extreme_last_date": dates[start + tied[-1]],
        "extreme_tie_day_count": len(tied),
        "extreme_first_position": tied[0] / denominator,
        "extreme_last_position": tied[-1] / denominator,
        "extreme_return_from_start_pct": (extreme / start_close - 1.0) * 100.0,
        "turn_return_from_start_pct": (closes[turn] / start_close - 1.0) * 100.0,
    }
    return event


def match_controls(
    events: list[dict[str, Any]],
    grouped: dict[tuple[str, int, str], list[dict[str, Any]]],
    prices_by_sample: dict[str, dict[str, tuple[list[int], list[float], dict[int, int]]]],
) -> None:
    transition_dates = {
        (event["sample"], event["window_id"], event["stock_id"], event["trade_date"])
        for event in events
    }
    candidates: dict[tuple[str, int, str, int, str], list[dict[str, Any]]] = defaultdict(list)
    for (sample, window_id, stock_id), rows in grouped.items():
        context = prices_by_sample[sample].get(stock_id)
        if context is None:
            continue
        for row in rows:
            if not valid_observation(row):
                continue
            if (sample, window_id, stock_id, row["trade_date"]) in transition_dates:
                continue
            control = {
                "trade_date": row["trade_date"],
                "expected_direction": 1,
            }
            if not add_forward_price_metrics(control, context):
                continue
            candidates[
                (sample, window_id, stock_id, row["trade_date"] // 10000, row["grade_name"])
            ].append(control)

    used: dict[str, set[tuple[str, int, str, int]]] = defaultdict(set)
    for event in sorted(events, key=lambda item: (item["transition_id"], item["sample"], item["trade_date"])):
        key = (
            event["sample"],
            event["window_id"],
            event["stock_id"],
            event["price_year"],
            event["grade_name"],
        )
        choices = [
            row for row in candidates.get(key, [])
            if (
                event["sample"], event["window_id"], event["stock_id"], row["trade_date"]
            ) not in used[event["transition_id"]]
        ]
        if not choices:
            event["control_date"] = None
            continue
        control = min(choices, key=lambda item: (abs(item["trade_date"] - event["trade_date"]), item["trade_date"]))
        used[event["transition_id"]].add(
            (event["sample"], event["window_id"], event["stock_id"], control["trade_date"])
        )
        event["control_date"] = control["trade_date"]
        for horizon in HORIZONS:
            value = control[f"return_{horizon}d_pct"]
            event[f"control_return_{horizon}d_pct"] = value
            event[f"control_aligned_{horizon}d_pct"] = (
                value * event["expected_direction"] if value is not None else None
            )


def aggregate_intervals(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    output: list[dict[str, Any]] = []
    scopes = [("ALL", events)] + [
        (sample, [event for event in events if event["sample"] == sample])
        for sample in sorted({event["sample"] for event in events})
    ]
    for scope, scoped in scopes:
        for direction in ("worsening", "improving"):
            rows = [event for event in scoped if event["direction"] == direction]
            primary = [event for event in rows if event["is_primary_duration"]]
            positions = [event["extreme_first_position"] for event in primary]
            last_positions = [event["extreme_last_position"] for event in primary]
            output.append(
                {
                    "scope": scope,
                    "direction": direction,
                    "interval_name": rows[0]["interval_name"] if rows else None,
                    "event_count": len(rows),
                    "primary_event_count": len(primary),
                    "short_event_count": len(rows) - len(primary),
                    "median_trading_day_count": median_or_none([event["trading_day_count"] for event in primary]),
                    "median_extreme_first_position": median_or_none(positions),
                    "median_extreme_last_position": median_or_none(last_positions),
                    "extreme_first_in_first_half_rate_pct": percent(sum(value < 0.5 for value in positions), len(positions)),
                    "extreme_first_in_first_quarter_rate_pct": percent(sum(value < 0.25 for value in positions), len(positions)),
                    "extreme_first_in_last_quarter_rate_pct": percent(sum(value >= 0.75 for value in positions), len(positions)),
                    "mean_extreme_return_from_start_pct": mean_or_none([event["extreme_return_from_start_pct"] for event in primary]),
                    "median_extreme_return_from_start_pct": median_or_none([event["extreme_return_from_start_pct"] for event in primary]),
                    "mean_turn_return_from_start_pct": mean_or_none([event["turn_return_from_start_pct"] for event in primary]),
                }
            )
    return output


def interval_buckets(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    output = []
    buckets = (("Q1", 0.0, 0.25), ("Q2", 0.25, 0.5), ("Q3", 0.5, 0.75), ("Q4", 0.75, 1.0000001))
    for scope in ("ALL", "A", "B"):
        scoped = events if scope == "ALL" else [event for event in events if event["sample"] == scope]
        for direction in ("worsening", "improving"):
            rows = [event for event in scoped if event["direction"] == direction and event["is_primary_duration"]]
            for bucket, low, high in buckets:
                count = sum(low <= event["extreme_first_position"] < high for event in rows)
                output.append(
                    {
                        "scope": scope,
                        "direction": direction,
                        "bucket": bucket,
                        "count": count,
                        "rate_pct": percent(count, len(rows)),
                    }
                )
    return output


def aggregate_transitions(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    output = []
    scopes = [("ALL", events)] + [
        (sample, [event for event in events if event["sample"] == sample])
        for sample in sorted({event["sample"] for event in events})
    ]
    for scope, scoped in scopes:
        for transition_id in sorted({event["transition_id"] for event in events}):
            transition_rows = [event for event in scoped if event["transition_id"] == transition_id]
            for horizon in HORIZONS:
                rows = [event for event in transition_rows if event[f"aligned_{horizon}d_pct"] is not None]
                paired = [event for event in rows if event.get(f"control_aligned_{horizon}d_pct") is not None]
                aligned = [event[f"aligned_{horizon}d_pct"] for event in rows]
                raw = [event[f"return_{horizon}d_pct"] for event in rows]
                control = [event[f"control_aligned_{horizon}d_pct"] for event in paired]
                edges = [
                    event[f"aligned_{horizon}d_pct"] - event[f"control_aligned_{horizon}d_pct"]
                    for event in paired
                ]
                output.append(
                    {
                        "scope": scope,
                        "transition_id": transition_id,
                        "transition_name": transition_rows[0]["transition_name"] if transition_rows else None,
                        "horizon": horizon,
                        "event_count": len(rows),
                        "matched_control_count": len(paired),
                        "mean_raw_return_pct": mean_or_none(raw),
                        "median_raw_return_pct": median_or_none(raw),
                        "mean_aligned_return_pct": mean_or_none(aligned),
                        "median_aligned_return_pct": median_or_none(aligned),
                        "aligned_hit_rate_pct": percent(sum(value > 0 for value in aligned), len(aligned)),
                        "control_mean_aligned_return_pct": mean_or_none(control),
                        "paired_mean_edge_pct": mean_or_none(edges),
                        "paired_median_edge_pct": median_or_none(edges),
                    }
                )
    return output


def concentration_rows(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    output = []
    for sample in sorted({event["sample"] for event in events}):
        for transition_id in sorted({event["transition_id"] for event in events}):
            rows = [event for event in events if event["sample"] == sample and event["transition_id"] == transition_id]
            stock_counts = Counter(event["stock_id"] for event in rows)
            window_counts = Counter(str(event["window_start"]) for event in rows)
            grade_counts = Counter(event["grade_name"] for event in rows)
            group_counts = Counter(event["group_name"] for event in rows)
            for dimension, counts in (
                ("stock", stock_counts),
                ("window", window_counts),
                ("grade", grade_counts),
                ("group", group_counts),
            ):
                for value, count in counts.most_common():
                    output.append(
                        {
                            "sample": sample,
                            "transition_id": transition_id,
                            "dimension": dimension,
                            "value": value,
                            "event_count": count,
                            "share_pct": percent(count, len(rows)),
                        }
                    )
    return output


def rule_overlap_rows(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    output = []
    for sample in ("ALL", "A", "B"):
        scoped = events if sample == "ALL" else [event for event in events if event["sample"] == sample]
        for transition_id in sorted({event["transition_id"] for event in events}):
            rows = [event for event in scoped if event["transition_id"] == transition_id]
            counts: Counter[str] = Counter()
            for event in rows:
                counts.update(set(event["rule_ids"]))
            for rule_id, count in counts.most_common():
                output.append(
                    {
                        "scope": sample,
                        "transition_id": transition_id,
                        "transition_name": rows[0]["transition_name"] if rows else None,
                        "rule_id": rule_id,
                        "event_count": count,
                        "transition_event_count": len(rows),
                        "coverage_pct": percent(count, len(rows)),
                    }
                )
    return output


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    fields = list(rows[0])
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        for row in rows:
            writer.writerow({field: rounded(row.get(field)) for field in fields})


def serializable_event(event: dict[str, Any]) -> dict[str, Any]:
    return {
        key: ";".join(value) if key == "rule_ids" else rounded(value)
        for key, value in event.items()
        if key != "price_index"
    }


def format_value(value: Any, digits: int = 3) -> str:
    if value is None:
        return "-"
    if isinstance(value, float):
        return f"{value:.{digits}f}"
    return str(value)


def markdown_table(rows: list[dict[str, Any]], columns: list[tuple[str, str]]) -> str:
    header = "| " + " | ".join(label for _, label in columns) + " |"
    separator = "|" + "|".join("---" for _ in columns) + "|"
    body = [
        "| " + " | ".join(format_value(row.get(key)) for key, _ in columns) + " |"
        for row in rows
    ]
    return "\n".join([header, separator, *body])


def build_report(
    interval_aggregate: list[dict[str, Any]],
    transition_aggregate: list[dict[str, Any]],
    concentration: list[dict[str, Any]],
    rule_overlap: list[dict[str, Any]],
    counters: Counter[str],
) -> str:
    position_rows = [row for row in interval_aggregate if row["scope"] in ("A", "B")]
    response_rows = [
        row for row in transition_aggregate
        if row["scope"] in ("A", "B") and row["horizon"] in (5, 20)
    ]
    concentration_rows_ = [
        row for row in concentration
        if row["dimension"] in ("stock", "window") and row["share_pct"] is not None
    ]
    highest_concentration = sorted(
        concentration_rows_, key=lambda row: (-row["share_pct"], row["sample"], row["transition_id"])
    )[:12]
    trend_rules = {"S-P07", "S-N05", "H-N01a", "H-N11", "A-P05", "L-N02", "L-P10"}
    trend_rule_rows = [
        row for row in rule_overlap
        if row["scope"] in ("A", "B") and row["rule_id"] in trend_rules
    ]
    return f"""# GT-P07-D0 Grade 趨勢分段與價格時序

## 研究界線

- 正式基準：Baseline v14、`T2/S33`、策略 S26；只讀 Sample A／B 固定三年 DecisionBase v6 與 TWSE 收盤價。
- 這是歷史關聯研究，不是候選回測。轉段日只由當日以前的 S33 狀態辨識；轉段後價格只作結果統計。
- 價格極值位置以確認起點為 `0`、首次轉段前一日為 `1`；至少 {MINIMUM_INTERVAL_DAYS} 個交易日才納入主要位置統計。
- 四種轉段的方向對齊只是檢驗假設：反彈／重回探頂視為正向，重回探底／拉回視為負向。

## 價格極值位置

{markdown_table(position_rows, [("scope", "Sample"), ("interval_name", "區間"), ("primary_event_count", "主要事件"), ("median_trading_day_count", "日數中位"), ("median_extreme_first_position", "極值位置中位"), ("extreme_first_in_first_half_rate_pct", "前半比例%"), ("extreme_first_in_first_quarter_rate_pct", "首季比例%"), ("mean_extreme_return_from_start_pct", "極值平均變化%")])}

## 轉段後價格反應

{markdown_table(response_rows, [("scope", "Sample"), ("transition_name", "轉段"), ("horizon", "日數"), ("event_count", "事件"), ("median_raw_return_pct", "原始報酬中位%"), ("aligned_hit_rate_pct", "假設方向命中%"), ("paired_mean_edge_pct", "相對配對日平均差%")])}

## 最高集中度

{markdown_table(highest_concentration, [("sample", "Sample"), ("transition_id", "轉段"), ("dimension", "維度"), ("value", "值"), ("event_count", "事件"), ("share_pct", "占比%")])}

## 已採用趨勢規則共現

{markdown_table(trend_rule_rows, [("scope", "Sample"), ("transition_name", "轉段"), ("rule_id", "規則代號"), ("event_count", "共現事件"), ("transition_event_count", "轉段事件"), ("coverage_pct", "涵蓋率%")]) if trend_rule_rows else '沒有轉段日與已採用趨勢規則的非零票共現。'}

## 截尾與資料狀態

```json
{json.dumps(dict(counters), ensure_ascii=False, indent=2)}
```

## 判讀原則

只有 A／B 的極值位置偏向與轉段後方向同時一致，且不是由單股或單一窗口主導，才值得提出特定既有規則的情境候選。若 A／B 方向相反、命中率接近 50%、相對配對日差接近 0，或只剩規則共現，則停在描述用途，不修改正式規則。
"""


def main() -> None:
    args = parse_args()
    specs = [parse_sample(value) for value in args.sample]
    if {sample for sample, _, _ in specs} != {"A", "B"}:
        raise RuntimeError("GT-P07-D0 requires exactly Sample A and B")

    all_observations: list[dict[str, Any]] = []
    prices_by_sample = {}
    votes_by_sample = {}
    metadata_by_sample = {}
    sources = []
    for sample, database, store in specs:
        observations, votes, metadata = load_decision_base(sample, database)
        if metadata.get("dataRuleVersion") != "T2/S33":
            raise RuntimeError(f"Sample {sample} is not T2/S33")
        if metadata.get("formatVersion") != "6":
            raise RuntimeError(f"Sample {sample} is not DecisionBase v6")
        all_observations.extend(observations)
        votes_by_sample[sample] = votes
        metadata_by_sample[sample] = metadata
        prices_by_sample[sample] = load_prices(store)
        sources.append(
            {
                "sample": sample,
                "decision_base": str(database),
                "decision_base_id": metadata.get("decisionBaseID"),
                "price_store": str(store),
            }
        )

    grouped = group_observations(all_observations)
    transitions = build_transition_events(grouped, prices_by_sample, votes_by_sample)
    intervals, counters = build_interval_events(grouped, prices_by_sample)
    match_controls(transitions, grouped, prices_by_sample)

    interval_aggregate = aggregate_intervals(intervals)
    buckets = interval_buckets(intervals)
    transition_aggregate = aggregate_transitions(transitions)
    concentration = concentration_rows(transitions)
    rule_overlap = rule_overlap_rows(transitions)

    args.output.mkdir(parents=True, exist_ok=True)
    write_csv(args.output / "interval-events.csv", [serializable_event(event) for event in intervals])
    write_csv(args.output / "interval-aggregate.csv", interval_aggregate)
    write_csv(args.output / "interval-buckets.csv", buckets)
    write_csv(args.output / "transition-events.csv", [serializable_event(event) for event in transitions])
    write_csv(args.output / "transition-aggregate.csv", transition_aggregate)
    write_csv(args.output / "concentration.csv", concentration)
    write_csv(args.output / "rule-overlap.csv", rule_overlap)

    summary = {
        "study_id": "GT-P07-D0",
        "baseline": "Baseline v14 / T2/S33 / S26",
        "hypothesis": "Price extremes tend to precede the first Grade-trend subphase turn, and online phase transitions may describe different later price-risk contexts",
        "changes_rule": False,
        "runs_candidate_backtest": False,
        "samples": ["A", "B"],
        "minimum_observation_count": MINIMUM_OBSERVATIONS,
        "minimum_interval_days": MINIMUM_INTERVAL_DAYS,
        "horizons": HORIZONS,
        "interval_event_count": len(intervals),
        "transition_event_count": len(transitions),
        "interval_aggregate": interval_aggregate,
        "transition_20d": [
            row for row in transition_aggregate
            if row["scope"] in ("A", "B") and row["horizon"] == 20
        ],
        "counters": dict(counters),
    }
    manifest = {
        "run_id": "gt-p07-d0-phase-price-context-ab-t2s33-20260828",
        "created_at": datetime.now().astimezone().isoformat(),
        "data_rule_version": "T2/S33",
        "strategy_rule_version": metadata_by_sample["A"].get("ruleVersion"),
        "rule_commit": metadata_by_sample["A"].get("ruleCommit"),
        "sources": sources,
        "output_files": [
            "summary.json", "manifest.json", "report.md",
            "interval-events.csv", "interval-aggregate.csv", "interval-buckets.csv",
            "transition-events.csv", "transition-aggregate.csv",
            "concentration.csv", "rule-overlap.csv", ".complete",
        ],
        "limitations": [
            "Observational association is not a counterfactual trading-rule result.",
            "Future prices label outcomes only and never participate in event classification.",
            "Matched controls use the same sample, stock, window, calendar year, and exact Grade.",
            "A and B are selected research samples and do not establish general validity.",
        ],
    }
    (args.output / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    (args.output / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    (args.output / "report.md").write_text(
        build_report(interval_aggregate, transition_aggregate, concentration, rule_overlap, counters),
        encoding="utf-8",
    )
    (args.output / ".complete").write_text("GT-P07-D0 complete\n", encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
