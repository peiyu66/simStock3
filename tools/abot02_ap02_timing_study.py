#!/usr/bin/env python3
"""A-BOT02-D0-ABCDE: inspect whether pivotal non-bottom A-P02 adds can wait."""

from __future__ import annotations

import argparse
import csv
import json
import math
import sqlite3
import statistics
from collections import defaultdict
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from abot01_non_bottom_add_penalty_study import (
    EXPECTED_COMMON,
    EXPECTED_SAMPLES,
    PHASE_NAMES,
    connect_readonly,
    decision_base_specs,
    formal_routes,
    load_sample,
    verify_identity,
)


STUDY_ID = "A-BOT02-D0-ABCDE"
TAIPEI = ZoneInfo("Asia/Taipei")
HORIZONS = (1, 3, 5)
BOTTOM_PHASE = 10


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--decision-base",
        action="append",
        required=True,
        metavar="SAMPLE=DIR",
        help="Repeat once for each Sample A, B, C, D, and E.",
    )
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def write_csv(path: Path, rows: list[dict]) -> None:
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    fields: list[str] = []
    for row in rows:
        for field in row:
            if field not in fields:
                fields.append(field)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def median(rows: list[dict], field: str) -> float | None:
    values = [
        float(row[field])
        for row in rows
        if row.get(field) is not None and math.isfinite(float(row[field]))
    ]
    return statistics.median(values) if values else None


def fmt(value: object, digits: int = 3) -> str:
    if value is None:
        return "—"
    return f"{float(value):.{digits}f}"


def load_future_rows(directory: Path, target: dict) -> tuple[list[dict], dict]:
    connection = connect_readonly(directory / "decisions.sqlite")
    connection.row_factory = sqlite3.Row
    votes: dict[int, dict[str, float]] = defaultdict(dict)
    for event_id, rule_id, contribution in connection.execute(
        """
        SELECT v.event_id,v.rule_id,v.contribution
        FROM event_vote_lookup v JOIN decision_events e USING(event_id)
        WHERE e.phase=4 AND e.window_id=?
          AND e.stock_key=(SELECT stock_key FROM stocks WHERE stock_id=?)
        """,
        (target["window_id"], target["stock_id"]),
    ):
        votes[int(event_id)][str(rule_id)] = float(contribution)
    gates = {
        int(row[0])
        for row in connection.execute(
            """
            SELECT g.event_id FROM event_gate_lookup g
            JOIN decision_events e USING(event_id)
            WHERE g.rule_id='A-E' AND e.phase=4 AND e.window_id=?
              AND e.stock_key=(SELECT stock_key FROM stocks WHERE stock_id=?)
            """,
            (target["window_id"], target["stock_id"]),
        )
    }
    query = """
        SELECT d.*,sf.fit_trend_phase,sf.fit_observation_count,
               g.decision_score grade_efficiency_score,
               l.planned_action l_planned_action
        FROM decision_event_lookup d
        LEFT JOIN event_strategy_fit_observations eso USING(event_id)
        LEFT JOIN strategy_fit_observations sf USING(observation_id)
        LEFT JOIN decision_events g ON g.window_id=d.window_id
          AND g.stock_key=d.stock_key AND g.trade_date=d.trade_date AND g.phase=0
        LEFT JOIN decision_events l ON l.window_id=d.window_id
          AND l.stock_key=d.stock_key AND l.trade_date=d.trade_date AND l.phase=2
        WHERE d.phase=4 AND d.window_id=? AND d.stock_id=? AND d.trade_date>=?
        ORDER BY d.trade_date
        LIMIT 6
    """
    previous = connection.execute(
        """
        SELECT event_id,trade_date FROM decision_events
        WHERE phase=4 AND window_id=?
          AND stock_key=(SELECT stock_key FROM stocks WHERE stock_id=?)
          AND trade_date<? ORDER BY trade_date DESC LIMIT 1
        """,
        (target["window_id"], target["stock_id"], target["trade_date"]),
    ).fetchone()
    previous_state = {
        "previous_trade_date": int(previous["trade_date"]) if previous else None,
        "previous_a_p02": int(
            previous is not None
            and votes[int(previous["event_id"])].get("A-P02", 0.0) > 0
        ),
    }
    result: list[dict] = []
    for offset, raw in enumerate(
        connection.execute(
            query,
            (target["window_id"], target["stock_id"], target["trade_date"]),
        )
    ):
        row = dict(raw)
        if offset == 0 and int(row["trade_date"]) != int(target["trade_date"]):
            raise ValueError(f"target event missing: {target['cycle_key']}")
        event_votes = votes[int(row["event_id"])]
        close = float(row["unit_cost_before"]) * (
            1.0 + float(row["unit_roi_before"]) / 100.0
        )
        routes = formal_routes(row, float(row["decision_score"]))
        result.append(
            {
                "offset": offset,
                "event_id": int(row["event_id"]),
                "trade_date": int(row["trade_date"]),
                "grade": str(row["grade_name"]),
                "grade_efficiency_score": float(row["grade_efficiency_score"]),
                "trend_phase_raw": int(row["fit_trend_phase"]),
                "trend_phase": PHASE_NAMES.get(
                    int(row["fit_trend_phase"]), f"unknown_{row['fit_trend_phase']}"
                ),
                "fit_observation_count": int(row["fit_observation_count"]),
                "a_p02": int(event_votes.get("A-P02", 0.0) > 0),
                "decision_score": float(row["decision_score"]),
                "formal_routes": "+".join(routes),
                "a_e_actual_gate": int(int(row["event_id"]) in gates),
                "planned_action": str(row["planned_action"]),
                "executed_action": str(row["executed_action"]),
                "unit_roi_before": float(row["unit_roi_before"]),
                "holding_days_before": float(row["holding_days_before"]),
                "invest_times_before": float(row["invest_times_before"]),
                "close_proxy": close,
                "all_votes": "|".join(
                    f"{key}:{event_votes[key]:g}" for key in sorted(event_votes)
                ),
            }
        )
    connection.close()
    return result, previous_state


