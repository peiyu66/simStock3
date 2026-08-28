#!/usr/bin/env python3
"""GT-P10-D0 v2: reconstruct A-P02's formal A-T01/A-T02 route impact."""

from __future__ import annotations

import csv
import json
import math
import sqlite3
from bisect import bisect_right
from collections import defaultdict
from pathlib import Path
from statistics import mean, median


ROOT = Path(__file__).resolve().parents[1]
BASES = {
    "A": ROOT / "exports/backtest-decision-bases/a-abcd9-v2-s26-ap05-wow-exclude-worsening-trend-20260827-t2-s33-126da5fe2c93-fixed3y-20260722-v6/decisions.sqlite",
    "B": ROOT / "exports/backtest-decision-bases/b-abcd9-v2-s26-ap05-wow-exclude-worsening-trend-20260827-t2-s33-126da5fe2c93-fixed3y-20260722-v6/decisions.sqlite",
}
OUTPUT = ROOT / "exports/ap02-trend-context-study/gt-p10-d0-ap02-formal-route-v2-ab-t2s33-20260829"

# 正式 S26 加碼出口。A-P02 本身只加一分，是否關鍵必須分別重建兩條出口。
AT01_SCORE = 3.0
AT01_SHORT_DAYS = 180.0
AT01_LONG_DAYS = 360.0

PHASE_NAMES = {
    0: "unavailable",
    1: "neutral",
    2: "improving_warning",
    3: "worsening_warning",
    4: "legacy_improving_confirmed",
    5: "legacy_worsening_confirmed",
    6: "improving_cooldown",
    7: "worsening_cooldown",
    8: "improving_seeking_peak",
    9: "improving_pulling_back",
    10: "worsening_seeking_bottom",
    11: "worsening_rebounding",
}


def formal_routes(row: sqlite3.Row, score: float) -> tuple[str, ...]:
    grade = int(row["grade"])
    roi = float(row["unit_roi_before"])
    days = float(row["holding_days_before"])
    buy_rule = str(row["buy_rule_before"])

    deep_loss_threshold = -32.5 if grade >= 0 else -30.0
    deep_loss = roi < deep_loss_threshold
    cycle_loss = roi < -25.0 and (days < AT01_SHORT_DAYS or days > AT01_LONG_DAYS)
    at01 = (deep_loss or cycle_loss) and score >= AT01_SCORE

    at02_threshold = 2.0 if grade <= -2 else 3.0
    at02 = -10.0 < roi < 1.0 and buy_rule == "L" and days < 60.0 and score >= at02_threshold

    routes: list[str] = []
    if at01:
        routes.append("A-T01")
    if at02:
        routes.append("A-T02")
    return tuple(routes)


def load_price_changes(connection: sqlite3.Connection) -> dict[int, tuple[list[int], list[float]]]:
    values: dict[int, tuple[list[int], list[float]]] = {}
    dates_by_stock: dict[int, list[int]] = defaultdict(list)
    changes_by_stock: dict[int, list[float]] = defaultdict(list)
    for stock_key, trade_date, change in connection.execute(
        "SELECT stock_key, trade_date, close_change_percent "
        "FROM technical_observations ORDER BY stock_key, trade_date"
    ):
        dates_by_stock[int(stock_key)].append(int(trade_date))
        changes_by_stock[int(stock_key)].append(float(change))
    for stock_key in dates_by_stock:
        values[stock_key] = (dates_by_stock[stock_key], changes_by_stock[stock_key])
    return values


def forward_metrics(
    row: sqlite3.Row,
    prices: dict[int, tuple[list[int], list[float]]],
    horizon: int,
) -> tuple[float | None, float | None]:
    series = prices.get(int(row["stock_key"]))
    if series is None:
        return None, None
    dates, changes = series
    start = bisect_right(dates, int(row["trade_date"]))
    selected: list[float] = []
    for index in range(start, len(dates)):
        if dates[index] > int(row["end_date"]):
            break
        selected.append(changes[index])
        if len(selected) == horizon:
            break
    if len(selected) < horizon:
        return None, None

    wealth = 1.0
    minimum_wealth = 1.0
    for change in selected:
        wealth *= 1.0 + change / 100.0
        minimum_wealth = min(minimum_wealth, wealth)
    return (wealth - 1.0) * 100.0, (minimum_wealth - 1.0) * 100.0


