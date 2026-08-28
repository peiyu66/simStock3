#!/usr/bin/env python3
"""GT-P08-D0: diagnose whether trend context changes L-P09's local value."""

from __future__ import annotations

import argparse
import csv
import json
import math
import sqlite3
import statistics
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from grade_trend_phase_price_context_study import load_prices


HORIZONS = (5, 10, 20)
PHASE_NAMES = {
    0: "不可用",
    1: "穩定",
    2: "改善預警",
    3: "惡化預警",
    4: "改善確認舊值",
    5: "惡化確認舊值",
    6: "改善確認後退回",
    7: "惡化確認後退回",
    8: "改善探頂",
    9: "改善拉回",
    10: "惡化探底",
    11: "惡化反彈",
}
PHASE_FAMILIES = {
    8: "改善確認",
    9: "改善確認",
    10: "惡化確認",
    11: "惡化確認",
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


def close_enough(value: Any, target: Any) -> bool:
    return (
        value is not None
        and target is not None
        and math.isclose(float(value), float(target), abs_tol=1e-9)
    )


def load_decisions(
    sample: str, path: Path
) -> tuple[list[dict[str, Any]], dict[str, str]]:
    connection = open_readonly(path)
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
                f"Unsafe DecisionBase {path}: bad_status={unsafe[0]}, money_lacked={unsafe[1]}"
            )
        rows = [
            dict(row) | {"sample": sample}
            for row in connection.execute(
                """
                SELECT
                    e.event_id, e.window_id, e.stock_key, e.trade_date,
                    e.phase AS decision_phase, e.grade, e.decision_score,
                    e.decision_threshold, e.planned_action, e.executed_action,
                    e.inventory_before, e.unit_roi_before,
                    e.holding_days_before, e.invest_times_before,
                    e.roll_rounds_before,
                    w.start_date AS window_start, w.end_date AS window_end,
                    s.stock_id, s.name AS stock_name, s.group_name,
                    sf.fit_trend_phase, sf.fit_trend, sf.grade_name,
                    EXISTS (
                        SELECT 1
                        FROM event_votes v JOIN rules r USING(rule_key)
                        WHERE v.event_id = e.event_id AND r.rule_id = 'L-P09'
                    ) AS has_lp09
                FROM decision_events e
                JOIN windows w USING(window_id)
                JOIN stocks s USING(stock_key)
                LEFT JOIN event_strategy_fit_observations esf USING(event_id)
                LEFT JOIN strategy_fit_observations sf USING(observation_id)
                WHERE e.phase IN (1, 2, 3, 4)
                ORDER BY e.window_id, e.stock_key, e.trade_date, e.phase
                """
            )
        ]
    finally:
        connection.close()
    return rows, metadata


def phase_name(value: Any) -> str:
    return PHASE_NAMES.get(int(value or 0), f"未知{value}")


def phase_family(value: Any) -> str:
    raw = int(value or 0)
    return PHASE_FAMILIES.get(raw, "非確認期")


