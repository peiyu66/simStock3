#!/usr/bin/env python3
"""NR12-D2-C: measure the realized exchange value of waiting to sell."""

from __future__ import annotations

import argparse
import csv
import json
import math
from collections import defaultdict
from pathlib import Path
from statistics import median

import nr12_waiting_value_study as waiting_value


ROOT = Path(__file__).resolve().parents[1]
CHECKPOINTS = (90, 150, 240, 360, 480)
PRIMARY_REASONS = {
    "grade_unrated",
    "roi_below_threshold",
    "sell_votes_insufficient",
}


def finite_values(rows: list[dict[str, object]], key: str) -> list[float]:
    values = []
    for row in rows:
        value = row.get(key)
        if value is not None and math.isfinite(float(value)):
            values.append(float(value))
    return values


def median_value(rows: list[dict[str, object]], key: str) -> float | None:
    values = finite_values(rows, key)
    return median(values) if values else None


def rate(rows: list[dict[str, object]], key: str) -> float | None:
    values = finite_values(rows, key)
    return sum(values) / len(values) if values else None


def summarize(rows: list[dict[str, object]]) -> dict[str, object]:
    completed = [row for row in rows if row["actual_exit"] == 1]
    total_holding = finite_values(completed, "total_holding_days_at_exit")
    return {
        "events": len(rows),
        "stocks": len({row["stock_id"] for row in rows}),
        "stock_windows": len({(row["window_start"], row["stock_id"]) for row in rows}),
        "actual_exit_rate": len(completed) / len(rows) if rows else None,
        "checkpoint_roi_median": median_value(completed, "checkpoint_roi"),
        "exit_roi_median": median_value(completed, "exit_roi"),
        "realized_roi_delta_median": median_value(completed, "realized_roi_delta"),
        "wait_trading_days_median": median_value(completed, "wait_trading_days"),
        "wait_trading_days_max": max(finite_values(completed, "wait_trading_days"), default=None),
        "total_holding_days_median": median(total_holding) if total_holding else None,
        "total_holding_days_max": max(total_holding, default=None),
        "negative_exit_rate": rate(completed, "negative_exit"),
        "immediate_exit_dominates_rate": rate(completed, "immediate_exit_dominates"),
        "later_exit_better_rate": rate(completed, "later_exit_better"),
        "future_add_before_exit_rate": rate(completed, "future_add_before_exit"),
    }


def grouped(rows: list[dict[str, object]], keys: tuple[str, ...]) -> list[dict[str, object]]:
    groups: dict[tuple[object, ...], list[dict[str, object]]] = defaultdict(list)
    for row in rows:
        groups[tuple(row[key] for key in keys)].append(row)
    output = []
    for values, items in sorted(groups.items(), key=lambda item: tuple(str(value) for value in item[0])):
        output.append({**dict(zip(keys, values)), **summarize(items)})
    return output


def write_csv(path: Path, rows: list[dict[str, object]]) -> None:
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def format_number(value: object, digits: int = 2) -> str:
    return "-" if value is None else f"{float(value):.{digits}f}"


def format_rate(value: object) -> str:
    return "-" if value is None else f"{float(value) * 100:.1f}%"