def inspect_target(sample: str, directory: Path, target: dict) -> tuple[dict, list[dict]]:
    future, previous = load_future_rows(directory, target)
    if not future:
        raise ValueError(f"no future rows for {target['cycle_key']}")
    start_close = float(future[0]["close_proxy"])
    daily: list[dict] = []
    for row in future:
        value = {
            "sample": sample,
            "cycle_key": target["cycle_key"],
            "window_start": target["window_start"],
            "window_end": target["window_end"],
            "stock_id": target["stock_id"],
            "stock_name": target["stock_name"],
            **row,
            "price_return_from_start": 100.0
            * (float(row["close_proxy"]) / start_close - 1.0),
            "bottom_with_ap02": int(
                int(row["trend_phase_raw"]) == BOTTOM_PHASE and int(row["a_p02"]) == 1
            ),
        }
        daily.append(value)

    result = {
        "sample": sample,
        "cycle_key": target["cycle_key"],
        "window_start": target["window_start"],
        "window_end": target["window_end"],
        "stock_id": target["stock_id"],
        "stock_name": target["stock_name"],
        "group_name": target["group_name"],
        "trade_date": target["trade_date"],
        "source_trend_phase": target["trend_phase"],
        "source_trend_phase_raw": target["trend_phase_raw"],
        "source_grade_score": target["grade_efficiency_score"],
        "source_decision_score": target["decision_score"],
        "source_unit_roi": target["unit_roi_before"],
        **previous,
        "source_first_ap02_day": int(previous["previous_a_p02"] == 0),
        "cycle_roi": target["cycle_roi"],
        "cycle_holding_days": target["cycle_holding_days"],
        "cycle_score": target["cycle_score"],
    }
    future_only = daily[1:]
    for horizon in HORIZONS:
        exact = next((row for row in daily if int(row["offset"]) == horizon), None)
        result[f"complete_{horizon}d"] = int(exact is not None)
        for field in (
            "trade_date",
            "trend_phase",
            "trend_phase_raw",
            "a_p02",
            "price_return_from_start",
            "grade",
            "grade_efficiency_score",
            "decision_score",
            "formal_routes",
            "a_e_actual_gate",
            "planned_action",
            "executed_action",
        ):
            result[f"{field}_{horizon}d"] = exact.get(field) if exact else None
        within = future_only[:horizon]
        matches = [
            row
            for row in within
            if row["bottom_with_ap02"] == 1 and row["price_return_from_start"] < 0
        ]
        first = matches[0] if matches else None
        result[f"bottom_ap02_lower_within_{horizon}d"] = int(first is not None)
        result[f"first_match_offset_within_{horizon}d"] = first["offset"] if first else None
        result[f"first_match_date_within_{horizon}d"] = first["trade_date"] if first else None
        result[f"first_match_return_within_{horizon}d"] = (
            first["price_return_from_start"] if first else None
        )
        if horizon == 1:
            result["next_day_ap02_lower"] = int(
                exact is not None
                and int(exact["a_p02"]) == 1
                and float(exact["price_return_from_start"]) < 0
            )
    return result, daily


