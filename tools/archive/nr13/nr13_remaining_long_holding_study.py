#!/usr/bin/env python3
"""NR13-D0-CD: diagnose long losing holdings remaining after S-T02g and G-M02."""

from __future__ import annotations

import csv
import json
import math
import sqlite3
from bisect import bisect_left
from collections import defaultdict
from datetime import datetime
from pathlib import Path
from statistics import median


ROOT = Path(__file__).resolve().parents[3]
EXPERIMENT_ID = "NR13-D0-CD"
OUTPUT = (
    ROOT
    / "exports/holding-waiting-value-study"
    / "nr13-d0-cd-remaining-long-holding-t2s35-20260830"
)
RULE_COMMIT = "a625837b8d48c2a8b35448dca8237267dc9edb9b"
RULE_VERSION = "s28-grade-loss-cut-penalty-20260830"
DATA_VERSION = "T2/S35"
BASE_IDS = {
    sample: (
        f"{sample.lower()}-abcd9-v2-s28-grade-loss-cut-penalty-20260830-"
        "t2-s35-a625837b8d48-fixed3y-20260722-v6"
    )
    for sample in ("C", "D")
}
CHECKPOINTS = (120, 240, 360)
GRADE_NAMES = {3: "wow", 2: "high", 1: "fine", 0: "none", -1: "weak", -2: "low", -3: "damn"}
PHASE_NAMES = {
    0: "暖機不足",
    1: "中性",
    2: "改善預警",
    3: "惡化預警",
    4: "舊改善確認",
    5: "舊惡化確認",
    6: "改善冷卻",
    7: "惡化冷卻",
    8: "改善探頂",
    9: "改善拉回",
    10: "惡化探底",
    11: "惡化反彈",
}


def parse_date(value: int):
    return datetime.strptime(str(value), "%Y%m%d").date()


def natural_grade(
    roll_roi: float,
    roll_days: float,
    rounds: float,
    inventory: float,
    holding_days: float,
    trade_date: int,
    start_date: int,
) -> int:
    inputs = (roll_roi, roll_days, rounds, inventory, holding_days)
    if not all(math.isfinite(value) for value in inputs):
        raise ValueError("Grade input contains a non-finite value")

    years = max((parse_date(trade_date) - parse_date(start_date)).days / 365.0, 1.0)
    roi = roll_roi / years
    if rounds <= 1:
        days = roll_days
    else:
        has_inventory = inventory > 0
        previous_rounds = rounds - (1 if has_inventory else 0)
        previous_days = (roll_days - (holding_days if has_inventory else 0)) / previous_rounds
        days = roll_days / rounds if holding_days > previous_days else previous_days

    if rounds <= 2 and days <= 360:
        return 0
    if days <= 0:
        return 0
    score = roi * 100 / days if roi >= 0 else roi * days / 100
    if score > 46:
        return 3
    if score > 39:
        return 2
    if score > 23:
        return 1
    if score >= -5:
        return -1
    if score >= -23:
        return -2
    return -3


def expected_penalized_grade(grade: int) -> int:
    return {3: 2, 2: 1, 1: -1, -1: -2, -2: -2}.get(grade, grade)


def roi_threshold(grade: int) -> float | None:
    if grade == 0:
        return None
    return -20.0 if grade in (-1, 1) else -17.5


def roi_band(value: float) -> str:
    if value <= -35:
        return "<=-35"
    if value <= -25:
        return "(-35,-25]"
    if value <= -20:
        return "(-25,-20]"
    if value <= -17.5:
        return "(-20,-17.5]"
    if value <= -10:
        return "(-17.5,-10]"
    return "(-10,0)"


def boundary_memberships(grade: int) -> list[str]:
    memberships = [f"exact_{GRADE_NAMES[grade]}"]
    if grade != 0:
        memberships.append("rated_all")
    if grade >= 1:
        memberships.append("fine_or_better")
    if grade <= -1:
        memberships.append("weak_or_below")
    if grade <= -2:
        memberships.append("low_or_below")
    return memberships