def report_table(rows: list[dict[str, object]], keys: tuple[str, ...]) -> list[str]:
    labels = [*keys, "件數", "股票", "檢查 ROI", "賣出 ROI", "實現差", "多等日", "總持有日", "仍虧損", "立即較佳", "期間加碼"]
    lines = ["| " + " | ".join(labels) + " |", "| " + " | ".join(["---"] * len(labels)) + " |"]
    for row in rows:
        values = [str(row[key]) for key in keys]
        values.extend([
            str(row["events"]),
            str(row["stocks"]),
            format_number(row["checkpoint_roi_median"]),
            format_number(row["exit_roi_median"]),
            format_number(row["realized_roi_delta_median"]),
            format_number(row["wait_trading_days_median"], 0),
            format_number(row["total_holding_days_median"], 0),
            format_rate(row["negative_exit_rate"]),
            format_rate(row["immediate_exit_dominates_rate"]),
            format_rate(row["future_add_before_exit_rate"]),
        ])
        lines.append("| " + " | ".join(values) + " |")
    lines.append("")
    return lines


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sample", choices=sorted(waiting_value.BASES), default="C")
    parser.add_argument("--experiment-id", default="NR12-D2-C")
    parser.add_argument(
        "--output-name",
        default="nr12-d2-c-realized-waiting-cost-c-t2s33-20260829",
        help="Directory name under exports/holding-waiting-cost-study",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    output = ROOT / "exports/holding-waiting-cost-study" / args.output_name
    output.mkdir(parents=True, exist_ok=True)
    complete_marker = output / ".complete"
    complete_marker.unlink(missing_ok=True)

    waiting_value.CHECKPOINTS = CHECKPOINTS
    database = waiting_value.BASES[args.sample]
    checkpoint_rows = waiting_value.build_checkpoints(args.sample, database)
    sell_rows, adds = waiting_value.load_events(database)

    public_to_internal = {}
    for row in sell_rows:
        public_to_internal[(int(row["start_date"]), row["stock_id"])] = (
            int(row["window_id"]),
            int(row["stock_key"]),
        )

    exchange_rows = []
    for row in checkpoint_rows:
        checkpoint_roi = float(row["roi"])
        exit_roi = float(row["exit_roi"]) if row["exit_roi"] is not None else None
        wait_days = int(row["trading_days_to_exit"]) if row["trading_days_to_exit"] is not None else None
        total_holding = float(row["holding_days"]) + wait_days if wait_days is not None else None
        internal_key = public_to_internal[(int(row["window_start"]), row["stock_id"])]
        end_date = int(row["exit_date"] or row["window_end"])
        future_add_dates = [
            int(value)
            for value in adds.get(internal_key, [])
            if int(row["trade_date"]) < int(value) <= end_date
        ]
        realized_delta = exit_roi - checkpoint_roi if exit_roi is not None else None
        exchange_rows.append({
            "sample": row["sample"],
            "window_start": row["window_start"],
            "window_end": row["window_end"],
            "stock_id": row["stock_id"],
            "stock_name": row["stock_name"],
            "group_name": row["group_name"],
            "cycle_number": row["cycle_number"],
            "checkpoint_days": row["checkpoint_days"],
            "checkpoint_date": row["trade_date"],
            "grade": row["grade"],
            "roi_band": row["roi_band"],
            "failure_reason": row["failure_reason"],
            "sell_score": row["sell_score"],
            "recent_add_60": row["recent_add_60"],
            "checkpoint_roi": checkpoint_roi,
            "actual_exit": row["actual_exit"],
            "exit_date": row["exit_date"],
            "exit_roi": exit_roi,
            "realized_roi_delta": realized_delta,
            "wait_trading_days": wait_days,
            "wait_calendar_days": row["calendar_days_to_exit"],
            "total_holding_days_at_exit": total_holding,
            "negative_exit": int(exit_roi < 0) if exit_roi is not None else None,
            "immediate_exit_dominates": int(realized_delta <= 0) if realized_delta is not None else None,
            "later_exit_better": int(realized_delta > 0) if realized_delta is not None else None,
            "future_add_before_exit": int(bool(future_add_dates)),
            "future_add_count_before_exit": len(future_add_dates),
            "censored_at_window_end": row["censored_at_window_end"],
        })

    primary = [
        row for row in exchange_rows
        if row["recent_add_60"] == 0 and row["failure_reason"] in PRIMARY_REASONS
    ]
    cycle_groups: dict[tuple[object, ...], list[dict[str, object]]] = defaultdict(list)
    for row in primary:
        cycle_groups[(row["window_start"], row["stock_id"], row["cycle_number"])].append(row)
    cycle_rows = [max(rows, key=lambda row: int(row["checkpoint_days"])) for rows in cycle_groups.values()]
    cycle_rows.sort(key=lambda row: (int(row["window_start"]), str(row["stock_id"]), int(row["cycle_number"])))

    by_latest_checkpoint = grouped(cycle_rows, ("checkpoint_days",))
    by_checkpoint = grouped(primary, ("checkpoint_days",))
    by_reason = grouped(cycle_rows, ("failure_reason",))
    by_boundary = grouped(primary, ("checkpoint_days", "failure_reason", "roi_band"))
    by_stock = grouped(cycle_rows, ("stock_id", "stock_name"))
    two_year_cycles = [
        row for row in cycle_rows
        if row["total_holding_days_at_exit"] is not None
        and float(row["total_holding_days_at_exit"]) >= 480
    ]

    summary = {
        "experiment_id": args.experiment_id,
        "baseline": f"Baseline v14 / S26 / T2-S33 / Sample {args.sample} DecisionBase v6",
        "classification_uses_future": False,
        "outcome_uses_future": True,
        "checkpoint_days": list(CHECKPOINTS),
        "primary_checkpoint_events": len(primary),
        "independent_cycles": len(cycle_rows),
        "two_year_cycles": len(two_year_cycles),
        "overall_independent_cycles": summarize(cycle_rows),
        "by_latest_checkpoint": by_latest_checkpoint,
        "by_checkpoint": by_checkpoint,
        "by_failure_reason_at_latest_checkpoint": by_reason,
        "by_boundary": by_boundary,
        "by_stock": by_stock,
    }

    write_csv(output / "checkpoint-exchange.csv", primary)
    write_csv(output / "independent-cycles.csv", cycle_rows)
    write_csv(output / "two-year-cycles.csv", two_year_cycles)
    write_csv(output / "summary-by-latest-checkpoint.csv", by_latest_checkpoint)
    write_csv(output / "summary-by-checkpoint.csv", by_checkpoint)
    write_csv(output / "summary-by-failure-reason.csv", by_reason)
    write_csv(output / "summary-by-boundary.csv", by_boundary)
    write_csv(output / "summary-by-stock.csv", by_stock)
    (output / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    report = [
        f"# {args.experiment_id}：長期等待的實際交換價值",
        "",
        "## 方法",
        "",
        f"固定使用 Baseline v14、S26、T2/S33 的 Sample {args.sample} DecisionBase v6，不修改規則。檢查點條件只使用當日以前資料；最終賣出 ROI、等待日數與期間加碼是事後結果，只用來形成候選假設。`實現差`為最終賣出 ROI 減去檢查點 ROI；小於或等於 0 表示當時立即認賠在價格與時間上都不差，列為立即認賠支配。",
        "",
        "每個檢查點表可比較候選邊界；獨立週期表只保留每輪到達的最長檢查點，避免把同一套牢週期重複計數。兩年案例以總持股至少 480 個交易日定義。",
        "",
        "## 獨立週期總覽",
        "",
    ]
    report.extend(report_table([summarize(cycle_rows)], ()))
    report.extend(["## 每輪最長檢查點", ""])
    report.extend(report_table(by_latest_checkpoint, ("checkpoint_days",)))
    report.extend(["## 各檢查點交換結果", ""])
    report.extend(report_table(by_checkpoint, ("checkpoint_days",)))
    report.extend(["## 最長檢查點的未通過原因", ""])
    report.extend(report_table(by_reason, ("failure_reason",)))
    report.extend([
        "## 判讀界限",
        "",
        "本研究只能找出值得完整重播的認賠邊界。若立即賣出只是節省時間但犧牲明顯 ROI，仍需以完整候選回測衡量資金再利用是否足以補回；不得把診斷差值直接當成候選分數。Grade `none` 只可診斷，不可作正式正向門檻。",
        "",
    ])
    (output / "report.md").write_text("\n".join(report), encoding="utf-8")
    complete_marker.write_text(f"{args.experiment_id}\n", encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