def summary_row(scope: str, rows: list[dict]) -> dict:
    value = {
        "scope": scope,
        "events": len(rows),
        "stocks": len({(row["sample"], row["stock_id"]) for row in rows}),
        "windows": len({(row["sample"], row["window_start"]) for row in rows}),
        "source_worsening_warning": sum(
            row["source_trend_phase"] == "worsening_warning" for row in rows
        ),
        "source_improving_pulling_back": sum(
            row["source_trend_phase"] == "improving_pulling_back" for row in rows
        ),
        "source_worsening_rebounding": sum(
            row["source_trend_phase"] == "worsening_rebounding" for row in rows
        ),
        "source_first_ap02_day": sum(row["source_first_ap02_day"] for row in rows),
        "next_day_ap02_lower": sum(row.get("next_day_ap02_lower", 0) for row in rows),
        "first_day_next_day_ap02_lower": sum(
            row["source_first_ap02_day"] and row.get("next_day_ap02_lower", 0)
            for row in rows
        ),
        "median_cycle_score": median(rows, "cycle_score"),
    }
    for horizon in HORIZONS:
        complete = [row for row in rows if row[f"complete_{horizon}d"]]
        matched = [
            row for row in complete if row[f"bottom_ap02_lower_within_{horizon}d"]
        ]
        value[f"complete_{horizon}d"] = len(complete)
        value[f"ap02_exact_{horizon}d"] = sum(
            int(row[f"a_p02_{horizon}d"] or 0) for row in complete
        )
        value[f"bottom_exact_{horizon}d"] = sum(
            int(row[f"trend_phase_raw_{horizon}d"] or -1) == BOTTOM_PHASE
            for row in complete
        )
        value[f"bottom_ap02_lower_within_{horizon}d"] = len(matched)
        value[f"median_match_return_within_{horizon}d"] = median(
            matched, f"first_match_return_within_{horizon}d"
        )
    return value


