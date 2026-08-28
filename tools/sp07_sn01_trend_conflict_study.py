#!/usr/bin/env python3
"""GT-P09-D0: study S-P07 and S-N01a/b opposing sell votes by trend phase."""

from __future__ import annotations

import argparse
import bisect
import csv
import json
import math
import sqlite3
import statistics
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from grade_trend_phase_price_context_study import load_prices, ymd_from_core_data


HORIZONS = (5, 10, 20, 60)
GRADE_NAMES = {3: "wow", 2: "high", 1: "fine", 0: "none", -1: "weak", -2: "low", -3: "damn"}
PHASE_NAMES = {
    0: "不可用", 1: "穩定", 2: "改善預警", 3: "惡化預警",
    4: "改善確認舊值", 5: "惡化確認舊值", 6: "改善確認後退回",
    7: "惡化確認後退回", 8: "改善探頂", 9: "改善拉回",
    10: "惡化探底", 11: "惡化反彈",
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


def open_readonly(path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    result = connection.execute("PRAGMA integrity_check").fetchone()[0]
    if result != "ok":
        connection.close()
        raise RuntimeError(f"SQLite integrity failed: {path}: {result}")
    return connection


def close_enough(value: Any, target: float) -> bool:
    return value is not None and math.isclose(float(value), target, abs_tol=1e-9)


def roi_threshold_for_st01c(grade: int) -> float:
    if grade <= -1:
        return 1.5
    if grade >= 3:
        return 2.25
    return 2.0


def opened_by_one_sell_vote(row: dict[str, Any]) -> list[str]:
    """Return formal exits that become eligible if the current score gains one."""
    score = float(row["decision_score"])
    roi = float(row["unit_roi_before"])
    days = float(row["holding_days_before"])
    grade = int(row["grade"])
    upper = grade >= 2
    gates: list[str] = []

    if roi > 22.5 and close_enough(score, 0.0 if upper else 1.0):
        gates.append("S-T01a")
    if roi > 0.45 and days > 1 and close_enough(score, 5.0):
        gates.append("S-T01b")
    if roi > roi_threshold_for_st01c(grade) and close_enough(score, 3.0):
        gates.append("S-T01c")
    if roi > 0.45 and days > 68 and close_enough(score, 3.0):
        gates.append("S-T01e")
    if roi > 15.5 and days < (60 if upper else 40) and close_enough(score, 2.0):
        gates.append("S-T01f")
    if roi > 9.5 and days < (30 if upper else 20) and close_enough(score, 2.0):
        gates.append("S-T01g")
    if roi > 6.5 and days < (10 if grade > -1 else 45) and close_enough(score, 2.0):
        gates.append("S-T01h")

    range_is_narrow = float(row["range_125"]) < 30
    st02b = days > 240 and range_is_narrow and (
        (grade > -1 and roi > -15) or ((days > 300 or grade <= -1) and roi > -20)
    )
    st02c = days > 400 and roi > (-20 if grade <= -1 else -15)
    threshold = 1.0 if grade >= 0 and days < 400 else 2.0
    if bool(row["no_recent_investment"]) and close_enough(score, threshold - 1):
        if st02b:
            gates.append("S-T02b")
        if st02c:
            gates.append("S-T02c")
    return gates


def load_sample(
    sample: str, database: Path, store: Path
) -> tuple[list[dict[str, Any]], dict[tuple[int, str], list[int]], dict[str, str]]:
    connection = open_readonly(database)
    try:
        metadata = dict(connection.execute("SELECT key, value FROM metadata"))
        unsafe = connection.execute(
            """
            SELECT
              SUM(CASE WHEN status IS NOT NULL
                        AND status NOT IN ('正常','completed','complete','ok')
                       THEN 1 ELSE 0 END),
              SUM(CASE WHEN COALESCE(money_lacked, 0) != 0 THEN 1 ELSE 0 END)
            FROM period_outcomes
            """
        ).fetchone()
        if any(int(value or 0) for value in unsafe):
            raise RuntimeError(
                f"Unsafe DecisionBase {database}: bad_status={unsafe[0]}, money_lacked={unsafe[1]}"
            )
        rows = [
            dict(row) | {"sample": sample}
            for row in connection.execute(
                """
                SELECT
                    e.event_id, e.window_id, e.trade_date, e.grade,
                    e.decision_score, e.planned_action, e.executed_action,
                    e.inventory_before, e.unit_cost_before, e.unit_roi_before,
                    e.holding_days_before, e.invest_times_before,
                    w.start_date AS window_start, w.end_date AS window_end,
                    s.stock_id, s.name AS stock_name, s.group_name,
                    sf.fit_trend_phase, sf.fit_trend, sf.grade_name,
                    EXISTS (
                        SELECT 1 FROM event_votes v JOIN rules r USING(rule_key)
                        WHERE v.event_id=e.event_id AND r.rule_id='S-P07'
                    ) AS has_sp07,
                    EXISTS (
                        SELECT 1 FROM event_votes v JOIN rules r USING(rule_key)
                        WHERE v.event_id=e.event_id AND r.rule_id='S-N01a'
                    ) AS has_sn01a,
                    EXISTS (
                        SELECT 1 FROM event_votes v JOIN rules r USING(rule_key)
                        WHERE v.event_id=e.event_id AND r.rule_id='S-N01b'
                    ) AS has_sn01b
                FROM decision_events e
                JOIN windows w USING(window_id)
                JOIN stocks s USING(stock_key)
                LEFT JOIN event_strategy_fit_observations esf USING(event_id)
                LEFT JOIN strategy_fit_observations sf USING(observation_id)
                WHERE e.phase=3 AND e.inventory_before>0
                ORDER BY e.window_id, s.stock_id, e.trade_date
                """
            )
        ]
        add_dates: dict[tuple[int, str], list[int]] = defaultdict(list)
        for row in connection.execute(
            """
            SELECT e.window_id, s.stock_id, e.trade_date
            FROM decision_events e JOIN stocks s USING(stock_key)
            WHERE e.phase=4 AND e.executed_action='ADD'
            ORDER BY e.window_id, s.stock_id, e.trade_date
            """
        ):
            add_dates[(int(row["window_id"]), str(row["stock_id"]))].append(
                int(row["trade_date"])
            )
    finally:
        connection.close()

    range_connection = open_readonly(store)
    try:
        ranges = {
            (str(row["stock_id"]), ymd_from_core_data(row["trade_time"])):
                float(row["low_diff"] or 0) - float(row["high_diff"] or 0)
            for row in range_connection.execute(
                """
                SELECT s.ZSID AS stock_id, t.ZDATETIME AS trade_time,
                       t.ZTLOWDIFF125 AS low_diff, t.ZTHIGHDIFF125 AS high_diff
                FROM ZTRADE t JOIN ZSTOCK s ON s.Z_PK=t.ZSTOCK
                ORDER BY s.ZSID, t.ZDATETIME
                """
            )
        }
    finally:
        range_connection.close()

    prices = load_prices(store)
    for row in rows:
        stock_id = str(row["stock_id"])
        trade_date = int(row["trade_date"])
        row["range_125"] = ranges[(stock_id, trade_date)]
        dates, _, indexes = prices[stock_id]
        additions = add_dates[(int(row["window_id"]), stock_id)]
        position = bisect.bisect_left(additions, trade_date) - 1
        recent = False
        if position >= 0 and additions[position] in indexes:
            recent = 0 < indexes[trade_date] - indexes[additions[position]] <= 60
        row["no_recent_investment"] = int(not recent)
    return rows, add_dates, metadata


def phase_name(value: Any) -> str:
    return PHASE_NAMES.get(int(value or 0), f"未知{value}")


def phase_family(value: Any) -> str:
    raw = int(value or 0)
    if raw == 3:
        return "惡化預警"
    if raw in (10, 11):
        return "惡化確認"
    return "其他"


def select_blocked_events(
    rows: list[dict[str, Any]]
) -> tuple[list[dict[str, Any]], Counter[str]]:
    grouped: dict[tuple[int, str], list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        grouped[(int(row["window_id"]), str(row["stock_id"]))].append(row)

    selected: list[dict[str, Any]] = []
    funnel: Counter[str] = Counter()
    for series in grouped.values():
        round_id = 0
        selected_keys: set[tuple[int, int]] = set()
        for row in series:
            if int(row["has_sp07"]):
                funnel["sp07_events"] += 1
            has_protection = int(row["has_sn01a"]) or int(row["has_sn01b"])
            if int(row["has_sp07"]) and has_protection:
                funnel["sp07_sn01_cooccurrences"] += 1
                planned = str(row["planned_action"]).upper()
                executed = str(row["executed_action"]).upper()
                gates = opened_by_one_sell_vote(row)
                phase = int(row["fit_trend_phase"] or 0)
                key = (round_id, phase)
                if planned == "HOLD" and executed == "NONE" and gates:
                    funnel["blocked_exit_rows"] += 1
                    if key not in selected_keys:
                        event = dict(row)
                        event["round_id"] = round_id
                        event["fit_phase_name"] = phase_name(phase)
                        event["fit_phase_family"] = phase_family(phase)
                        event["grade_name"] = row["grade_name"] or GRADE_NAMES.get(int(row["grade"]), "unknown")
                        event["opened_gates"] = "+".join(gates)
                        event["protection_rules"] = "+".join(
                            rule for rule, present in (
                                ("S-N01a", row["has_sn01a"]),
                                ("S-N01b", row["has_sn01b"]),
                            ) if int(present)
                        )
                        selected.append(event)
                        selected_keys.add(key)
                        funnel["selected_first_per_round_phase"] += 1
            if str(row["executed_action"]).upper() == "SELL":
                round_id += 1
    return selected, funnel


def decorate_outcomes(
    events: list[dict[str, Any]],
    all_rows: list[dict[str, Any]],
    prices: dict[str, tuple[list[int], list[float], dict[int, int]]],
) -> None:
    actual_sells: dict[tuple[int, str], list[dict[str, Any]]] = defaultdict(list)
    for row in all_rows:
        if str(row["executed_action"]).upper() == "SELL":
            actual_sells[(int(row["window_id"]), str(row["stock_id"]))].append(row)

    for event in events:
        stock_id = str(event["stock_id"])
        dates, closes, indexes = prices[stock_id]
        event_date = int(event["trade_date"])
        index = indexes[event_date]
        close = closes[index]
        event["close"] = close
        sells = actual_sells[(int(event["window_id"]), stock_id)]
        sell_dates = [int(row["trade_date"]) for row in sells]
        position = bisect.bisect_right(sell_dates, event_date)
        actual = sells[position] if position < len(sells) else None
        event["actual_sell_date"] = int(actual["trade_date"]) if actual else None
        event["actual_sell_roi_pct"] = float(actual["unit_roi_before"]) if actual else None
        event["waiting_roi_delta_pct"] = (
            float(actual["unit_roi_before"]) - float(event["unit_roi_before"])
            if actual else None
        )
        event["days_to_actual_sell"] = None
        event["return_to_actual_sell_pct"] = None
        event["minimum_return_to_actual_sell_pct"] = None
        event["maximum_return_to_actual_sell_pct"] = None
        if actual and int(actual["trade_date"]) in indexes:
            sell_index = indexes[int(actual["trade_date"])]
            path = closes[index + 1 : sell_index + 1]
            returns = [(value / close - 1.0) * 100.0 for value in path]
            event["days_to_actual_sell"] = sell_index - index
            if returns:
                event["return_to_actual_sell_pct"] = returns[-1]
                event["minimum_return_to_actual_sell_pct"] = min(returns)
                event["maximum_return_to_actual_sell_pct"] = max(returns)
        for horizon in HORIZONS:
            end = index + horizon
            if end >= len(closes) or dates[end] > int(event["window_end"]):
                event[f"return_{horizon}d_pct"] = None
                event[f"minimum_{horizon}d_pct"] = None
                event[f"maximum_{horizon}d_pct"] = None
                continue
            path = closes[index + 1 : end + 1]
            event[f"return_{horizon}d_pct"] = (closes[end] / close - 1.0) * 100.0
            event[f"minimum_{horizon}d_pct"] = (min(path) / close - 1.0) * 100.0
            event[f"maximum_{horizon}d_pct"] = (max(path) / close - 1.0) * 100.0


def numeric(rows: list[dict[str, Any]], field: str) -> list[float]:
    return [float(row[field]) for row in rows if row.get(field) is not None]


def mean_value(rows: list[dict[str, Any]], field: str) -> float | None:
    values = numeric(rows, field)
    return statistics.fmean(values) if values else None


def median_value(rows: list[dict[str, Any]], field: str) -> float | None:
    values = numeric(rows, field)
    return statistics.median(values) if values else None


def percentage(part: int, total: int) -> float | None:
    return part / total * 100.0 if total else None


def metrics(rows: list[dict[str, Any]]) -> dict[str, Any]:
    completed = [row for row in rows if row.get("actual_sell_date") is not None]
    result = {
        "events": len(rows),
        "rounds": len({(row["sample"], row["window_id"], row["stock_id"], row["round_id"]) for row in rows}),
        "stocks": len({(row["sample"], row["stock_id"]) for row in rows}),
        "windows": len({(row["sample"], row["window_id"]) for row in rows}),
        "completed_later_sells": len(completed),
        "censored": len(rows) - len(completed),
        "earlier_sell_better_rate_pct": percentage(
            sum(float(row["return_to_actual_sell_pct"]) < 0 for row in completed), len(completed)
        ),
        "mean_return_to_actual_sell_pct": mean_value(completed, "return_to_actual_sell_pct"),
        "median_return_to_actual_sell_pct": median_value(completed, "return_to_actual_sell_pct"),
        "mean_waiting_roi_delta_pct": mean_value(completed, "waiting_roi_delta_pct"),
        "mean_days_to_actual_sell": mean_value(completed, "days_to_actual_sell"),
        "mean_minimum_while_waiting_pct": mean_value(completed, "minimum_return_to_actual_sell_pct"),
    }
    for horizon in HORIZONS:
        field = f"return_{horizon}d_pct"
        valid = [row for row in rows if row.get(field) is not None]
        result[f"valid_{horizon}d"] = len(valid)
        result[f"mean_return_{horizon}d_pct"] = mean_value(valid, field)
        result[f"median_return_{horizon}d_pct"] = median_value(valid, field)
        result[f"fall_rate_{horizon}d_pct"] = percentage(
            sum(float(row[field]) < 0 for row in valid), len(valid)
        )
        result[f"mean_minimum_{horizon}d_pct"] = mean_value(valid, f"minimum_{horizon}d_pct")
    return result


def aggregate(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    output = []
    for scope in ("ALL", "A", "B"):
        scoped = events if scope == "ALL" else [row for row in events if row["sample"] == scope]
        for dimension, resolver in (
            ("全部", lambda row: "全部"),
            ("趨勢大段", lambda row: row["fit_phase_family"]),
            ("趨勢分段", lambda row: row["fit_phase_name"]),
            ("出口規則", lambda row: row["opened_gates"]),
        ):
            for condition in sorted({resolver(row) for row in scoped}):
                rows = [row for row in scoped if resolver(row) == condition]
                output.append(
                    {"scope": scope, "dimension": dimension, "condition": condition}
                    | metrics(rows)
                )
    return output


def concentration_rows(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    output = []
    for sample in ("A", "B"):
        for phase in sorted({row["fit_phase_name"] for row in events if row["sample"] == sample}):
            rows = [row for row in events if row["sample"] == sample and row["fit_phase_name"] == phase]
            for dimension, counts in (
                ("stock", Counter(row["stock_id"] for row in rows)),
                ("window", Counter(str(row["window_start"]) for row in rows)),
                ("grade", Counter(str(row["grade_name"]) for row in rows)),
                ("group", Counter(str(row["group_name"]) for row in rows)),
            ):
                for value, count in counts.most_common():
                    output.append(
                        {
                            "sample": sample, "phase": phase, "dimension": dimension,
                            "value": value, "event_count": count,
                            "share_pct": percentage(count, len(rows)),
                        }
                    )
    return output


def serializable(row: dict[str, Any]) -> dict[str, Any]:
    return {
        key: round(value, 6) if isinstance(value, float) and math.isfinite(value) else value
        for key, value in row.items()
    }


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    fields = list(dict.fromkeys(key for row in rows for key in row))
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(serializable(row) for row in rows)


def format_value(value: Any) -> str:
    if value is None:
        return "-"
    if isinstance(value, float):
        return f"{value:.3f}"
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
    summaries: list[dict[str, Any]], concentration: list[dict[str, Any]], funnels: dict[str, dict[str, int]]
) -> str:
    headline = [
        row for row in summaries
        if row["scope"] in ("A", "B")
        and row["dimension"] == "趨勢分段"
        and row["condition"] in ("惡化預警", "惡化探底", "惡化反彈")
    ]
    top = sorted(
        [row for row in concentration if row["dimension"] in ("stock", "window")],
        key=lambda row: (-(row["share_pct"] or 0), row["sample"], row["phase"]),
    )[:12]
    return f"""# GT-P09-D0 `S-P07 × S-N01a/b` 對向票

## 研究界線

- 固定 Baseline v14、`T2/S33`、策略 S26 的 Sample A／B DecisionBase v6。
- `S-P07` 在惡化預警／確認增加退出意願；`S-N01a/b` 在 MA60／MA20 九日低點合計保護一票。本研究不修改任何票。
- 主要事件為兩者共現、Baseline 未賣，且若拿掉低點保護的一票就會開啟既有正式出口；每個持股輪、每個趨勢分段只取第一次。
- 「提早賣較好」只表示後續 Baseline 實際賣價低於事件日，不是移除規則的完整反事實績效。

## 漏斗

```json
{json.dumps(funnels, ensure_ascii=False, indent=2)}
```

## 分段結果

{markdown_table(headline, [("scope", "Sample"), ("condition", "趨勢分段"), ("events", "事件"), ("rounds", "持股輪"), ("completed_later_sells", "後續賣出"), ("earlier_sell_better_rate_pct", "提早賣較好%"), ("mean_return_to_actual_sell_pct", "後續賣價變化%"), ("mean_waiting_roi_delta_pct", "等待ROI差"), ("mean_days_to_actual_sell", "等待交易日"), ("mean_minimum_while_waiting_pct", "等待最大下探%")])}

## 最高集中度

{markdown_table(top, [("sample", "Sample"), ("phase", "趨勢分段"), ("dimension", "維度"), ("value", "值"), ("event_count", "事件"), ("share_pct", "占比%")])}

## 判讀邊界

只有 A／B 在同一分段都有足夠事件，且提早賣價與等待 ROI 一致優於 Baseline 後續賣出、沒有單股或單一窗口主導，才可提出「該分段暫停 S-N01 低點保護」的單一候選。方向混合、等待反而改善、事件不足或集中時，保留 `S-P07` 與 `S-N01a/b` 的現行互補，不建立候選。
"""


def main() -> None:
    args = parse_args()
    specs = [parse_sample(value) for value in args.sample]
    if {sample for sample, _, _ in specs} != {"A", "B"}:
        raise RuntimeError("GT-P09-D0 requires exactly Sample A and B")

    all_events: list[dict[str, Any]] = []
    funnels: dict[str, dict[str, int]] = {}
    metadata_by_sample: dict[str, dict[str, str]] = {}
    sources = []
    for sample, database, store in specs:
        rows, _, metadata = load_sample(sample, database, store)
        if metadata.get("dataRuleVersion") != "T2/S33":
            raise RuntimeError(f"Sample {sample} is not T2/S33")
        if metadata.get("formatVersion") != "6":
            raise RuntimeError(f"Sample {sample} is not DecisionBase v6")
        events, funnel = select_blocked_events(rows)
        decorate_outcomes(events, rows, load_prices(store))
        all_events.extend(events)
        funnels[sample] = dict(funnel)
        metadata_by_sample[sample] = metadata
        sources.append(
            {
                "sample": sample, "decision_base": str(database),
                "decision_base_id": metadata.get("decisionBaseID"),
                "price_store": str(store),
            }
        )

    summaries = aggregate(all_events)
    concentration = concentration_rows(all_events)
    primary = [
        row for row in summaries
        if row["scope"] in ("A", "B") and row["dimension"] == "趨勢分段"
        and row["condition"] in ("惡化預警", "惡化探底", "惡化反彈")
    ]
    summary = {
        "study_id": "GT-P09-D0",
        "baseline": "Baseline v14 / T2/S33 / S26",
        "hypothesis": "S-P07 deterioration exit pressure and S-N01 moving-average-low protection may have different local value across worsening subphases",
        "changes_rule": False,
        "runs_candidate_backtest": False,
        "funnels": funnels,
        "selected_event_count": len(all_events),
        "primary_phase_results": primary,
    }
    manifest = {
        "run_id": "gt-p09-d0-sp07-sn01-conflict-ab-t2s33-20260828",
        "created_at": datetime.now(timezone.utc).isoformat(),
        "data_rule_version": "T2/S33",
        "strategy_rule_version": metadata_by_sample["A"].get("ruleVersion"),
        "rule_commit": metadata_by_sample["A"].get("ruleCommit"),
        "sources": sources,
        "reconstructable_exits": [
            "S-T01a", "S-T01b", "S-T01c", "S-T01e", "S-T01f",
            "S-T01g", "S-T01h", "S-T02b", "S-T02c",
        ],
        "excluded_exit": {"S-T01d": "DecisionBase does not retain K/D for every SELL event"},
        "files": [
            "summary.json", "manifest.json", "report.md", "events.csv",
            "condition-summary.csv", "concentration.csv", ".complete",
        ],
        "limitations": [
            "Earlier-sale comparison is observational and not a counterfactual replay.",
            "Each holding round contributes at most one event per exact trend subphase.",
            "Future prices and later Baseline exits never participate in event selection.",
            "A and B are selected research samples and do not establish general validity.",
        ],
    }
    args.output.mkdir(parents=True, exist_ok=True)
    write_csv(args.output / "events.csv", all_events)
    write_csv(args.output / "condition-summary.csv", summaries)
    write_csv(args.output / "concentration.csv", concentration)
    (args.output / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    (args.output / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    (args.output / "report.md").write_text(
        build_report(summaries, concentration, funnels), encoding="utf-8"
    )
    (args.output / ".complete").write_text("GT-P09-D0 complete\n", encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
