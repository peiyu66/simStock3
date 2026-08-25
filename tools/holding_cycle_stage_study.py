#!/usr/bin/env python3
"""Split completed Baseline holding rounds into cycle stages for NR4-D0."""

from __future__ import annotations

import argparse
import csv
import json
import math
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


@dataclass
class Round:
    sample: str
    window_id: str
    window_start: str
    window_end: str
    stock_id: str
    stock_name: str
    group_name: str
    round_before: int
    buy_date: str
    sell_date: str
    holding_days: int
    sell_roi: float
    add_count: int
    final_add_date: str
    had_negative_after_anchor: bool
    recovery_date: str
    recovery_roi: float | None
    recovery_grade: str
    recovery_trend_phase: str
    buy_to_final_add_days: int | None
    buy_to_recovery_days: int | None
    final_add_to_recovery_days: int | None
    recovery_to_sell_days: int | None
    unrecovered_after_final_add_days: int | None
    dominant_stage: str
    dominant_stage_days: int
    long_tail: bool = False


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--samples", nargs="+", choices=sorted(DEFAULT_BASES), default=["A", "B"])
    parser.add_argument("--tail-ratio", type=float, default=0.20)
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def average(values: Iterable[float | int | None]) -> float | None:
    items = [float(value) for value in values if value is not None]
    return round(statistics.fmean(items), 6) if items else None


def percentage(part: int, total: int) -> float:
    return round(100.0 * part / total, 3) if total else 0.0