def render_report(summary: list[dict], targets: list[dict]) -> str:
    lookup = {row["scope"]: row for row in summary}
    all_row = lookup["ALL"]
    lines = [
        f"# {STUDY_ID}",
        "",
        "只讀 Baseline v19 A～E DecisionBase v6，不修改規則或重播模擬。對象是 A-BOT01-D0 中被 A-P02 例外保護、Grade exact wow、趨勢已暖機、非惡化確認探底，且扣除一分會使正式 A-T01／A-T02 均不再成立的每輪第一個正式加碼。",
        "",
        "## 起始事件",
        "",
        f"共有 {all_row['events']} 輪、{all_row['stocks']} 檔股票；起始階段為惡化預警 {all_row['source_worsening_warning']}、改善拉回 {all_row['source_improving_pulling_back']}、惡化反彈 {all_row['source_worsening_rebounding']}。其中 {all_row['source_first_ap02_day']} 輪是前一交易日尚無 A-P02 的首次成立日；全部事件有 {all_row['next_day_ap02_lower']} 輪隔日 A-P02 仍成立且價格更低，首次成立子集則有 {all_row['first_day_next_day_ap02_lower']} 輪。",
        "",
        "| Sample | 事件 | A-P02 首日 | 隔日仍有 A-P02 且更低 | 首日子集隔日仍有且更低 | 1 日內探底＋A-P02＋更低價 | 3 日內 | 5 日內 |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for scope in (*"ABCDE", "ALL"):
        row = lookup[scope]
        lines.append(
            f"| {scope} | {row['events']} | {row['source_first_ap02_day']} | "
            f"{row['next_day_ap02_lower']} | {row['first_day_next_day_ap02_lower']} | "
            f"{row['bottom_ap02_lower_within_1d']} | "
            f"{row['bottom_ap02_lower_within_3d']} | "
            f"{row['bottom_ap02_lower_within_5d']} |"
        )
    lines.extend(
        [
            "",
            "## 精確日訊號",
            "",
            "| 期間 | 完整事件 | A-P02 仍成立 | 已在惡化探底 | 期間內同時探底、A-P02、價格更低 | 命中價格變化中位 |",
            "| --- | ---: | ---: | ---: | ---: | ---: |",
        ]
    )
    for horizon in HORIZONS:
        lines.append(
            f"| {horizon} 日 | {all_row[f'complete_{horizon}d']} | "
            f"{all_row[f'ap02_exact_{horizon}d']} | "
            f"{all_row[f'bottom_exact_{horizon}d']} | "
            f"{all_row[f'bottom_ap02_lower_within_{horizon}d']} | "
            f"{fmt(all_row[f'median_match_return_within_{horizon}d'])}% |"
        )
    lines.extend(
        [
            "",
            "## 逐例",
            "",
            "| Sample | 股票 | 窗口 | 日期 | 起始階段 | A-P02 首日 | 隔日同票且更低 | 當輪分數 | 1／3／5 日內探底命中 |",
            "| --- | --- | --- | --- | --- | --- | --- | ---: | --- |",
        ]
    )
    for row in targets:
        hits = "／".join(
            "是" if row[f"bottom_ap02_lower_within_{horizon}d"] else "否"
            for horizon in HORIZONS
        )
        lines.append(
            f"| {row['sample']} | {row['stock_id']} {row['stock_name']} | "
            f"{row['window_start']} | {row['trade_date']} | {row['source_trend_phase']} | "
            f"{'是' if row['source_first_ap02_day'] else '否'} | "
            f"{'是' if row['next_day_ap02_lower'] else '否'} | "
            f"{fmt(row['cycle_score'])} | {hits} |"
        )
    lines.extend(
        [
            "",
            "## 方法界線",
            "",
            "- 第 1／3／5 日以同一股票、同一窗口後續 ADD 決策列計算；價格由當日成本與單位 ROI 還原，與既有 A-BOT01 方法一致。",
            "- 後續正式路徑已經執行起始加碼，因此 A-E 冷卻、成本、Grade 與加碼次數都受該加碼影響；`formal_routes` 與 `a_e_actual_gate` 只能描述正式路徑，不能冒充『若起始日跳過』的完整資格。是否真能改日加碼仍須候選完整重播。",
            "- 本診斷只回答現有關鍵案例是否常出現『稍後仍有 A-P02、已進入惡化探底且價格更低』，不以當輪歷史結果直接相加為候選分數。",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> None:
    args = arguments()
    specs = decision_base_specs(args.decision_base)
    identities = verify_identity(specs)
    targets: list[dict] = []
    daily: list[dict] = []
    for sample, directory in sorted(specs.items()):
        rows, _ = load_sample(sample, directory)
        selected = [
            row
            for row in rows
            if row["first_blanket_in_cycle"]
            and row["protected_ap02"]
            and row["grade"] == "wow"
        ]
        for target in selected:
            inspected, inspected_daily = inspect_target(sample, directory, target)
            targets.append(inspected)
            daily.extend(inspected_daily)
    targets.sort(key=lambda row: (row["sample"], row["window_start"], row["stock_id"], row["trade_date"]))
    daily.sort(key=lambda row: (row["sample"], row["window_start"], row["stock_id"], row["trade_date"]))
    summary = [
        summary_row(scope, targets if scope == "ALL" else [row for row in targets if row["sample"] == scope])
        for scope in (*"ABCDE", "ALL")
    ]
    output = args.output
    output.mkdir(parents=True, exist_ok=True)
    write_csv(output / "targets.csv", targets)
    write_csv(output / "daily-followup.csv", daily)
    write_csv(output / "summary.csv", summary)
    (output / "report.md").write_text(render_report(summary, targets), encoding="utf-8")
    manifest = {
        "studyID": STUDY_ID,
        "createdAt": datetime.now(TAIPEI).isoformat(),
        "baseline": "v19",
        **EXPECTED_COMMON,
        "samples": sorted(EXPECTED_SAMPLES),
        "target": "first pivotal exact-wow non-bottom ADD protected by A-P02 in each cycle",
        "horizons": list(HORIZONS),
        "identities": identities,
        "counts": {row["scope"]: row for row in summary},
        "files": ["manifest.json", "report.md", "targets.csv", "daily-followup.csv", "summary.csv"],
        "limitations": [
            "formal-path follow-up after the start ADD is path-contaminated",
            "actual A-E cooldown cannot prove counterfactual eligibility after skipping the start ADD",
            "candidate replay is required before adoption",
        ],
    }
    (output / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )


if __name__ == "__main__":
    main()
