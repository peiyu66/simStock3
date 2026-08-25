#!/usr/bin/env python3
"""Diagnose near-threshold sell opportunities after the final add-on.

NR3-D0 is diagnostic only. It does not replay or modify the formal strategy.
It locates the first post-final-add sell decision in each round where adding one
sell vote would newly satisfy one of the formal S-T01b...h exit routes.
"""

from __future__ import annotations

import argparse
import csv
import json
import sqlite3
import statistics
from collections import Counter, defaultdict
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Iterable


DEFAULT_BASES = {
    "A": "a-abcd9-v2-s24-sn05-wow-worsening-20260824-t2-s28-73003cf8f39c-fixed3y-20260722-v5",
    "B": "b-abcd9-v2-s24-sn05-wow-worsening-20260824-t2-s28-73003cf8f39c-fixed3y-20260722-v5",
}

GRADE_NAMES = {
    -3: "damn",
    -2: "low",
    -1: "weak",
    0: "none",
    1: "fine",
    2: "high",
    3: "wow",
}

TREND_PHASE_NAMES = {
    0: "initial",
    1: "stable",
    2: "improving-warning",
    3: "worsening-warning",
    4: "improving-confirmed",
    5: "worsening-confirmed",
    6: "improving-returned",
    7: "worsening-returned",
}


@dataclass
class Event:
    sample: str
    window_id: str
    window_start: str
    window_end: str
    stock_id: str
    stock_name: str
    group_name: str
    round_before: int
    final_add_date: str
    event_date: str
    grade: str
    fit_trend_phase: str
    fit_trend: float | None
    sell_score: int
    candidate_sell_score: int
    newly_opened_routes: str
    event_roi: float
    event_holding_days: int
    actual_sell_date: str
    actual_sell_roi: float | None
    wait_trading_days: int | None
    waiting_roi_delta: float | None
    minimum_roi_while_waiting: float | None
    maximum_roi_while_waiting: float | None
    censored: bool


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--project-root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
    )
    parser.add_argument("--samples", nargs="+", choices=sorted(DEFAULT_BASES), default=["A", "B"])
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def median(values: Iterable[float]) -> float | None:
    items = list(values)
    return statistics.median(items) if items else None


def mean(values: Iterable[float]) -> float | None:
    items = list(values)
    return statistics.fmean(items) if items else None


def rounded(value: float | None) -> float | None:
    return round(value, 6) if value is not None else None


def exit_routes(row: sqlite3.Row, score: int) -> set[str]:
    roi = float(row["unit_roi_before"])
    days = int(row["holding_days_before"])
    grade = int(row["grade"])
    k_z125 = row["kd_k_z125"]
    d_z125 = row["kd_d_z125"]
    routes: set[str] = set()

    if score >= 6 and roi > 0.45 and days > 1:
        routes.add("S-T01b")

    if grade <= -1:
        grade_roi_threshold = 1.5
    elif grade >= 3:
        grade_roi_threshold = 2.25
    else:
        grade_roi_threshold = 2.0
    if score >= 4 and roi > grade_roi_threshold:
        routes.add("S-T01c")

    technical_overheated = (
        (k_z125 is not None and float(k_z125) > 1.5)
        or (d_z125 is not None and float(d_z125) > 1.5)
    )
    if score >= 4 and roi > 3.5 and technical_overheated:
        routes.add("S-T01d")
    if score >= 4 and roi > 0.45 and days > 68:
        routes.add("S-T01e")

    if score >= 3 and roi > 15.5 and days < (60 if grade >= 2 else 40):
        routes.add("S-T01f")
    if score >= 3 and roi > 9.5 and days < (30 if grade >= 2 else 20):
        routes.add("S-T01g")
    if score >= 3 and roi > 6.5 and days < (45 if grade <= -1 else 10):
        routes.add("S-T01h")
    return routes