def load_rows(connection: sqlite3.Connection) -> list[sqlite3.Row]:
    return connection.execute(
        """
        SELECT
            e.event_id, e.window_id, e.stock_key, e.trade_date, e.phase,
            e.grade, e.decision_score, e.executed_action, e.inventory_before, e.unit_roi_before,
            e.holding_days_before, e.invest_times_before, e.roll_rounds_before,
            w.start_date AS window_start, w.end_date AS window_end,
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


def check_database(connection: sqlite3.Connection, path: Path) -> None:
    integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
    if integrity != "ok":
        raise RuntimeError(f"SQLite integrity failed for {path}: {integrity}")
    unsafe = connection.execute(
        """
        SELECT
          SUM(CASE WHEN status IS NOT NULL AND status NOT IN ('正常','completed','complete','ok') THEN 1 ELSE 0 END),
          SUM(CASE WHEN COALESCE(money_lacked, 0) != 0 THEN 1 ELSE 0 END)
        FROM period_outcomes
        """
    ).fetchone()
    if any(int(value or 0) for value in unsafe):
        raise RuntimeError(f"Unsafe DecisionBase {path}: bad_status={unsafe[0]}, money_lacked={unsafe[1]}")


def stage_count(sell_rows: list[sqlite3.Row], after_date: Any, through_date: Any) -> int:
    return sum(1 for row in sell_rows if row["trade_date"] > after_date and row["trade_date"] <= through_date)


def choose_dominant(stages: dict[str, int | None]) -> tuple[str, int]:
    available = [(name, int(value)) for name, value in stages.items() if value is not None]
    if not available:
        return "unclassified", 0
    return max(available, key=lambda item: (item[1], item[0]))


def build_rounds(sample: str, database: Path) -> list[Round]:
    connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    try:
        check_database(connection, database)
        rows = load_rows(connection)
    finally:
        connection.close()

    grouped: dict[tuple[Any, ...], list[sqlite3.Row]] = defaultdict(list)
    for row in rows:
        grouped[(row["window_id"], row["stock_key"])].append(row)

    completed: list[Round] = []
    for stock_rows in grouped.values():
        buy: sqlite3.Row | None = None
        adds: list[sqlite3.Row] = []
        sell_observations: list[sqlite3.Row] = []
        for row in stock_rows:
            if row["executed_action"] == "BUY" and float(row["inventory_before"]) == 0:
                if buy is not None:
                    raise RuntimeError(
                        f"Overlapping BUY in Sample {sample}, stock {row['stock_id']}, window {row['window_id']}"
                    )
                buy = row
                adds = []
                sell_observations = []
                continue
            if buy is None:
                continue
            if row["phase"] == 4 and row["executed_action"] == "ADD":
                adds.append(row)
                continue
            if row["phase"] != 3:
                continue
            sell_observations.append(row)
            if row["executed_action"] != "SELL":
                continue
            sell = row
            completed.append(build_round(sample, buy, sell, adds, sell_observations))
            buy = None
            adds = []
            sell_observations = []
    return completed


def build_round(
    sample: str,
    buy: sqlite3.Row,
    sell: sqlite3.Row,
    adds: list[sqlite3.Row],
    sell_observations: list[sqlite3.Row],
) -> Round:
        final_add = max(adds, key=lambda row: row["trade_date"]) if adds else None
        recovery_anchor = final_add["trade_date"] if final_add else buy["trade_date"]
        anchor_observations = [row for row in sell_observations if row["trade_date"] > recovery_anchor]
        first_negative = next(
            (
                row
                for row in anchor_observations
                if float(row["unit_roi_before"]) < 0
            ),
            None,
        )
        recovery = (
            next(
                (
                    row
                    for row in anchor_observations
                    if row["trade_date"] > first_negative["trade_date"]
                    and float(row["unit_roi_before"]) >= 0
                ),
                None,
            )
            if first_negative
            else None
        )

        buy_to_final_add = (
            stage_count(sell_observations, buy["trade_date"], final_add["trade_date"])
            if final_add
            else None
        )
        buy_to_recovery = (
            stage_count(sell_observations, buy["trade_date"], recovery["trade_date"])
            if recovery and not final_add
            else None
        )
        final_add_to_recovery = (
            stage_count(sell_observations, final_add["trade_date"], recovery["trade_date"])
            if final_add and recovery
            else None
        )
        recovery_to_sell = (
            stage_count(sell_observations, recovery["trade_date"], sell["trade_date"])
            if recovery
            else None
        )
        unrecovered_after_final_add = (
            stage_count(sell_observations, final_add["trade_date"], sell["trade_date"])
            if final_add and first_negative and not recovery
            else None
        )

        if not first_negative:
            dominant_name, dominant_days = "positive-without-drawdown-to-sell", len(anchor_observations)
        elif final_add and not recovery:
            dominant_name, dominant_days = "unrecovered-after-final-add", int(unrecovered_after_final_add or 0)
        elif not final_add and not recovery:
            dominant_name, dominant_days = "unrecovered-without-add", len(sell_observations)
        else:
            dominant_name, dominant_days = choose_dominant(
                {
                    "buy-to-final-add": buy_to_final_add,
                    "buy-to-recovery": buy_to_recovery,
                    "final-add-to-recovery": final_add_to_recovery,
                    "recovery-to-sell": recovery_to_sell,
                }
            )

        return Round(
                sample=sample,
                window_id=str(buy["window_id"]),
                window_start=str(buy["window_start"]),
                window_end=str(buy["window_end"]),
                stock_id=str(buy["stock_id"]),
                stock_name=str(buy["stock_name"]),
                group_name=str(buy["group_name"]),
                round_before=int(buy["roll_rounds_before"]),
                buy_date=str(buy["trade_date"]),
                sell_date=str(sell["trade_date"]),
                holding_days=len(sell_observations),
                sell_roi=round(float(sell["unit_roi_before"]), 6),
                add_count=len(adds),
                final_add_date=str(final_add["trade_date"]) if final_add else "",
                had_negative_after_anchor=first_negative is not None,
                recovery_date=str(recovery["trade_date"]) if recovery else "",
                recovery_roi=round(float(recovery["unit_roi_before"]), 6) if recovery else None,
                recovery_grade=GRADE_NAMES.get(int(recovery["grade"]), str(recovery["grade"])) if recovery else "",
                recovery_trend_phase=(
                    TREND_NAMES.get(int(recovery["fit_trend_phase"] or 0), str(recovery["fit_trend_phase"]))
                    if recovery
                    else ""
                ),
                buy_to_final_add_days=buy_to_final_add,
                buy_to_recovery_days=buy_to_recovery,
                final_add_to_recovery_days=final_add_to_recovery,
                recovery_to_sell_days=recovery_to_sell,
                unrecovered_after_final_add_days=unrecovered_after_final_add,
                dominant_stage=dominant_name,
                dominant_stage_days=dominant_days,
            )


def mark_long_tail(rounds: list[Round], ratio: float) -> dict[str, Any]:
    count = max(1, math.ceil(len(rounds) * ratio)) if rounds else 0
    ordered = sorted(rounds, key=lambda row: (row.holding_days, row.stock_id, row.window_id, row.round_before), reverse=True)
    selected = ordered[:count]
    selected_ids = {(row.window_id, row.stock_id, row.round_before) for row in selected}
    for row in rounds:
        row.long_tail = (row.window_id, row.stock_id, row.round_before) in selected_ids
    return {
        "completed_rounds": len(rounds),
        "long_tail_rounds": count,
        "minimum_long_tail_holding_days": min((row.holding_days for row in selected), default=None),
    }


def summarize_subset(rounds: list[Round]) -> dict[str, Any]:
    recovered = [row for row in rounds if row.recovery_date]
    added = [row for row in rounds if row.add_count]
    added_recovered = [row for row in added if row.recovery_date]
    negative = [row for row in rounds if row.had_negative_after_anchor]
    waiting_roi_deltas = [
        row.sell_roi - float(row.recovery_roi)
        for row in recovered
        if row.recovery_roi is not None
    ]
    return {
        "rounds": len(rounds),
        "stocks": len({row.stock_id for row in rounds}),
        "windows": len({row.window_id for row in rounds}),
        "mean_holding_days": average(row.holding_days for row in rounds),
        "mean_sell_roi": average(row.sell_roi for row in rounds),
        "with_add": len(added),
        "with_add_pct": percentage(len(added), len(rounds)),
        "had_negative_after_anchor": len(negative),
        "recovered_after_drawdown": len(recovered),
        "recovered_after_drawdown_pct": percentage(len(recovered), len(negative)),
        "positive_without_drawdown": len(rounds) - len(negative),
        "unrecovered_after_final_add": sum(
            1 for row in added if row.had_negative_after_anchor and not row.recovery_date
        ),
        "mean_buy_to_final_add_days": average(row.buy_to_final_add_days for row in added),
        "mean_buy_to_recovery_days_without_add": average(row.buy_to_recovery_days for row in recovered if not row.add_count),
        "mean_final_add_to_recovery_days": average(row.final_add_to_recovery_days for row in added_recovered),
        "mean_recovery_to_sell_days": average(row.recovery_to_sell_days for row in recovered),
        "mean_recovery_roi": average(row.recovery_roi for row in recovered),
        "mean_recovered_sell_roi": average(row.sell_roi for row in recovered),
        "mean_waiting_roi_delta": average(waiting_roi_deltas),
        "waiting_improved_count": sum(1 for value in waiting_roi_deltas if value > 0),
        "waiting_worsened_count": sum(1 for value in waiting_roi_deltas if value < 0),
        "waiting_improved_pct": percentage(sum(1 for value in waiting_roi_deltas if value > 0), len(waiting_roi_deltas)),
        "dominant_stages": dict(sorted(Counter(row.dominant_stage for row in rounds).items())),
        "groups": dict(sorted(Counter(row.group_name for row in rounds).items())),
        "window_counts": dict(sorted(Counter(row.window_id for row in rounds).items())),
    }


def build_summary(rounds: list[Round], tail_meta: dict[str, dict[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {"samples": {}}
    for sample in sorted(tail_meta):
        sample_rounds = [row for row in rounds if row.sample == sample]
        result["samples"][sample] = {
            **tail_meta[sample],
            "all": summarize_subset(sample_rounds),
            "long_tail": summarize_subset([row for row in sample_rounds if row.long_tail]),
        }
    long_rounds = [row for row in rounds if row.long_tail]
    result["combined_long_tail"] = summarize_subset(long_rounds)
    result["combined_long_tail"]["recovery_grades"] = dict(
        sorted(Counter(row.recovery_grade for row in long_rounds if row.recovery_grade).items())
    )
    result["combined_long_tail"]["recovery_trend_phases"] = dict(
        sorted(Counter(row.recovery_trend_phase for row in long_rounds if row.recovery_trend_phase).items())
    )
    return result


def write_outputs(output: Path, rounds: list[Round], summary: dict[str, Any], databases: dict[str, Path]) -> None:
    output.mkdir(parents=True, exist_ok=True)
    with (output / "rounds.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(Round.__dataclass_fields__))
        writer.writeheader()
        writer.writerows(asdict(row) for row in rounds)
    (output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    manifest = {
        "study": "NR4-D0",
        "purpose": "diagnostic-only",
        "baseline": "v10",
        "data_rule_version": "T2/S28",
        "strategy_rule_version": "S24",
        "formal_rule_commit": "73003cf8f39cbf3a673792957324f508261bd731",
        "long_tail_definition": "Longest 20 percent of completed rounds within each sample by holding_days_before.",
        "decision_bases": {sample: str(path) for sample, path in databases.items()},
    }
    (output / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    lines = [
        "# NR4-D0 長週期持股階段診斷",
        "",
        "- 比較基準：Baseline v10（T2/S28，策略 S24）",
        "- 長週期：各 Sample 已完成持股輪中，依持有日數排序最長的 20%。",
        "- 本研究不修改或重播正式規則。",
        "",
        "## 摘要",
        "",
        "| Sample | 完成輪 | 長週期輪 | 長週期最低日數 | 平均日數 | 平均賣出 ROI | 有加碼 | 加碼後未回本 | 主導階段 |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---|",
    ]
    for sample, values in summary["samples"].items():
        long_tail = values["long_tail"]
        dominant = "、".join(f"{key} {value}" for key, value in long_tail["dominant_stages"].items())
        lines.append(
            f"| {sample} | {values['completed_rounds']} | {values['long_tail_rounds']} | "
            f"{values['minimum_long_tail_holding_days']} | {long_tail['mean_holding_days']} | "
            f"{long_tail['mean_sell_roi']} | {long_tail['with_add']} | "
            f"{long_tail['unrecovered_after_final_add']} | {dominant} |"
        )
    lines.extend(
        [
            "",
            "## 長週期明細",
            "",
            "| Sample | 股票 | 窗口 | 持有日 | 賣出 ROI | 加碼 | 買進至末次加碼 | 末次加碼至回本 | 回本至賣出 | 主導階段 |",
            "|---|---|---|---:|---:|---:|---:|---:|---:|---|",
        ]
    )
    for row in sorted((item for item in rounds if item.long_tail), key=lambda item: (item.sample, -item.holding_days)):
        lines.append(
            f"| {row.sample} | {row.stock_id} {row.stock_name} | {row.window_id} | {row.holding_days} | "
            f"{row.sell_roi} | {row.add_count} | {row.buy_to_final_add_days if row.buy_to_final_add_days is not None else '-'} | "
            f"{row.final_add_to_recovery_days if row.final_add_to_recovery_days is not None else '-'} | "
            f"{row.recovery_to_sell_days if row.recovery_to_sell_days is not None else '-'} | {row.dominant_stage} |"
        )
    (output / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()
    if not 0 < args.tail_ratio <= 1:
        raise ValueError("--tail-ratio must be in (0, 1]")
    root = args.project_root.resolve()
    output = args.output or root / "exports" / "holding-cycle-stage-study" / "nr4-d0-baseline-v10-t2s28-20260825"
    databases = {
        sample: root / "exports" / "backtest-decision-bases" / DEFAULT_BASES[sample] / "decisions.sqlite"
        for sample in args.samples
    }
    missing = [str(path) for path in databases.values() if not path.is_file()]
    if missing:
        raise FileNotFoundError("Missing DecisionBase: " + ", ".join(missing))

    rounds: list[Round] = []
    tail_meta: dict[str, dict[str, Any]] = {}
    for sample, database in databases.items():
        sample_rounds = build_rounds(sample, database)
        tail_meta[sample] = mark_long_tail(sample_rounds, args.tail_ratio)
        rounds.extend(sample_rounds)
    summary = build_summary(rounds, tail_meta)
    write_outputs(output.resolve(), rounds, summary, databases)
    print(json.dumps({"output": str(output.resolve()), **summary}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
