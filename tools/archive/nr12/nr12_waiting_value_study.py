#!/usr/bin/env python3
"""NR12-D0: diagnose the value of waiting outside S-T02e eligibility."""

from __future__ import annotations

import argparse
import csv
import json
import math
import sqlite3
from bisect import bisect_left
from collections import defaultdict
from datetime import datetime
from pathlib import Path
from statistics import mean, median


ROOT = Path(__file__).resolve().parents[3]
BASES = {
    "A": ROOT / "exports/backtest-decision-bases/a-abcd9-v2-s26-ap05-wow-exclude-worsening-trend-20260827-t2-s33-126da5fe2c93-fixed3y-20260722-v6/decisions.sqlite",
    "B": ROOT / "exports/backtest-decision-bases/b-abcd9-v2-s26-ap05-wow-exclude-worsening-trend-20260827-t2-s33-126da5fe2c93-fixed3y-20260722-v6/decisions.sqlite",
    "C": ROOT / "exports/backtest-decision-bases/c-abcd9-v2-s26-ap05-wow-exclude-worsening-trend-20260827-t2-s33-126da5fe2c93-fixed3y-20260722-v6/decisions.sqlite",
    "D": ROOT / "exports/backtest-decision-bases/d-abcd9-v2-s26-ap05-wow-exclude-worsening-trend-20260827-t2-s33-126da5fe2c93-fixed3y-20260722-v6/decisions.sqlite",
}
OUTPUT = ROOT / "exports/holding-waiting-value-study/nr12-d0-st02e-outside-waiting-value-ab-t2s33-20260829"
CHECKPOINTS = (90, 150, 240)
HORIZONS = (20, 60, 120)


def parse_date(value: int):
    return datetime.strptime(str(value), "%Y%m%d").date()


def load_events(database: Path):
    connection = sqlite3.connect(database)
    connection.row_factory = sqlite3.Row
    sell_query = """
        SELECT d.*, w.start_date, w.end_date,
               GROUP_CONCAT(DISTINCT g.rule_id) AS passed_gates
        FROM decision_event_lookup d
        JOIN windows w USING(window_id)
        LEFT JOIN event_gate_lookup g USING(event_id)
        WHERE d.phase = 3
        GROUP BY d.event_id
        ORDER BY d.window_id, d.stock_key, d.trade_date
    """
    sell_rows = [dict(row) for row in connection.execute(sell_query)]
    add_query = """
        SELECT window_id, stock_key, trade_date
        FROM decision_events
        WHERE phase = 4 AND executed_action = 'ADD'
        ORDER BY window_id, stock_key, trade_date
    """
    adds: dict[tuple[int, int], list[int]] = defaultdict(list)
    for row in connection.execute(add_query):
        adds[(int(row["window_id"]), int(row["stock_key"]))].append(int(row["trade_date"]))
    connection.close()
    return sell_rows, adds


def split_cycles(rows: list[dict[str, object]]):
    groups: dict[tuple[int, int], list[dict[str, object]]] = defaultdict(list)
    for row in rows:
        groups[(int(row["window_id"]), int(row["stock_key"]))].append(row)

    cycles: list[list[dict[str, object]]] = []
    for group_rows in groups.values():
        current: list[dict[str, object]] = []
        for row in group_rows:
            has_inventory = float(row["inventory_before"]) > 0
            if not has_inventory:
                if current:
                    cycles.append(current)
                    current = []
                continue
            current.append(row)
            if row["executed_action"] == "SELL":
                cycles.append(current)
                current = []
        if current:
            cycles.append(current)
    return cycles


def grade_roi_threshold(grade: int) -> float | None:
    if grade == 0:
        return None
    return -20.0 if grade in (-1, 1) else -17.5


def roi_band(value: float) -> str:
    if value <= -25.0:
        return "<=-25"
    if value <= -20.0:
        return "(-25,-20]"
    if value <= -17.5:
        return "(-20,-17.5]"
    if value <= -10.0:
        return "(-17.5,-10]"
    return "(-10,0)"


def gates(row: dict[str, object]) -> set[str]:
    return {item for item in str(row.get("passed_gates") or "").split(",") if item}


def failure_reason(row: dict[str, object], recent_add: bool) -> str:
    row_gates = gates(row)
    if "S-T02e" in row_gates:
        return "cooldown_after_add" if recent_add else "eligibility_passed_but_held"
    grade = int(row["grade"])
    if grade == 0:
        return "grade_unrated"
    threshold = grade_roi_threshold(grade)
    if threshold is not None and float(row["unit_roi_before"]) <= threshold:
        return "roi_below_threshold"
    return "sell_votes_insufficient"