def load_sample(sample: str, database: Path) -> list[dict[str, object]]:
    if not database.exists():
        raise FileNotFoundError(database)
    connection = sqlite3.connect(database)
    connection.row_factory = sqlite3.Row
    prices = load_price_changes(connection)
    query = """
        SELECT d.*, w.start_date, w.end_date,
               sf.fit_trend, sf.fit_trend_phase, sf.fit_trend_phase_extreme,
               po.roi AS period_roi, po.average_days AS period_average_days,
               po.rounds AS period_rounds, po.grade_name AS period_grade,
               GROUP_CONCAT(DISTINCT g.rule_id) AS passed_gates
        FROM decision_event_lookup d
        JOIN event_vote_lookup v
          ON v.event_id = d.event_id
         AND v.rule_id = 'A-P02'
         AND v.contribution = 1
        JOIN windows w ON w.window_id = d.window_id
        LEFT JOIN event_strategy_fit_observations eso ON eso.event_id = d.event_id
        LEFT JOIN strategy_fit_observations sf ON sf.observation_id = eso.observation_id
        LEFT JOIN period_outcomes po
          ON po.window_id = d.window_id AND po.stock_key = d.stock_key
        LEFT JOIN event_gate_lookup g ON g.event_id = d.event_id
        WHERE d.phase = 4
        GROUP BY d.event_id
        ORDER BY d.window_id, d.stock_id, d.trade_date
    """
    output: list[dict[str, object]] = []
    for row in connection.execute(query):
        score_with = float(row["decision_score"])
        score_without = score_with - 1.0
        routes_with = formal_routes(row, score_with)
        routes_without = formal_routes(row, score_without)
        route_decisive = bool(routes_with) and not routes_without
        gates = {value for value in str(row["passed_gates"] or "").split(",") if value}
        execution_eligible = "A-E" in gates
        decision_critical = route_decisive and execution_eligible
        phase_raw = row["fit_trend_phase"]
        phase_name = PHASE_NAMES.get(int(phase_raw), f"unknown_{phase_raw}") if phase_raw is not None else "missing"

        record: dict[str, object] = {
            "sample": sample,
            "event_id": int(row["event_id"]),
            "event_key": row["event_key"],
            "window_start": int(row["start_date"]),
            "window_end": int(row["end_date"]),
            "stock_id": row["stock_id"],
            "stock_name": row["stock_name"],
            "group_name": row["group_name"],
            "trade_date": int(row["trade_date"]),
            "grade": row["grade_name"],
            "grade_raw": int(row["grade"]),
            "trend_phase": phase_name,
            "trend_phase_raw": phase_raw,
            "fit_trend": row["fit_trend"],
            "score_with_ap02": score_with,
            "score_without_ap02": score_without,
            "routes_with_ap02": "+".join(routes_with),
            "routes_without_ap02": "+".join(routes_without),
            "route_decisive": int(route_decisive),
            "execution_eligible": int(execution_eligible),
            "decision_critical": int(decision_critical),
            "planned_action": row["planned_action"],
            "executed_action": row["executed_action"],
            "unit_roi_before": float(row["unit_roi_before"]),
            "holding_days_before": float(row["holding_days_before"]),
            "invest_times_before": float(row["invest_times_before"]),
            "buy_rule_before": row["buy_rule_before"],
            "period_roi": row["period_roi"],
            "period_average_days": row["period_average_days"],
            "period_rounds": row["period_rounds"],
            "period_grade": row["period_grade"],
        }
        for horizon in (5, 10, 20, 40):
            future_return, drawdown = forward_metrics(row, prices, horizon)
            record[f"return_{horizon}d"] = future_return
            record[f"drawdown_{horizon}d"] = drawdown
        output.append(record)
    connection.close()
    return output


def finite_values(rows: list[dict[str, object]], key: str) -> list[float]:
    values: list[float] = []
    for row in rows:
        value = row.get(key)
        if value is not None and math.isfinite(float(value)):
            values.append(float(value))
    return values