def build_round_outcomes(rows: list[dict[str, Any]]) -> dict[int, dict[str, Any]]:
    grouped: dict[tuple[int, int], list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        grouped[(int(row["window_id"]), int(row["stock_key"]))].append(row)

    outcomes: dict[int, dict[str, Any]] = {}
    for series in grouped.values():
        active: dict[str, Any] | None = None
        add_count = 0
        for row in series:
            action = str(row["executed_action"]).upper()
            if action == "BUY" and float(row["inventory_before"]) == 0:
                if active is not None:
                    raise RuntimeError(
                        f"overlapping BUY: {row['sample']} {row['stock_id']} {row['trade_date']}"
                    )
                active = row
                add_count = 0
                continue
            if active is None:
                continue
            if int(row["decision_phase"]) == 4 and action == "ADD":
                add_count += 1
                continue
            if int(row["decision_phase"]) != 3 or action != "SELL":
                continue
            outcomes[int(active["event_id"])] = {
                "completed_round": 1,
                "sell_date": int(row["trade_date"]),
                "sell_roi_pct": float(row["unit_roi_before"]),
                "holding_days": int(row["holding_days_before"]),
                "add_count": add_count,
            }
            active = None
            add_count = 0
        if active is not None:
            outcomes[int(active["event_id"])] = {
                "completed_round": 0,
                "sell_date": None,
                "sell_roi_pct": None,
                "holding_days": None,
                "add_count": add_count,
            }
    return outcomes


def decorate_price_path(
    event: dict[str, Any],
    context: tuple[list[int], list[float], dict[int, int]],
) -> None:
    dates, closes, indexes = context
    index = indexes.get(int(event["trade_date"]))
    if index is None:
        raise RuntimeError(
            f"missing price: {event['sample']} {event['stock_id']} {event['trade_date']}"
        )
    close = closes[index]
    event["close"] = close
    event["price_year"] = int(event["trade_date"]) // 10000
    for horizon in HORIZONS:
        end = index + horizon
        if end >= len(closes) or dates[end] > int(event["window_end"]):
            event[f"return_{horizon}d_pct"] = None
            event[f"mfe_{horizon}d_pct"] = None
            event[f"mae_{horizon}d_pct"] = None
            continue
        path = closes[index + 1 : end + 1]
        event[f"return_{horizon}d_pct"] = (closes[end] / close - 1.0) * 100.0
        event[f"mfe_{horizon}d_pct"] = (max(path) / close - 1.0) * 100.0
        event[f"mae_{horizon}d_pct"] = (min(path) / close - 1.0) * 100.0


def select_events_and_controls(
    rows: list[dict[str, Any]],
    prices: dict[str, tuple[list[int], list[float], dict[int, int]]],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], Counter[str]]:
    outcomes = build_round_outcomes(rows)
    direct: list[dict[str, Any]] = []
    controls: list[dict[str, Any]] = []
    funnel: Counter[str] = Counter()
    for source in rows:
        if int(source["decision_phase"]) != 2 or float(source["inventory_before"]) != 0:
            continue
        action = str(source["executed_action"]).upper()
        score_at_threshold = close_enough(source["decision_score"], source["decision_threshold"])
        row = dict(source)
        row["fit_phase_name"] = phase_name(row["fit_trend_phase"])
        row["fit_phase_family"] = phase_family(row["fit_trend_phase"])
        row |= outcomes.get(
            int(row["event_id"]),
            {
                "completed_round": 0,
                "sell_date": None,
                "sell_roi_pct": None,
                "holding_days": None,
                "add_count": None,
            },
        )
        if str(row["stock_id"]) not in prices:
            raise RuntimeError(f"missing stock prices for {row['stock_id']}")
        decorate_price_path(row, prices[str(row["stock_id"])])
        if int(row["has_lp09"]) == 1:
            funnel["direct_vote_events"] += 1
            row["decisive_lp09_buy"] = int(score_at_threshold and action == "BUY")
            if row["decisive_lp09_buy"]:
                funnel["decisive_buy_events"] += 1
            direct.append(row)
        elif score_at_threshold and action == "BUY":
            funnel["eligible_control_buys"] += 1
            row["decisive_lp09_buy"] = 0
            controls.append(row)
    return direct, controls, funnel


def date_ordinal(value: int) -> int:
    return datetime.strptime(str(value), "%Y%m%d").date().toordinal()