def load_rows(connection: sqlite3.Connection) -> list[sqlite3.Row]:
    return connection.execute(
        """
        SELECT
            e.event_id,
            e.window_id,
            e.stock_key,
            e.trade_date,
            e.phase,
            e.grade,
            e.decision_score,
            e.planned_action,
            e.executed_action,
            e.inventory_before,
            e.unit_roi_before,
            e.holding_days_before,
            e.invest_times_before,
            e.roll_rounds_before,
            w.start_date AS window_start,
            w.end_date AS window_end,
            s.stock_id,
            s.name AS stock_name,
            s.group_name,
            t.kd_k_z125,
            t.kd_d_z125,
            sf.fit_trend_phase,
            sf.fit_trend
        FROM decision_events e
        JOIN windows w ON w.window_id = e.window_id
        JOIN stocks s ON s.stock_key = e.stock_key
        LEFT JOIN event_observations eo ON eo.event_id = e.event_id
        LEFT JOIN technical_observations t ON t.observation_id = eo.observation_id
        LEFT JOIN event_strategy_fit_observations esf ON esf.event_id = e.event_id
        LEFT JOIN strategy_fit_observations sf ON sf.observation_id = esf.observation_id
        WHERE e.phase IN (3, 4)
        ORDER BY e.window_id, e.stock_key, e.roll_rounds_before, e.trade_date, e.phase
        """
    ).fetchall()


def check_database(connection: sqlite3.Connection, path: Path) -> None:
    integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
    if integrity != "ok":
        raise RuntimeError(f"SQLite integrity failed for {path}: {integrity}")

    bad_periods = connection.execute(
        """
        SELECT COUNT(*)
        FROM period_outcomes
        WHERE status IS NOT NULL AND status NOT IN ('正常', 'completed', 'complete', 'ok')
        """
    ).fetchone()[0]
    money_lacked = connection.execute(
        "SELECT COUNT(*) FROM period_outcomes WHERE COALESCE(money_lacked, 0) != 0"
    ).fetchone()[0]
    if bad_periods or money_lacked:
        raise RuntimeError(
            f"Unsafe DecisionBase {path}: bad_periods={bad_periods}, money_lacked={money_lacked}"
        )