def metrics(rows: list[dict[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {"events": len(rows)}
    for key in ("return_5d", "return_10d", "return_20d", "return_40d", "period_roi"):
        values = finite_values(rows, key)
        result[f"{key}_count"] = len(values)
        result[f"{key}_mean"] = mean(values) if values else None
        result[f"{key}_median"] = median(values) if values else None
        result[f"{key}_positive_rate"] = (
            sum(value > 0 for value in values) / len(values) if values else None
        )
    return result


def grouped(rows: list[dict[str, object]], key: str) -> list[dict[str, object]]:
    groups: dict[str, list[dict[str, object]]] = defaultdict(list)
    for row in rows:
        groups[str(row[key])].append(row)
    return [{key: name, **metrics(items)} for name, items in sorted(groups.items())]


def format_number(value: object, digits: int = 3) -> str:
    if value is None:
        return "-"
    return f"{float(value):.{digits}f}"


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


def markdown_table(rows: list[dict[str, object]], label: str) -> list[str]:
    lines = [
        f"### {label}",
        "",
        "| 分界 | 關鍵事件 | 20日平均 | 20日中位 | 20日上漲率 | 期間ROI平均 |",
        "|---|---:|---:|---:|---:|---:|",
    ]
    for row in rows:
        group = row.get("trend_phase", row.get("grade", ""))
        positive_rate = row.get("return_20d_positive_rate")
        lines.append(
            "| {group} | {events} | {mean20} | {median20} | {rate20} | {period} |".format(
                group=group,
                events=row["events"],
                mean20=format_number(row.get("return_20d_mean")),
                median20=format_number(row.get("return_20d_median")),
                rate20=(f"{float(positive_rate) * 100:.1f}%" if positive_rate is not None else "-"),
                period=format_number(row.get("period_roi_mean")),
            )
        )
    lines.append("")
    return lines


def main() -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    complete = OUTPUT / ".complete"
    complete.unlink(missing_ok=True)

    all_rows: list[dict[str, object]] = []
    for sample, database in BASES.items():
        all_rows.extend(load_sample(sample, database))

    critical = [row for row in all_rows if row["decision_critical"] == 1]
    sample_summary: dict[str, dict[str, object]] = {}
    phase_rows: list[dict[str, object]] = []
    grade_rows: list[dict[str, object]] = []
    for sample in BASES:
        direct_sample = [row for row in all_rows if row["sample"] == sample]
        critical_sample = [row for row in critical if row["sample"] == sample]
        sample_summary[sample] = {
            "direct_votes": len(direct_sample),
            "formal_route_decisive": sum(int(row["route_decisive"]) for row in direct_sample),
            "execution_eligible_route_decisive": len(critical_sample),
            "critical_metrics": metrics(critical_sample),
            "distinct_stocks": len({row["stock_id"] for row in critical_sample}),
            "distinct_windows": len({(row["window_start"], row["window_end"]) for row in critical_sample}),
        }
        for item in grouped(critical_sample, "trend_phase"):
            phase_rows.append({"sample": sample, **item})
        for item in grouped(critical_sample, "grade"):
            grade_rows.append({"sample": sample, **item})

    summary = {
        "experiment_id": "GT-P10-D0-formal-route-v2",
        "baseline": "Baseline v14 / S26 / T2-S33 / DecisionBase v6",
        "hypothesis": "A-P02 的正式決策關鍵加碼在 Grade 趨勢情境中可能有可解釋的結果差異。",
        "method": {
            "A-T01": "[(ROI < Grade深虧門檻) 或 (ROI < -25 且持股 <180 或 >360日)] 且分數 >=3",
            "A-T02": "L買、-10 < ROI < 1、持股 <60日，low以下分數 >=2，其餘 >=3",
            "critical": "移除 A-P02 的 1 分後，A-T01/A-T02 均不再通過，且原事件通過 A-E 執行資格",
        },
        "samples": sample_summary,
        "total_direct_votes": len(all_rows),
        "total_critical_events": len(critical),
        "phase_boundaries": phase_rows,
        "grade_boundaries": grade_rows,
    }

    write_csv(OUTPUT / "all-ap02-events.csv", all_rows)
    write_csv(OUTPUT / "decision-critical-events.csv", critical)
    write_csv(OUTPUT / "phase-boundaries.csv", phase_rows)
    write_csv(OUTPUT / "grade-boundaries.csv", grade_rows)
    (OUTPUT / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    report = [
        "# GT-P10-D0 formal-route-v2：A-P02 趨勢情境診斷",
        "",
        "## 方法修正",
        "",
        "舊版把 ADD 當成單一 `decision_threshold`，不適用於正式 A-T01／A-T02 多路出口。本版逐事件移除 A-P02 的 1 分，分別重建兩條正式出口；只有兩條出口都因此關閉，而且原事件已通過 A-E，才列為決策關鍵事件。",
        "",
        "## A/B 摘要",
        "",
        "| Sample | A-P02直接票 | 出口關鍵 | 通過A-E的決策關鍵 | 股票數 | 窗口數 | 20日平均 | 20日上漲率 |",
        "|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for sample, item in sample_summary.items():
        critical_metrics = item["critical_metrics"]
        rate = critical_metrics["return_20d_positive_rate"]
        report.append(
            "| {sample} | {direct} | {route} | {critical} | {stocks} | {windows} | {mean20} | {rate20} |".format(
                sample=sample,
                direct=item["direct_votes"],
                route=item["formal_route_decisive"],
                critical=item["execution_eligible_route_decisive"],
                stocks=item["distinct_stocks"],
                windows=item["distinct_windows"],
                mean20=format_number(critical_metrics["return_20d_mean"]),
                rate20=(f"{float(rate) * 100:.1f}%" if rate is not None else "-"),
            )
        )
    report.append("")
    report.extend(markdown_table(phase_rows, "趨勢階段分界"))
    report.extend(markdown_table(grade_rows, "Grade 分界"))
    report.extend([
        "## 判讀界限",
        "",
        "這是既有正式決策的診斷，不是移除 A-P02 的反事實績效。只有跨樣本、跨股票或窗口出現方向一致且可解釋的分界，才足以提出下一個單一變因候選；事件少但已有這種方向時，應擴大樣本而非直接結案。",
        "",
    ])
    (OUTPUT / "report.md").write_text("\n".join(report), encoding="utf-8")
    complete.write_text("GT-P10-D0-formal-route-v2\n", encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