def match_controls(
    decisive: list[dict[str, Any]], controls: list[dict[str, Any]]
) -> None:
    grouped: dict[tuple[Any, ...], list[dict[str, Any]]] = defaultdict(list)
    for control in controls:
        key = (
            control["sample"], control["window_id"], control["stock_id"],
            control["price_year"], control["grade_name"], control["fit_trend_phase"],
        )
        grouped[key].append(control)
    used: set[int] = set()
    for event in sorted(decisive, key=lambda row: (row["sample"], row["trade_date"])):
        key = (
            event["sample"], event["window_id"], event["stock_id"],
            event["price_year"], event["grade_name"], event["fit_trend_phase"],
        )
        choices = [row for row in grouped.get(key, []) if int(row["event_id"]) not in used]
        if not choices:
            event["control_event_id"] = None
            continue
        target = date_ordinal(int(event["trade_date"]))
        control = min(
            choices,
            key=lambda row: (
                abs(date_ordinal(int(row["trade_date"])) - target),
                int(row["trade_date"]),
            ),
        )
        used.add(int(control["event_id"]))
        event["control_event_id"] = int(control["event_id"])
        event["control_trade_date"] = int(control["trade_date"])
        for field in (
            "sell_roi_pct", "holding_days", "add_count", "completed_round",
            "return_5d_pct", "return_10d_pct", "return_20d_pct",
            "mfe_20d_pct", "mae_20d_pct",
        ):
            event[f"control_{field}"] = control.get(field)
        for field in ("sell_roi_pct", "return_5d_pct", "return_10d_pct", "return_20d_pct"):
            left = event.get(field)
            right = control.get(field)
            event[f"paired_{field}_edge"] = (
                float(left) - float(right)
                if left is not None and right is not None else None
            )


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
    completed = [row for row in rows if row.get("completed_round") == 1]
    matched = [row for row in rows if row.get("control_event_id") is not None]
    result = {
        "events": len(rows),
        "stocks": len({row["stock_id"] for row in rows}),
        "windows": len({row["window_id"] for row in rows}),
        "completed_rounds": len(completed),
        "matched_controls": len(matched),
        "mean_sell_roi_pct": mean_value(completed, "sell_roi_pct"),
        "median_sell_roi_pct": median_value(completed, "sell_roi_pct"),
        "positive_sell_roi_rate_pct": percentage(
            sum(float(row["sell_roi_pct"]) > 0 for row in completed), len(completed)
        ),
        "mean_holding_days": mean_value(completed, "holding_days"),
        "mean_add_count": mean_value(completed, "add_count"),
        "mean_paired_sell_roi_edge": mean_value(matched, "paired_sell_roi_pct_edge"),
        "median_paired_sell_roi_edge": median_value(matched, "paired_sell_roi_pct_edge"),
    }
    for horizon in HORIZONS:
        field = f"return_{horizon}d_pct"
        valid = [row for row in rows if row.get(field) is not None]
        result[f"valid_{horizon}d"] = len(valid)
        result[f"mean_return_{horizon}d_pct"] = mean_value(valid, field)
        result[f"median_return_{horizon}d_pct"] = median_value(valid, field)
        result[f"rise_rate_{horizon}d_pct"] = percentage(
            sum(float(row[field]) > 0 for row in valid), len(valid)
        )
        result[f"mean_mfe_{horizon}d_pct"] = mean_value(valid, f"mfe_{horizon}d_pct")
        result[f"mean_mae_{horizon}d_pct"] = mean_value(valid, f"mae_{horizon}d_pct")
        result[f"mean_paired_return_{horizon}d_edge"] = mean_value(
            matched, f"paired_return_{horizon}d_pct_edge"
        )
    return result


def aggregate(
    direct: list[dict[str, Any]], decisive: list[dict[str, Any]]
) -> list[dict[str, Any]]:
    output: list[dict[str, Any]] = []
    scopes = ("ALL", "A", "B")
    dimensions = (
        ("全部", lambda row: "全部"),
        ("趨勢大段", lambda row: row["fit_phase_family"]),
        ("趨勢分段", lambda row: row["fit_phase_name"]),
    )
    for scope in scopes:
        scoped_direct = direct if scope == "ALL" else [row for row in direct if row["sample"] == scope]
        scoped_decisive = decisive if scope == "ALL" else [row for row in decisive if row["sample"] == scope]
        for dimension, resolver in dimensions:
            conditions = sorted({resolver(row) for row in scoped_direct})
            for condition in conditions:
                rows = [row for row in scoped_decisive if resolver(row) == condition]
                direct_count = sum(resolver(row) == condition for row in scoped_direct)
                output.append(
                    {
                        "scope": scope,
                        "dimension": dimension,
                        "condition": condition,
                        "direct_vote_events": direct_count,
                        "decisive_rate_pct": percentage(len(rows), direct_count),
                    }
                    | metrics(rows)
                )
    return output