def verify_and_connect(sample: str) -> sqlite3.Connection:
    base_id = BASE_IDS[sample]
    directory = ROOT / "exports/backtest-decision-bases" / base_id
    manifest = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    expected = {
        "decisionBaseID": base_id,
        "sampleID": sample,
        "dataRuleVersion": DATA_VERSION,
        "ruleVersion": RULE_VERSION,
        "ruleCommit": RULE_COMMIT,
        "stockCount": 10,
        "windowCount": 3,
        "outcomeCount": 30,
    }
    for key, value in expected.items():
        if manifest.get(key) != value:
            raise ValueError(f"{sample} manifest mismatch: {key}={manifest.get(key)!r}, expected {value!r}")
    if (directory / ".complete").read_text(encoding="utf-8").strip() != base_id:
        raise ValueError(f"{sample} DecisionBase completion marker mismatch")
    if (directory / ".p4b-complete").read_text(encoding="utf-8").strip() != base_id:
        raise ValueError(f"{sample} P4b completion marker mismatch")
    connection = sqlite3.connect(directory / "decisions.sqlite")
    connection.row_factory = sqlite3.Row
    integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
    if integrity != "ok":
        raise ValueError(f"{sample} SQLite integrity check failed: {integrity}")
    return connection


def load_sample(sample: str):
    connection = verify_and_connect(sample)
    sell_query = """
        SELECT d.*, w.start_date, w.end_date,
               o.fit_trend_phase,
               GROUP_CONCAT(DISTINCT g.rule_id) AS passed_gates
        FROM decision_event_lookup d
        JOIN windows w USING(window_id)
        LEFT JOIN event_strategy_fit_observations x USING(event_id)
        LEFT JOIN strategy_fit_observations o USING(observation_id)
        LEFT JOIN event_gate_lookup g USING(event_id)
        WHERE d.phase = 3
        GROUP BY d.event_id
        ORDER BY d.window_id, d.stock_key, d.trade_date
    """
    sell_rows = [dict(row) for row in connection.execute(sell_query)]
    adds: dict[tuple[int, int], list[int]] = defaultdict(list)
    for row in connection.execute(
        """
        SELECT window_id, stock_key, trade_date
        FROM decision_events
        WHERE phase = 4 AND executed_action = 'ADD'
        ORDER BY window_id, stock_key, trade_date
        """
    ):
        adds[(int(row["window_id"]), int(row["stock_key"]))].append(int(row["trade_date"]))
    outcomes = {
        (int(row["window_id"]), int(row["stock_key"])): dict(row)
        for row in connection.execute(
            "SELECT window_id, stock_key, roi, average_days, rounds, grade_name, money_lacked, status FROM period_outcomes"
        )
    }
    connection.close()
    return sell_rows, adds, outcomes


def split_cycles(rows: list[dict[str, object]]):
    groups: dict[tuple[int, int], list[dict[str, object]]] = defaultdict(list)
    for row in rows:
        groups[(int(row["window_id"]), int(row["stock_key"]))].append(row)
    cycles = []
    for key, group_rows in groups.items():
        current: list[dict[str, object]] = []
        cycle_number = 0
        for row in group_rows:
            if float(row["inventory_before"]) <= 0:
                if current:
                    cycle_number += 1
                    cycles.append((key, cycle_number, current))
                    current = []
                continue
            current.append(row)
            if row["executed_action"] == "SELL":
                cycle_number += 1
                cycles.append((key, cycle_number, current))
                current = []
        if current:
            cycle_number += 1
            cycles.append((key, cycle_number, current))
    return cycles


def gates(row: dict[str, object]) -> set[str]:
    return {value for value in str(row.get("passed_gates") or "").split(",") if value}


def remaining_reason(row: dict[str, object], decision_grade: int, recent_add: bool) -> str:
    threshold = roi_threshold(decision_grade)
    roi = float(row["unit_roi_before"])
    row_gates = gates(row)
    if decision_grade == 0:
        return "grade_none"
    if decision_grade >= 2 and roi <= -17.5:
        return "high_deep_loss_without_exit"
    if threshold is not None and roi > threshold:
        if "S-T02e" in row_gates:
            return "st02e_subgate_passed_but_held_recent_add" if recent_add else "st02e_subgate_passed_but_held"
        return "roi_recovered_missing_sell_gate"
    if decision_grade <= 1:
        return "fine_or_lower_deep_loss"
    return "other"