def horizon_metrics(
    cycle: list[dict[str, object]],
    checkpoint_index: int,
    horizon: int,
    add_dates: list[int],
) -> dict[str, object]:
    checkpoint = cycle[checkpoint_index]
    future = cycle[checkpoint_index + 1:]
    selected = future[:horizon]
    exit_index = next(
        (index for index, row in enumerate(future, start=1) if row["executed_action"] == "SELL"),
        None,
    )
    complete = len(future) >= horizon or (exit_index is not None and exit_index <= horizon)
    if not complete:
        return {
            f"complete_{horizon}d": 0,
            f"max_roi_{horizon}d": None,
            f"max_improvement_{horizon}d": None,
            f"min_roi_{horizon}d": None,
            f"break_even_{horizon}d": None,
            f"st02e_reached_{horizon}d": None,
            f"exit_{horizon}d": None,
            f"future_add_{horizon}d": None,
        }

    checkpoint_roi = float(checkpoint["unit_roi_before"])
    roi_values = [float(row["unit_roi_before"]) for row in selected]
    max_roi = max(roi_values) if roi_values else checkpoint_roi
    min_roi = min(roi_values) if roi_values else checkpoint_roi
    end_date = int(selected[-1]["trade_date"]) if selected else int(checkpoint["trade_date"])
    start_date = int(checkpoint["trade_date"])
    future_add = any(start_date < add_date <= end_date for add_date in add_dates)
    return {
        f"complete_{horizon}d": 1,
        f"max_roi_{horizon}d": max_roi,
        f"max_improvement_{horizon}d": max_roi - checkpoint_roi,
        f"min_roi_{horizon}d": min_roi,
        f"break_even_{horizon}d": int(max_roi > 0),
        f"st02e_reached_{horizon}d": int(any("S-T02e" in gates(row) for row in selected)),
        f"exit_{horizon}d": int(exit_index is not None and exit_index <= horizon),
        f"future_add_{horizon}d": int(future_add),
    }


def build_checkpoints(sample: str, database: Path) -> list[dict[str, object]]:
    sell_rows, adds = load_events(database)
    output: list[dict[str, object]] = []
    cycles = split_cycles(sell_rows)
    for cycle_number, cycle in enumerate(cycles, start=1):
        first = cycle[0]
        key = (int(first["window_id"]), int(first["stock_key"]))
        add_dates = adds.get(key, [])
        cycle_dates = [int(row["trade_date"]) for row in cycle]
        for checkpoint_days in CHECKPOINTS:
            checkpoint_index = next(
                (
                    index
                    for index, row in enumerate(cycle)
                    if float(row["holding_days_before"]) > checkpoint_days
                    and float(row["unit_roi_before"]) < 0
                    and row["executed_action"] != "SELL"
                ),
                None,
            )
            if checkpoint_index is None:
                continue
            row = cycle[checkpoint_index]
            trade_date = int(row["trade_date"])
            prior_add_index = bisect_left(add_dates, trade_date) - 1
            last_add_date = add_dates[prior_add_index] if prior_add_index >= 0 else None
            if last_add_date is None:
                trading_days_since_add = None
                recent_add = False
            else:
                add_position = bisect_left(cycle_dates, last_add_date)
                trading_days_since_add = checkpoint_index - add_position
                recent_add = 0 <= trading_days_since_add < 60

            exit_offset = next(
                (
                    offset
                    for offset, future_row in enumerate(cycle[checkpoint_index + 1:], start=1)
                    if future_row["executed_action"] == "SELL"
                ),
                None,
            )
            exit_row = cycle[checkpoint_index + exit_offset] if exit_offset is not None else None
            record: dict[str, object] = {
                "sample": sample,
                "window_start": int(row["start_date"]),
                "window_end": int(row["end_date"]),
                "stock_id": row["stock_id"],
                "stock_name": row["stock_name"],
                "group_name": row["group_name"],
                "cycle_number": cycle_number,
                "checkpoint_days": checkpoint_days,
                "trade_date": trade_date,
                "grade": row["grade_name"],
                "grade_raw": int(row["grade"]),
                "holding_days": float(row["holding_days_before"]),
                "roi": float(row["unit_roi_before"]),
                "roi_band": roi_band(float(row["unit_roi_before"])),
                "sell_score": float(row["decision_score"]),
                "recent_add_60": int(recent_add),
                "last_add_date": last_add_date,
                "trading_days_since_add": trading_days_since_add,
                "failure_reason": failure_reason(row, recent_add),
                "actual_exit": int(exit_row is not None),
                "trading_days_to_exit": exit_offset,
                "calendar_days_to_exit": (
                    (parse_date(int(exit_row["trade_date"])) - parse_date(trade_date)).days
                    if exit_row is not None else None
                ),
                "exit_date": int(exit_row["trade_date"]) if exit_row is not None else None,
                "exit_roi": float(exit_row["unit_roi_before"]) if exit_row is not None else None,
                "censored_at_window_end": int(exit_row is None),
            }
            for horizon in HORIZONS:
                record.update(horizon_metrics(cycle, checkpoint_index, horizon, add_dates))
            output.append(record)
    return output