def analyze_sample(sample: str, database: Path) -> tuple[list[Event], dict[str, int]]:
    uri = f"file:{database}?mode=ro"
    connection = sqlite3.connect(uri, uri=True)
    connection.row_factory = sqlite3.Row
    try:
        check_database(connection, database)
        rows = load_rows(connection)
    finally:
        connection.close()

    rounds: dict[tuple[Any, ...], list[sqlite3.Row]] = defaultdict(list)
    for row in rows:
        key = (row["window_id"], row["stock_key"], int(row["roll_rounds_before"]))
        rounds[key].append(row)

    funnel = Counter()
    events: list[Event] = []
    for round_rows in rounds.values():
        final_adds = [
            row
            for row in round_rows
            if row["phase"] == 4
            and row["executed_action"] == "ADD"
            and int(row["invest_times_before"]) >= 2
        ]
        if not final_adds:
            continue
        funnel["rounds_with_final_add"] += 1
        final_add = max(final_adds, key=lambda row: row["trade_date"])
        sell_rows = [
            row
            for row in round_rows
            if row["phase"] == 3 and row["trade_date"] > final_add["trade_date"]
        ]
        if not sell_rows:
            continue
        funnel["rounds_with_later_sell_observation"] += 1
        if any(float(row["unit_roi_before"]) >= 0 for row in sell_rows):
            funnel["rounds_ever_recovered"] += 1

        candidate_index: int | None = None
        newly_opened: set[str] = set()
        for index, row in enumerate(sell_rows):
            if row["executed_action"] == "SELL":
                break
            if row["executed_action"] not in ("NONE", "HOLD"):
                continue
            score = int(row["decision_score"])
            baseline_routes = exit_routes(row, score)
            candidate_routes = exit_routes(row, score + 1)
            delta = candidate_routes - baseline_routes
            if delta:
                candidate_index = index
                newly_opened = delta
                break

        if candidate_index is None:
            continue
        funnel["rounds_with_one_vote_short_event"] += 1
        event_row = sell_rows[candidate_index]
        later_sell_index = next(
            (
                index
                for index in range(candidate_index + 1, len(sell_rows))
                if sell_rows[index]["executed_action"] == "SELL"
            ),
            None,
        )
        path_end = later_sell_index if later_sell_index is not None else len(sell_rows) - 1
        path_rows = sell_rows[candidate_index : path_end + 1]
        path_rois = [float(row["unit_roi_before"]) for row in path_rows]
        actual_sell = sell_rows[later_sell_index] if later_sell_index is not None else None
        event_roi = float(event_row["unit_roi_before"])
        actual_sell_roi = float(actual_sell["unit_roi_before"]) if actual_sell else None

        events.append(
            Event(
                sample=sample,
                window_id=str(event_row["window_id"]),
                window_start=str(event_row["window_start"]),
                window_end=str(event_row["window_end"]),
                stock_id=str(event_row["stock_id"]),
                stock_name=str(event_row["stock_name"]),
                group_name=str(event_row["group_name"]),
                round_before=int(event_row["roll_rounds_before"]),
                final_add_date=str(final_add["trade_date"]),
                event_date=str(event_row["trade_date"]),
                grade=GRADE_NAMES.get(int(event_row["grade"]), str(event_row["grade"])),
                fit_trend_phase=TREND_PHASE_NAMES.get(
                    int(event_row["fit_trend_phase"]) if event_row["fit_trend_phase"] is not None else 0,
                    str(event_row["fit_trend_phase"]),
                ),
                fit_trend=(float(event_row["fit_trend"]) if event_row["fit_trend"] is not None else None),
                sell_score=int(event_row["decision_score"]),
                candidate_sell_score=int(event_row["decision_score"]) + 1,
                newly_opened_routes="+".join(sorted(newly_opened)),
                event_roi=event_roi,
                event_holding_days=int(event_row["holding_days_before"]),
                actual_sell_date=str(actual_sell["trade_date"]) if actual_sell else "",
                actual_sell_roi=actual_sell_roi,
                wait_trading_days=(later_sell_index - candidate_index if later_sell_index is not None else None),
                waiting_roi_delta=(actual_sell_roi - event_roi if actual_sell_roi is not None else None),
                minimum_roi_while_waiting=min(path_rois) if path_rois else None,
                maximum_roi_while_waiting=max(path_rois) if path_rois else None,
                censored=actual_sell is None,
            )
        )
    return events, dict(funnel)


def summarize(events: list[Event], funnels: dict[str, dict[str, int]]) -> dict[str, Any]:
    result: dict[str, Any] = {"funnels": funnels, "samples": {}, "breakdowns": {}}
    for sample in sorted(funnels):
        sample_events = [event for event in events if event.sample == sample]
        completed = [event for event in sample_events if not event.censored]
        deltas = [event.waiting_roi_delta for event in completed if event.waiting_roi_delta is not None]
        waits = [float(event.wait_trading_days) for event in completed if event.wait_trading_days is not None]
        drawdowns = [
            event.minimum_roi_while_waiting - event.event_roi
            for event in completed
            if event.minimum_roi_while_waiting is not None
        ]
        result["samples"][sample] = {
            "events": len(sample_events),
            "completed_later_sells": len(completed),
            "censored": len(sample_events) - len(completed),
            "stocks": len({event.stock_id for event in sample_events}),
            "windows": len({event.window_id for event in sample_events}),
            "mean_wait_trading_days": rounded(mean(waits)),
            "median_wait_trading_days": rounded(median(waits)),
            "mean_waiting_roi_delta": rounded(mean(value for value in deltas if value is not None)),
            "median_waiting_roi_delta": rounded(median(value for value in deltas if value is not None)),
            "waiting_improved_count": sum(1 for value in deltas if value is not None and value > 0),
            "waiting_worsened_count": sum(1 for value in deltas if value is not None and value < 0),
            "mean_interim_drawdown_from_event": rounded(mean(drawdowns)),
        }

    for field in ("grade", "fit_trend_phase", "newly_opened_routes", "group_name"):
        result["breakdowns"][field] = dict(sorted(Counter(getattr(event, field) for event in events).items()))
    return result