def build_records(sample: str) -> list[dict[str, object]]:
    sell_rows, adds, outcomes = load_sample(sample)
    records: list[dict[str, object]] = []
    for key, cycle_number, cycle in split_cycles(sell_rows):
        add_dates = adds.get(key, [])
        cycle_dates = [int(row["trade_date"]) for row in cycle]
        for checkpoint in CHECKPOINTS:
            checkpoint_index = next(
                (
                    index
                    for index, row in enumerate(cycle)
                    if float(row["holding_days_before"]) > checkpoint
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
            future = cycle[checkpoint_index + 1 :]
            exit_offset = next(
                (offset for offset, future_row in enumerate(future, start=1) if future_row["executed_action"] == "SELL"),
                None,
            )
            exit_row = cycle[checkpoint_index + exit_offset] if exit_offset is not None else None
            outcome_end_date = int(exit_row["trade_date"]) if exit_row is not None else int(cycle[-1]["trade_date"])
            future_add_dates = [date for date in add_dates if trade_date < date <= outcome_end_date]
            observed = future[:exit_offset] if exit_offset is not None else future
            observed_rois = [float(item["unit_roi_before"]) for item in observed]
            natural = natural_grade(
                float(row["roll_roi_before"]),
                float(row["roll_days_before"]),
                float(row["roll_rounds_before"]),
                float(row["inventory_before"]),
                float(row["holding_days_before"]),
                int(row["trade_date"]),
                int(row["start_date"]),
            )
            decision = int(row["grade"])
            phase = int(row["fit_trend_phase"]) if row.get("fit_trend_phase") is not None else -1
            penalty_applied = decision != natural
            if penalty_applied:
                if phase != 10 or decision != expected_penalized_grade(natural):
                    raise ValueError(
                        f"Unexpected G-M02 mapping {sample} {row['stock_id']} {trade_date}: "
                        f"natural={natural}, decision={decision}, phase={phase}"
                    )
            checkpoint_roi = float(row["unit_roi_before"])
            exit_roi = float(exit_row["unit_roi_before"]) if exit_row is not None else None
            period = outcomes[key]
            record = {
                "sample": sample,
                "window_start": int(row["start_date"]),
                "window_end": int(row["end_date"]),
                "stock_id": row["stock_id"],
                "stock_name": row["stock_name"],
                "group_name": row["group_name"],
                "cycle_number": cycle_number,
                "checkpoint_days": checkpoint,
                "checkpoint_date": trade_date,
                "holding_days": float(row["holding_days_before"]),
                "checkpoint_roi": checkpoint_roi,
                "roi_band": roi_band(checkpoint_roi),
                "natural_grade": GRADE_NAMES[natural],
                "natural_grade_raw": natural,
                "decision_grade": GRADE_NAMES[decision],
                "decision_grade_raw": decision,
                "g_m02_applied": int(penalty_applied),
                "fit_trend_phase": phase,
                "fit_trend_phase_name": PHASE_NAMES.get(phase, "未知"),
                "sell_score": float(row["decision_score"]),
                "passed_gates": ",".join(sorted(gates(row))),
                "recent_add_60": int(recent_add),
                "last_add_date": last_add_date,
                "trading_days_since_add": trading_days_since_add,
                "remaining_reason": remaining_reason(row, decision, recent_add),
                "actual_exit": int(exit_row is not None),
                "exit_date": int(exit_row["trade_date"]) if exit_row is not None else None,
                "exit_roi": exit_roi,
                "realized_roi_delta": exit_roi - checkpoint_roi if exit_roi is not None else None,
                "wait_trading_days": exit_offset,
                "wait_calendar_days": (
                    (parse_date(int(exit_row["trade_date"])) - parse_date(trade_date)).days
                    if exit_row is not None
                    else None
                ),
                "total_holding_days_at_exit": (
                    float(exit_row["holding_days_before"]) if exit_row is not None else None
                ),
                "negative_exit": int(exit_roi < 0) if exit_roi is not None else None,
                "immediate_exit_dominates": int(exit_roi <= checkpoint_roi) if exit_roi is not None else None,
                "future_add_before_exit": int(bool(future_add_dates)),
                "future_add_count_before_exit": len(future_add_dates),
                "max_roi_before_exit": max(observed_rois) if observed_rois else checkpoint_roi,
                "min_roi_before_exit": min(observed_rois) if observed_rois else checkpoint_roi,
                "censored_at_window_end": int(exit_row is None),
                "period_roi": period["roi"],
                "period_average_days": period["average_days"],
                "period_rounds": period["rounds"],
                "period_grade": period["grade_name"],
                "period_money_lacked": period["money_lacked"],
                "period_status": period["status"],
            }
            records.append(record)
    return records


def finite(rows: list[dict[str, object]], key: str) -> list[float]:
    values = []
    for row in rows:
        value = row.get(key)
        if value is not None and math.isfinite(float(value)):
            values.append(float(value))
    return values


def rate(rows: list[dict[str, object]], key: str) -> float | None:
    values = finite(rows, key)
    return sum(values) / len(values) if values else None


def summarize(rows: list[dict[str, object]]) -> dict[str, object]:
    exited = [row for row in rows if row["actual_exit"] == 1]
    stock_counts: dict[str, int] = defaultdict(int)
    stock_names: dict[str, str] = {}
    for row in rows:
        stock_counts[str(row["stock_id"])] += 1
        stock_names[str(row["stock_id"])] = str(row["stock_name"])
    top_stock = max(stock_counts, key=stock_counts.get) if stock_counts else None
    two_year = [
        row for row in exited
        if row["total_holding_days_at_exit"] is not None
        and float(row["total_holding_days_at_exit"]) >= 480
    ]
    return {
        "events": len(rows),
        "stocks": len(stock_counts),
        "stock_windows": len({(row["stock_id"], row["window_start"]) for row in rows}),
        "checkpoint_roi_median": median(finite(rows, "checkpoint_roi")) if rows else None,
        "exit_rate": rate(rows, "actual_exit"),
        "negative_exit_rate": rate(exited, "negative_exit"),
        "immediate_exit_dominates_rate": rate(exited, "immediate_exit_dominates"),
        "realized_roi_delta_median": median(finite(exited, "realized_roi_delta")) if exited else None,
        "wait_trading_days_median": median(finite(exited, "wait_trading_days")) if exited else None,
        "future_add_rate": rate(rows, "future_add_before_exit"),
        "recent_add_60_rate": rate(rows, "recent_add_60"),
        "g_m02_applied_rate": rate(rows, "g_m02_applied"),
        "two_year_exit_count": len(two_year),
        "top_stock": (
            f"{top_stock} {stock_names[top_stock]}" if top_stock is not None else None
        ),
        "top_stock_share": stock_counts[top_stock] / len(rows) if top_stock is not None else None,
    }


def grouped(rows: list[dict[str, object]], keys: tuple[str, ...]) -> list[dict[str, object]]:
    groups: dict[tuple[object, ...], list[dict[str, object]]] = defaultdict(list)
    for row in rows:
        groups[tuple(row[key] for key in keys)].append(row)
    return [
        {**dict(zip(keys, values)), **summarize(items)}
        for values, items in sorted(groups.items(), key=lambda item: tuple(str(value) for value in item[0]))
    ]


def boundary_summary(rows: list[dict[str, object]]) -> list[dict[str, object]]:
    expanded = []
    for row in rows:
        for boundary in boundary_memberships(int(row["decision_grade_raw"])):
            expanded.append({**row, "grade_boundary": boundary})
    return grouped(expanded, ("sample", "checkpoint_days", "grade_boundary"))


def write_csv(path: Path, rows: list[dict[str, object]]) -> None:
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    fields = []
    for row in rows:
        for key in row:
            if key not in fields:
                fields.append(key)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def number(value: object, digits: int = 2) -> str:
    return "-" if value is None else f"{float(value):.{digits}f}"


def percent(value: object) -> str:
    return "-" if value is None else f"{float(value) * 100:.1f}%"


def report_table(rows: list[dict[str, object]], keys: tuple[str, ...]) -> list[str]:
    title = "／".join(keys)
    lines = [
        f"| {title} | 事件 | 股票×窗口 | ROI中位 | 賣出率 | 負損結案 | 立即認賠支配 | 實現差中位 | 等待交易日中位 | 後續加碼 | G-M02 | 最大個股占比 |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for row in rows:
        label = "／".join(str(row[key]) for key in keys)
        lines.append(
            f"| {label} | {row['events']} | {row['stock_windows']} | {number(row['checkpoint_roi_median'])} | "
            f"{percent(row['exit_rate'])} | {percent(row['negative_exit_rate'])} | "
            f"{percent(row['immediate_exit_dominates_rate'])} | {number(row['realized_roi_delta_median'])} | "
            f"{number(row['wait_trading_days_median'], 1)} | {percent(row['future_add_rate'])} | "
            f"{percent(row['g_m02_applied_rate'])} | {percent(row['top_stock_share'])} |"
        )
    lines.append("")
    return lines


def main() -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    complete = OUTPUT / ".complete"
    complete.unlink(missing_ok=True)
    records = [record for sample in ("C", "D") for record in build_records(sample)]
    cycle_groups: dict[tuple[object, ...], list[dict[str, object]]] = defaultdict(list)
    for row in records:
        cycle_groups[(row["sample"], row["window_start"], row["stock_id"], row["cycle_number"])].append(row)
    independent = [max(items, key=lambda item: int(item["checkpoint_days"])) for items in cycle_groups.values()]
    independent.sort(
        key=lambda row: (str(row["sample"]), int(row["window_start"]), str(row["stock_id"]), int(row["cycle_number"]))
    )
    by_sample = grouped(independent, ("sample",))
    by_checkpoint = grouped(records, ("sample", "checkpoint_days"))
    by_decision_grade = grouped(records, ("sample", "checkpoint_days", "decision_grade"))
    by_natural_grade = grouped(records, ("sample", "checkpoint_days", "natural_grade"))
    by_boundary = boundary_summary(records)
    by_reason = grouped(independent, ("sample", "remaining_reason"))
    by_stock = grouped(independent, ("sample", "stock_id", "stock_name"))
    summary = {
        "experiment_id": EXPERIMENT_ID,
        "baseline": "Baseline v16 / S28 / T2-S35 / Sample C-D DecisionBase v6",
        "rule_commit": RULE_COMMIT,
        "classification_uses_future": False,
        "outcome_uses_future": True,
        "checkpoint_days": list(CHECKPOINTS),
        "checkpoint_events": len(records),
        "independent_cycles": len(independent),
        "by_sample": by_sample,
        "by_checkpoint": by_checkpoint,
        "by_decision_grade": by_decision_grade,
        "by_natural_grade": by_natural_grade,
        "by_grade_boundary": by_boundary,
        "by_remaining_reason": by_reason,
        "by_stock": by_stock,
    }
    write_csv(OUTPUT / "checkpoint-events.csv", records)
    write_csv(OUTPUT / "independent-cycles.csv", independent)
    write_csv(OUTPUT / "summary-by-checkpoint.csv", by_checkpoint)
    write_csv(OUTPUT / "summary-by-decision-grade.csv", by_decision_grade)
    write_csv(OUTPUT / "summary-by-natural-grade.csv", by_natural_grade)
    write_csv(OUTPUT / "summary-by-grade-boundary.csv", by_boundary)
    write_csv(OUTPUT / "summary-by-remaining-reason.csv", by_reason)
    write_csv(OUTPUT / "summary-by-stock.csv", by_stock)
    (OUTPUT / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    report = [
        f"# {EXPERIMENT_ID}：S-T02g 與 G-M02 後的剩餘長期套牢",
        "",
        "## 方法",
        "",
        "固定使用 Baseline v16、S28、T2/S35 的 Sample C／D DecisionBase v6，不修改規則或重播。每輪持股在超過 120／240／360 日後，各取第一個仍為負 ROI 且當日未賣出的 SELL 判斷事件。分類只用檢查日以前資料；最終賣出 ROI、等待日數與期間加碼是事後結果，只能形成候選假設。",
        "",
        "DecisionBase 的事件 Grade 是 G-M02 套用後的決策 Grade；自然 Grade 由同事件的累積 ROI、平均週期與輪次依正式 G-T01／G-P／G-N 級距重算。若兩者不同，工具要求事件必須位於惡化探底且符合正式一級降級映射，否則停止。每輪獨立週期只保留其到達的最長檢查點，避免同一套牢重複計數。",
        "",
        "`立即認賠支配`表示最終賣出 ROI 小於或等於檢查點 ROI，亦即多等一段時間並未換到較好賣價；它仍不是提前賣出的完整反事實分數。",
        "",
        "## 獨立週期總覽",
        "",
    ]
    report.extend(report_table(by_sample, ("sample",)))
    report.extend(["## 120／240／360 日", ""])
    report.extend(report_table(by_checkpoint, ("sample", "checkpoint_days")))
    report.extend(["## 決策 Grade", ""])
    report.extend(report_table(by_decision_grade, ("sample", "checkpoint_days", "decision_grade")))
    report.extend(["## 連續 Grade 邊界", ""])
    report.extend(report_table(by_boundary, ("sample", "checkpoint_days", "grade_boundary")))
    report.extend(["## 仍持有原因", ""])
    report.extend(report_table(by_reason, ("sample", "remaining_reason")))
    report.extend([
        "## 判讀界限",
        "",
        "只有 C／D 在相同連續 Grade 方向與持股門檻呈現可解釋、非單股主導的共同交換結果，才值得另提 Sample C 單一變因候選並由 D 確認。`.none` 只可診斷，不得成為正式納入條件；診斷差值不能代替完整回測分數。",
        "",
    ])
    (OUTPUT / "report.md").write_text("\n".join(report), encoding="utf-8")
    complete.write_text(f"{EXPERIMENT_ID}\n", encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