def finite_values(rows: list[dict[str, object]], key: str) -> list[float]:
    values: list[float] = []
    for row in rows:
        value = row.get(key)
        if value is not None and math.isfinite(float(value)):
            values.append(float(value))
    return values


def rate(rows: list[dict[str, object]], key: str) -> float | None:
    values = finite_values(rows, key)
    return sum(values) / len(values) if values else None


def summarize(rows: list[dict[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {
        "events": len(rows),
        "stocks": len({row["stock_id"] for row in rows}),
        "stock_windows": len({(row["stock_id"], row["window_start"]) for row in rows}),
        "roi_median": median(finite_values(rows, "roi")) if rows else None,
        "future_exit_rate": rate(rows, "actual_exit"),
        "censored_rate": rate(rows, "censored_at_window_end"),
    }
    for horizon in HORIZONS:
        complete_rows = [row for row in rows if row[f"complete_{horizon}d"] == 1]
        improvement = finite_values(complete_rows, f"max_improvement_{horizon}d")
        result[f"complete_{horizon}d"] = len(complete_rows)
        result[f"max_improvement_{horizon}d_median"] = median(improvement) if improvement else None
        result[f"break_even_{horizon}d_rate"] = rate(complete_rows, f"break_even_{horizon}d")
        result[f"st02e_reached_{horizon}d_rate"] = rate(complete_rows, f"st02e_reached_{horizon}d")
        result[f"exit_{horizon}d_rate"] = rate(complete_rows, f"exit_{horizon}d")
        result[f"future_add_{horizon}d_rate"] = rate(complete_rows, f"future_add_{horizon}d")
    return result


def grouped(rows: list[dict[str, object]], keys: tuple[str, ...]) -> list[dict[str, object]]:
    groups: dict[tuple[object, ...], list[dict[str, object]]] = defaultdict(list)
    for row in rows:
        groups[tuple(row[key] for key in keys)].append(row)
    output = []
    for values, items in sorted(groups.items(), key=lambda item: tuple(str(value) for value in item[0])):
        output.append({**dict(zip(keys, values)), **summarize(items)})
    return output


def format_number(value: object, digits: int = 2) -> str:
    return "-" if value is None else f"{float(value):.{digits}f}"


def format_rate(value: object) -> str:
    return "-" if value is None else f"{float(value) * 100:.1f}%"


def write_csv(path: Path, rows: list[dict[str, object]]) -> None:
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    fields: list[str] = []
    for row in rows:
        for key in row:
            if key not in fields:
                fields.append(key)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def report_table(rows: list[dict[str, object]], group_keys: tuple[str, ...]) -> list[str]:
    labels = "／".join(group_keys)
    lines = [
        f"| {labels} | 事件 | 股票×窗口 | ROI中位 | 60日最大改善中位 | 60日回本 | 60日取得S-T02e | 60日賣出 | 60日後續加碼 |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for row in rows:
        name = "／".join(str(row[key]) for key in group_keys)
        lines.append(
            "| {name} | {events} | {windows} | {roi} | {improvement} | {break_even} | {eligible} | {exit_rate} | {add_rate} |".format(
                name=name,
                events=row["events"],
                windows=row["stock_windows"],
                roi=format_number(row["roi_median"]),
                improvement=format_number(row["max_improvement_60d_median"]),
                break_even=format_rate(row["break_even_60d_rate"]),
                eligible=format_rate(row["st02e_reached_60d_rate"]),
                exit_rate=format_rate(row["exit_60d_rate"]),
                add_rate=format_rate(row["future_add_60d_rate"]),
            )
        )
    lines.append("")
    return lines


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--samples",
        nargs="+",
        choices=sorted(BASES),
        default=["A", "B"],
        help="DecisionBase samples to analyze (default: A B)",
    )
    parser.add_argument("--experiment-id", default="NR12-D0")
    parser.add_argument(
        "--output-name",
        help="Directory name under exports/holding-waiting-value-study",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    output = (
        ROOT / "exports/holding-waiting-value-study" / args.output_name
        if args.output_name
        else OUTPUT
    )
    output.mkdir(parents=True, exist_ok=True)
    complete_marker = output / ".complete"
    complete_marker.unlink(missing_ok=True)

    all_rows: list[dict[str, object]] = []
    for sample in args.samples:
        database = BASES[sample]
        if not database.exists():
            raise FileNotFoundError(database)
        all_rows.extend(build_checkpoints(sample, database))

    primary = [
        row for row in all_rows
        if row["recent_add_60"] == 0
        and row["failure_reason"] in {
            "grade_unrated", "roi_below_threshold", "sell_votes_insufficient"
        }
    ]
    by_sample = grouped(primary, ("sample",))
    by_checkpoint = grouped(primary, ("sample", "checkpoint_days"))
    by_reason = grouped(primary, ("sample", "failure_reason"))
    by_grade = grouped(primary, ("sample", "grade"))
    by_boundary = grouped(
        primary, ("sample", "checkpoint_days", "failure_reason", "roi_band")
    )
    all_reasons = grouped(all_rows, ("sample", "failure_reason"))

    summary = {
        "experiment_id": args.experiment_id,
        "baseline": "Baseline v14 / S26 / T2-S33 / DecisionBase v6",
        "hypothesis": "S-T02e 以外的部分長期負報酬持股，等待 60/120 日仍無法有效恢復，形成無效資金占用。",
        "classification_uses_future": False,
        "checkpoint_days": list(CHECKPOINTS),
        "horizons": list(HORIZONS),
        "all_checkpoint_events": len(all_rows),
        "primary_no_recent_add_events": len(primary),
        "by_sample": by_sample,
        "by_checkpoint": by_checkpoint,
        "by_failure_reason": by_reason,
        "by_boundary": by_boundary,
        "all_failure_reasons": all_reasons,
    }

    write_csv(output / "checkpoint-events.csv", all_rows)
    write_csv(output / "primary-no-recent-add.csv", primary)
    write_csv(output / "summary-by-checkpoint.csv", by_checkpoint)
    write_csv(output / "summary-by-failure-reason.csv", by_reason)
    write_csv(output / "summary-by-grade.csv", by_grade)
    write_csv(output / "summary-by-boundary.csv", by_boundary)
    (output / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    report = [
        f"# {args.experiment_id}：S-T02e 以外長期持股的等待價值",
        "",
        "## 方法",
        "",
        f"固定使用 Baseline v14、S26、T2/S33 的 Sample {'／'.join(args.samples)} DecisionBase v6，不修改規則。每輪持股在超過 90／150／240 日後，只取第一個仍為負 ROI、當日未賣出的事件；分類只使用當日以前的正式狀態，後續 20／60／120 個交易日只作結果統計。主要分析排除前 60 個交易日內已加碼的事件，另保留全部原因旁錄。",
        "",
        "`unit_roi_before` 會在後續加碼後改變成本，因此報告同時列出後續加碼率；不能把加碼造成的 ROI 改善全部解讀為單純等待的價值。未滿觀察期且尚未賣出的窗口尾端事件標為截尾，不進入該期限比例。",
        "",
        "## A/B 主要摘要",
        "",
    ]
    report.extend(report_table(by_sample, ("sample",)))
    report.extend(["## 持股日檢查點", ""])
    report.extend(report_table(by_checkpoint, ("sample", "checkpoint_days")))
    report.extend(["## 未通過原因", ""])
    report.extend(report_table(by_reason, ("sample", "failure_reason")))
    report.extend(["## 持股日 × 原因 × ROI 聯合界線", ""])
    report.extend(report_table(
        by_boundary, ("sample", "checkpoint_days", "failure_reason", "roi_band")
    ))
    report.extend([
        "## 判讀界限",
        "",
        "本研究只能辨識值得建立候選的共同區段，不能把觀察到的未來結果當成可交易時已知資訊，也不能直接估算提前賣出的反事實績效。只有 A／B 在相同原因與持股／ROI 區段呈現一致、非單股主導的低恢復率，才提出獨立認賠候選並完整重播。",
        "",
    ])
    (output / "report.md").write_text("\n".join(report), encoding="utf-8")
    complete_marker.write_text(f"{args.experiment_id}\n", encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