def concentration_rows(decisive: list[dict[str, Any]]) -> list[dict[str, Any]]:
    output = []
    for sample in ("A", "B"):
        for family in ("改善確認", "惡化確認", "非確認期"):
            rows = [
                row for row in decisive
                if row["sample"] == sample and row["fit_phase_family"] == family
            ]
            for dimension, values in (
                ("stock", Counter(row["stock_id"] for row in rows)),
                ("window", Counter(str(row["window_start"]) for row in rows)),
                ("grade", Counter(str(row["grade_name"]) for row in rows)),
                ("group", Counter(str(row["group_name"]) for row in rows)),
            ):
                for value, count in values.most_common():
                    output.append(
                        {
                            "sample": sample,
                            "phase_family": family,
                            "dimension": dimension,
                            "value": value,
                            "event_count": count,
                            "share_pct": percentage(count, len(rows)),
                        }
                    )
    return output


def serializable(row: dict[str, Any]) -> dict[str, Any]:
    return {
        key: (round(value, 6) if isinstance(value, float) and math.isfinite(value) else value)
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
    summary_rows: list[dict[str, Any]], concentration: list[dict[str, Any]], funnel: dict[str, dict[str, int]]
) -> str:
    headline = [
        row for row in summary_rows
        if row["scope"] in ("A", "B")
        and row["dimension"] in ("趨勢大段", "趨勢分段")
        and row["condition"] in ("改善確認", "惡化確認", "改善探頂", "改善拉回", "惡化探底", "惡化反彈")
    ]
    concentration_top = sorted(
        [row for row in concentration if row["dimension"] in ("stock", "window")],
        key=lambda row: (-(row["share_pct"] or 0), row["sample"], row["phase_family"]),
    )[:12]
    return f"""# GT-P08-D0 `L-P09 × Grade 趨勢情境`

## 研究界線

- 正式基準為 Baseline v14、`T2/S33`、策略 S26；只讀 Sample A／B 固定三年 DecisionBase v6。
- `L-P09` 正式描述為「良好評等股票強烈拉回」。本研究不修改其技術條件或票數。
- 主要事件限定為 `L-P09 +1` 恰好使 L 買分數到達正式門檻並實際買進；因此是在正式 Baseline 路徑中觀察結果，不是移除該票的反事實回測。
- 配對控制為同股票、窗口、年度、exact Grade、exact Grade 趨勢分段，且同樣恰在 L 買門檻成交、但沒有 `L-P09` 票的事件。

## 漏斗

```json
{json.dumps(funnel, ensure_ascii=False, indent=2)}
```

## 趨勢情境結果

{markdown_table(headline, [("scope", "Sample"), ("condition", "趨勢情境"), ("direct_vote_events", "直接票"), ("events", "決定性買進"), ("completed_rounds", "完成輪次"), ("matched_controls", "配對"), ("mean_sell_roi_pct", "賣出ROI平均%"), ("mean_holding_days", "持股日平均"), ("mean_return_20d_pct", "20日平均%"), ("mean_paired_sell_roi_edge", "相對配對輪次ROI差")])}

## 最高集中度

{markdown_table(concentration_top, [("sample", "Sample"), ("phase_family", "趨勢大段"), ("dimension", "維度"), ("value", "值"), ("event_count", "事件"), ("share_pct", "占比%")])}

## 停止與候選邊界

只有改善確認在 A／B 都有足夠決定性事件、完成輪次結果一致優於惡化確認，而且相對同階段配對買進仍有優勢，才可提出一條固定的 `L-P09` 趨勢候選。若任一 Sample 事件太少、改善與惡化方向反轉、結果集中單股／窗口，或只是整體市場環境較強，則停止本方向，不把觀察結果直接寫入正式規則。
"""


