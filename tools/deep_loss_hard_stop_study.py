#!/usr/bin/env python3
"""Diagnose prolonged deep-loss holdings before proposing a hard-stop rule."""

from __future__ import annotations

import argparse
import csv
import json
import math
import sqlite3
import statistics
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Iterable


GRADE_NAMES = {-3: "damn", -2: "low", -1: "weak", 0: "none", 1: "fine", 2: "high", 3: "wow"}
TREND_NAMES = {
    0: "initial",
    1: "stable",
    2: "improving-warning",
    3: "worsening-warning",
    4: "improving-confirmed",
    5: "worsening-confirmed",
    6: "improving-returned",
    7: "worsening-returned",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--decision-base", type=Path, required=True)
    parser.add_argument("--browse-store", type=Path, required=True)
    parser.add_argument("--sample", required=True)
    parser.add_argument("--holding-days", type=float, default=180.0)
    parser.add_argument("--roi", type=float, default=-30.0)
    parser.add_argument("--cooldown-days", type=int, default=60)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def mean(values: Iterable[float | int | None]) -> float | None:
    items = [float(value) for value in values if value is not None and math.isfinite(float(value))]
    return round(statistics.fmean(items), 6) if items else None


def median(values: Iterable[float | int | None]) -> float | None:
    items = [float(value) for value in values if value is not None and math.isfinite(float(value))]
    return round(statistics.median(items), 6) if items else None


def percentage(part: int, total: int) -> float | None:
    return round(100.0 * part / total, 3) if total else None


def compound_return(changes: list[float]) -> float:
    factor = 1.0
    for change in changes:
        factor *= 1.0 + change / 100.0
    return 100.0 * (factor - 1.0)


def check_database(connection: sqlite3.Connection, path: Path) -> None:
    integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
    if integrity != "ok":
        raise RuntimeError(f"SQLite integrity failed for {path}: {integrity}")
    bad_status, money_lacked = connection.execute(
        """
        SELECT
          SUM(CASE WHEN status IS NOT NULL AND status NOT IN ('正常','completed','complete','ok') THEN 1 ELSE 0 END),
          SUM(CASE WHEN COALESCE(money_lacked, 0) != 0 THEN 1 ELSE 0 END)
        FROM period_outcomes
        """
    ).fetchone()
    if int(bad_status or 0) or int(money_lacked or 0):
        raise RuntimeError(
            f"Unsafe DecisionBase {path}: bad_status={bad_status}, money_lacked={money_lacked}"
        )


def load_rows(connection: sqlite3.Connection) -> list[sqlite3.Row]:
    return connection.execute(
        """
        SELECT
            e.event_id, e.window_id, e.stock_key, e.trade_date, e.phase,
            e.grade, e.decision_score, e.executed_action, e.inventory_before,
            e.unit_cost_before, e.unit_roi_before, e.holding_days_before, e.invest_times_before,
            e.roll_rounds_before, w.start_date AS window_start, w.end_date AS window_end,
            s.stock_id, s.name AS stock_name, s.group_name,
            sf.fit_trend_phase, sf.fit_trend
        FROM decision_events e
        JOIN windows w ON w.window_id = e.window_id
        JOIN stocks s ON s.stock_key = e.stock_key
        LEFT JOIN event_strategy_fit_observations esf ON esf.event_id = e.event_id
        LEFT JOIN strategy_fit_observations sf ON sf.observation_id = esf.observation_id
        WHERE e.phase IN (1, 2, 3, 4)
        ORDER BY e.window_id, e.stock_key, e.trade_date, e.phase
        """
    ).fetchall()


def load_prices(store: Path) -> dict[str, tuple[list[int], list[float]]]:
    connection = sqlite3.connect(f"file:{store}?mode=ro", uri=True)
    try:
        rows = connection.execute(
            """
            SELECT s.ZSID,
                CAST(strftime('%Y%m%d', datetime(t.ZDATETIME + 978307200, 'unixepoch')) AS INTEGER),
                t.ZPRICECLOSE
            FROM ZTRADE t
            JOIN ZSTOCK s ON s.Z_PK = t.ZSTOCK
            WHERE t.ZDATASOURCE = 'TWSE' AND t.ZPRICECLOSE > 0
            ORDER BY s.ZSID, t.ZDATETIME
            """
        ).fetchall()
    finally:
        connection.close()
    grouped: dict[str, list[tuple[int, float]]] = defaultdict(list)
    for stock_id, trade_date, close in rows:
        grouped[str(stock_id)].append((int(trade_date), float(close)))
    return {
        stock_id: ([date for date, _ in values], [close for _, close in values])
        for stock_id, values in grouped.items()
    }


def forward_return(
    prices: dict[str, tuple[list[int], list[float]]],
    stock_id: str,
    event_date: int,
    window_end: int,
    days: int,
) -> float | None:
    dates, closes = prices[stock_id]
    try:
        event_index = dates.index(event_date)
    except ValueError as error:
        raise RuntimeError(f"Missing price observation for stock_id={stock_id}, date={event_date}") from error
    end_index = event_index + days
    if end_index >= len(dates) or dates[end_index] > window_end:
        return None
    return round(100.0 * (closes[end_index] / closes[event_index] - 1.0), 6)


def return_to_date(
    prices: dict[str, tuple[list[int], list[float]]],
    stock_id: str,
    event_date: int,
    target_date: int,
) -> float:
    dates, closes = prices[stock_id]
    try:
        event_index = dates.index(event_date)
        target_index = dates.index(target_date)
    except ValueError as error:
        raise RuntimeError(
            f"Missing price observation for stock_id={stock_id}, event={event_date}, target={target_date}"
        ) from error
    return round(100.0 * (closes[target_index] / closes[event_index] - 1.0), 6)


def build_cases(
    rows: list[sqlite3.Row],
    prices: dict[str, tuple[list[int], list[float]]],
    holding_days: float,
    roi: float,
    cooldown_days: int,
) -> list[dict[str, Any]]:
    grouped: dict[tuple[int, int], list[sqlite3.Row]] = defaultdict(list)
    for row in rows:
        grouped[(int(row["window_id"]), int(row["stock_key"]))].append(row)

    cases: list[dict[str, Any]] = []
    for stock_rows in grouped.values():
        active = False
        candidate: dict[str, Any] | None = None
        sell_day_count = 0
        last_add_sell_day: int | None = None
        later_add_count = 0

        for row in stock_rows:
            if row["executed_action"] == "BUY" and float(row["inventory_before"]) == 0:
                active = True
                candidate = None
                sell_day_count = 0
                last_add_sell_day = None
                later_add_count = 0
                continue
            if not active:
                continue

            if int(row["phase"]) == 4 and row["executed_action"] == "ADD":
                last_add_sell_day = sell_day_count
                if candidate is not None:
                    later_add_count += 1
                continue
            if int(row["phase"]) != 3:
                continue

            sell_day_count += 1
            cooldown_passed = (
                last_add_sell_day is None or sell_day_count - last_add_sell_day >= cooldown_days
            )
            if (
                candidate is None
                and float(row["holding_days_before"]) > holding_days
                and float(row["unit_roi_before"]) <= roi
                and cooldown_passed
            ):
                event_date = int(row["trade_date"])
                candidate = {
                    "sample": "",
                    "window_start": int(row["window_start"]),
                    "window_end": int(row["window_end"]),
                    "stock_id": str(row["stock_id"]),
                    "stock_name": str(row["stock_name"]),
                    "group": str(row["group_name"]),
                    "round_before": int(float(row["roll_rounds_before"])),
                    "event_date": event_date,
                    "event_grade": GRADE_NAMES.get(int(row["grade"]), str(row["grade"])),
                    "event_trend_phase": TREND_NAMES.get(
                        int(row["fit_trend_phase"] or 0), str(row["fit_trend_phase"])
                    ),
                    "event_fit_trend": (
                        round(float(row["fit_trend"]), 6) if row["fit_trend"] is not None else None
                    ),
                    "event_roi": round(float(row["unit_roi_before"]), 6),
                    "event_holding_days": int(float(row["holding_days_before"])),
                    "event_invest_times": int(float(row["invest_times_before"])),
                    "event_score": round(float(row["decision_score"]), 6),
                    "days_since_add": (
                        sell_day_count - last_add_sell_day if last_add_sell_day is not None else None
                    ),
                    "forward_20_return": forward_return(
                        prices, str(row["stock_id"]), event_date, int(row["window_end"]), 20
                    ),
                    "forward_60_return": forward_return(
                        prices, str(row["stock_id"]), event_date, int(row["window_end"]), 60
                    ),
                    "event_sell_day_count": sell_day_count,
                }

            if row["executed_action"] != "SELL":
                continue

            if candidate is not None:
                sell_date = int(row["trade_date"])
                candidate.update(
                    {
                        "baseline_sell_date": sell_date,
                        "baseline_sell_roi": round(float(row["unit_roi_before"]), 6),
                        "trading_days_to_sell": sell_day_count - int(candidate["event_sell_day_count"]),
                        "price_return_to_sell": return_to_date(
                            prices, str(row["stock_id"]), int(candidate["event_date"]), sell_date
                        ),
                        "later_add_count": later_add_count,
                        "resolved": True,
                    }
                )
                cases.append(candidate)
            active = False
            candidate = None

        if active and candidate is not None:
            candidate.update(
                {
                    "baseline_sell_date": None,
                    "baseline_sell_roi": None,
                    "trading_days_to_sell": sell_day_count - int(candidate["event_sell_day_count"]),
                    "price_return_to_sell": None,
                    "later_add_count": later_add_count,
                    "resolved": False,
                }
            )
            cases.append(candidate)

    for case in cases:
        case["sample"] = ""
        case.pop("event_sell_day_count")
    return cases


def summarize(cases: list[dict[str, Any]], args: argparse.Namespace) -> dict[str, Any]:
    resolved = [case for case in cases if case["resolved"]]
    forward20 = [case["forward_20_return"] for case in cases if case["forward_20_return"] is not None]
    forward60 = [case["forward_60_return"] for case in cases if case["forward_60_return"] is not None]
    sell_returns = [case["price_return_to_sell"] for case in resolved]
    return {
        "study_id": "NR10-D0-C",
        "sample": args.sample,
        "decision_base": args.decision_base.name,
        "definition": {
            "holding_days_greater_than": args.holding_days,
            "roi_at_or_below": args.roi,
            "minimum_trading_days_since_add": args.cooldown_days,
            "deduplication": "first qualifying event per holding round",
        },
        "case_count": len(cases),
        "stock_count": len({case["stock_id"] for case in cases}),
        "window_count": len({case["window_start"] for case in cases}),
        "group_counts": dict(Counter(case["group"] for case in cases)),
        "grade_counts": dict(Counter(case["event_grade"] for case in cases)),
        "trend_phase_counts": dict(Counter(case["event_trend_phase"] for case in cases)),
        "mean_event_roi": mean(case["event_roi"] for case in cases),
        "resolved_count": len(resolved),
        "unresolved_count": len(cases) - len(resolved),
        "later_add_count": sum(1 for case in cases if case["later_add_count"] > 0),
        "mean_trading_days_to_sell": mean(case["trading_days_to_sell"] for case in cases),
        "forward_20": {
            "available": len(forward20),
            "mean_return": mean(forward20),
            "median_return": median(forward20),
            "hard_stop_price_better_count": sum(value <= 0 for value in forward20),
            "hard_stop_price_better_pct": percentage(sum(value <= 0 for value in forward20), len(forward20)),
        },
        "forward_60": {
            "available": len(forward60),
            "mean_return": mean(forward60),
            "median_return": median(forward60),
            "hard_stop_price_better_count": sum(value <= 0 for value in forward60),
            "hard_stop_price_better_pct": percentage(sum(value <= 0 for value in forward60), len(forward60)),
        },
        "baseline_sell": {
            "available": len(sell_returns),
            "mean_price_return": mean(sell_returns),
            "median_price_return": median(sell_returns),
            "hard_stop_price_better_count": sum(value <= 0 for value in sell_returns),
            "hard_stop_price_better_pct": percentage(
                sum(value <= 0 for value in sell_returns), len(sell_returns)
            ),
        },
    }


def write_outputs(cases: list[dict[str, Any]], summary: dict[str, Any], output: Path) -> None:
    output.mkdir(parents=True, exist_ok=True)
    with (output / "summary.json").open("w", encoding="utf-8") as handle:
        json.dump(summary, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")
    if cases:
        with (output / "cases.csv").open("w", encoding="utf-8", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(cases[0]))
            writer.writeheader()
            writer.writerows(cases)


def main() -> int:
    args = parse_args()
    database = args.decision_base / "decisions.sqlite"
    connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    try:
        check_database(connection, database)
        rows = load_rows(connection)
    finally:
        connection.close()
    prices = load_prices(args.browse_store)
    cases = build_cases(rows, prices, args.holding_days, args.roi, args.cooldown_days)
    for case in cases:
        case["sample"] = args.sample
    summary = summarize(cases, args)
    write_outputs(cases, summary, args.output)
    print(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