def write_outputs(
    output: Path,
    events: list[Event],
    summary: dict[str, Any],
    databases: dict[str, Path],
) -> None:
    output.mkdir(parents=True, exist_ok=True)
    event_rows = [asdict(event) for event in events]
    fields = list(Event.__dataclass_fields__)
    with (output / "events.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(event_rows)

    (output / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    manifest = {
        "study": "NR3-D0",
        "purpose": "diagnostic-only",
        "baseline": "v10",
        "data_rule_version": "T2/S28",
        "strategy_rule_version": "S24",
        "formal_rule_commit": "73003cf8f39cbf3a673792957324f508261bd731",
        "decision_bases": {sample: str(path) for sample, path in databases.items()},
        "event_definition": (
            "First post-final-add formal sell HOLD where adding one sell vote newly opens "
            "S-T01b...h; first event only per round."
        ),
    }
    (output / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    lines = [
        "# NR3-D0 最後加碼後回本近門檻診斷",
        "",
        "- 比較基準：Baseline v10（T2/S28，策略 S24）",
        "- 事件：每輪最後一次實際加碼後，正式規則尚未賣出，但賣出分數加 1 即首次開啟 S-T01b～h 出口。",
        "- 本研究只做事件診斷，未修改或重播正式規則。",
        "",
        "## 樣本摘要",
        "",
        "| 樣本 | 事件 | 後續正式賣出 | 截尾 | 平均等待交易日 | 平均等待報酬差 | 等待改善／惡化 |",
        "|---|---:|---:|---:|---:|---:|---:|",
    ]
    for sample, values in summary["samples"].items():
        lines.append(
            f"| {sample} | {values['events']} | {values['completed_later_sells']} | {values['censored']} | "
            f"{values['mean_wait_trading_days']} | {values['mean_waiting_roi_delta']} | "
            f"{values['waiting_improved_count']}／{values['waiting_worsened_count']} |"
        )
    lines.extend(["", "## 事件明細", ""])
    if not events:
        lines.append("沒有符合事件。")
    else:
        lines.extend(
            [
                "| 樣本 | 股票 | 窗口 | 事件日 | Grade | 趨勢 | 出口 | 事件 ROI | 正式賣出日 | 等待日 | 報酬差 |",
                "|---|---|---|---|---|---|---|---:|---|---:|---:|",
            ]
        )
        for event in events:
            lines.append(
                f"| {event.sample} | {event.stock_id} {event.stock_name} | {event.window_id} | "
                f"{event.event_date} | {event.grade} | {event.fit_trend_phase} | "
                f"{event.newly_opened_routes} | {event.event_roi:.3f} | "
                f"{event.actual_sell_date or '未賣'} | {event.wait_trading_days if event.wait_trading_days is not None else '-'} | "
                f"{event.waiting_roi_delta if event.waiting_roi_delta is not None else '-'} |"
            )
    (output / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    root = args.project_root.resolve()
    output = args.output or (
        root / "exports" / "final-add-recovery-study" / "nr3-d0-baseline-v10-t2s28-20260825"
    )
    databases = {
        sample: root / "exports" / "backtest-decision-bases" / DEFAULT_BASES[sample] / "decisions.sqlite"
        for sample in args.samples
    }
    missing = [str(path) for path in databases.values() if not path.is_file()]
    if missing:
        raise FileNotFoundError("Missing DecisionBase: " + ", ".join(missing))

    events: list[Event] = []
    funnels: dict[str, dict[str, int]] = {}
    for sample, database in databases.items():
        sample_events, sample_funnel = analyze_sample(sample, database)
        events.extend(sample_events)
        funnels[sample] = sample_funnel
    summary = summarize(events, funnels)
    write_outputs(output.resolve(), events, summary, databases)
    print(json.dumps({"output": str(output.resolve()), **summary}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