def main() -> None:
    args = parse_args()
    specs = [parse_sample(value) for value in args.sample]
    if {sample for sample, _, _ in specs} != {"A", "B"}:
        raise RuntimeError("GT-P08-D0 requires exactly Sample A and B")

    all_direct: list[dict[str, Any]] = []
    all_controls: list[dict[str, Any]] = []
    funnels: dict[str, dict[str, int]] = {}
    metadata_by_sample: dict[str, dict[str, str]] = {}
    sources = []
    for sample, database, store in specs:
        rows, metadata = load_decisions(sample, database)
        if metadata.get("dataRuleVersion") != "T2/S33":
            raise RuntimeError(f"Sample {sample} is not T2/S33")
        if metadata.get("formatVersion") != "6":
            raise RuntimeError(f"Sample {sample} is not DecisionBase v6")
        direct, controls, funnel = select_events_and_controls(rows, load_prices(store))
        all_direct.extend(direct)
        all_controls.extend(controls)
        funnels[sample] = dict(funnel)
        metadata_by_sample[sample] = metadata
        sources.append(
            {
                "sample": sample,
                "decision_base": str(database),
                "decision_base_id": metadata.get("decisionBaseID"),
                "price_store": str(store),
            }
        )

    decisive = [row for row in all_direct if row["decisive_lp09_buy"] == 1]
    match_controls(decisive, all_controls)
    summary_rows = aggregate(all_direct, decisive)
    concentration = concentration_rows(decisive)

    args.output.mkdir(parents=True, exist_ok=True)
    write_csv(args.output / "direct-events.csv", all_direct)
    write_csv(args.output / "decisive-events.csv", decisive)
    write_csv(args.output / "eligible-controls.csv", all_controls)
    write_csv(args.output / "condition-summary.csv", summary_rows)
    write_csv(args.output / "concentration.csv", concentration)

    primary = [
        row for row in summary_rows
        if row["scope"] in ("A", "B")
        and row["dimension"] == "趨勢大段"
        and row["condition"] in ("改善確認", "惡化確認", "非確認期")
    ]
    summary = {
        "study_id": "GT-P08-D0",
        "baseline": "Baseline v14 / T2/S33 / S26",
        "hypothesis": "L-P09 strong-pullback votes may have different local value under improving versus worsening Grade-trend context",
        "changes_rule": False,
        "runs_candidate_backtest": False,
        "funnels": funnels,
        "direct_vote_event_count": len(all_direct),
        "decisive_buy_event_count": len(decisive),
        "eligible_control_count": len(all_controls),
        "primary_phase_family_results": primary,
    }
    manifest = {
        "run_id": "gt-p08-d0-lp09-trend-context-ab-t2s33-20260828",
        "created_at": datetime.now(timezone.utc).isoformat(),
        "data_rule_version": "T2/S33",
        "strategy_rule_version": metadata_by_sample["A"].get("ruleVersion"),
        "rule_commit": metadata_by_sample["A"].get("ruleCommit"),
        "sources": sources,
        "files": [
            "summary.json", "manifest.json", "report.md", "direct-events.csv",
            "decisive-events.csv", "eligible-controls.csv", "condition-summary.csv",
            "concentration.csv", ".complete",
        ],
        "limitations": [
            "Observed decisive baseline buys are not a counterfactual removal replay.",
            "Future price and completed-round outcomes never participate in event selection.",
            "Matched controls require same stock, window, year, exact Grade, and exact trend subphase.",
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
        build_report(summary_rows, concentration, funnels), encoding="utf-8"
    )
    (args.output / ".complete").write_text("GT-P08-D0 complete\n", encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
