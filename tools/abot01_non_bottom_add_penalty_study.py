#!/usr/bin/env python3
"""A-BOT01-D0-ABCDE: diagnose a non-bottoming add-score penalty."""

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

from ecap03_long_negative_holding_study import (
    connect_readonly,
    hypothetical_realized_roi,
    read_json,
    round_score,
)
from eprofit01_long_positive_holding_study import grade_score_band


STUDY_ID = "A-BOT01-D0-ABCDE"
TAIPEI = ZoneInfo("Asia/Taipei")
EXPECTED_SAMPLES = {"A", "B", "C", "D", "E"}
EXPECTED_COMMON = {
    "dataRuleVersion": "T2/S38",
    "ruleVersion": "s31-st02h-efficiency-loss-cut-20260831",
    "ruleCommit": "e4e41e1f1dfecb2fd320d347023a2095366ee0ec",
    "through": "2026/07/22",
    "moneyBaseWan": 600,
    "automaticInvestments": 2,
}
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
HORIZONS = (20, 60, 120)


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


def decision_base_specs(values: list[str]) -> dict[str, Path]:
    result: dict[str, Path] = {}
    for value in values:
        if "=" not in value:
            raise ValueError(f"invalid --decision-base value: {value!r}")
        sample, raw_path = value.split("=", 1)
        sample = sample.upper()
        if sample not in EXPECTED_SAMPLES or sample in result:
            raise ValueError(f"invalid or duplicate sample: {sample!r}")
        result[sample] = Path(raw_path)
    if set(result) != EXPECTED_SAMPLES:
        raise ValueError(f"expected A/B/C/D/E, received {sorted(result)}")
    return result


def verify_identity(specs: dict[str, Path]) -> dict[str, dict]:
    identities: dict[str, dict] = {}
    for sample, directory in sorted(specs.items()):
        manifest = read_json(directory / "manifest.json")
        decision_base_id = manifest["decisionBaseID"]
        if (directory / ".complete").read_text(encoding="utf-8").strip() != decision_base_id:
            raise ValueError(f"{sample} completion marker mismatch")
        if (directory / ".p4b-complete").read_text(encoding="utf-8").strip() != decision_base_id:
            raise ValueError(f"{sample} P4b marker mismatch")
        if manifest.get("sampleID") != sample:
            raise ValueError(f"{sample} manifest sample mismatch")
        for key, expected in EXPECTED_COMMON.items():
            if manifest.get(key) != expected:
                raise ValueError(f"{sample} manifest mismatch {key}: {manifest.get(key)!r}")
        connection = connect_readonly(directory / "decisions.sqlite")
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        windows = connection.execute("SELECT COUNT(*) FROM windows").fetchone()[0]
        stocks = connection.execute("SELECT COUNT(*) FROM stocks").fetchone()[0]
        connection.close()
        if integrity != "ok" or windows != 3 or stocks != 10:
            raise ValueError(
                f"{sample} coverage mismatch: integrity={integrity}, windows={windows}, stocks={stocks}"
            )
        identities[sample] = {
            "decisionBaseID": decision_base_id,
            "database": str(directory / "decisions.sqlite"),
            "windows": windows,
            "stocks": stocks,
        }
    return identities


def formal_routes(row: dict, score: float) -> tuple[str, ...]:
    grade = int(row["grade"])
    roi = float(row["unit_roi_before"])
    days = float(row["holding_days_before"])
    deep_loss_threshold = -32.5 if grade >= 0 else -30.0
    at01 = (
        (roi < deep_loss_threshold or (roi < -25.0 and (days < 180.0 or days > 360.0)))
        and score >= 3.0
    )
    at02_threshold = 2.0 if grade <= -2 else 3.0
    at02 = (
        row["l_planned_action"] == "L"
        and days < 60.0
        and -10.0 < roi < 1.0
        and score >= at02_threshold
    )
    routes = []
    if at01:
        routes.append("A-T01")
    if at02:
        routes.append("A-T02")
    return tuple(routes)


def finite_median(rows: list[dict], field: str) -> float | None:
    values = [float(row[field]) for row in rows if row.get(field) is not None and math.isfinite(float(row[field]))]
    return statistics.median(values) if values else None


def finite_mean(rows: list[dict], field: str) -> float | None:
    values = [float(row[field]) for row in rows if row.get(field) is not None and math.isfinite(float(row[field]))]
    return statistics.mean(values) if values else None


def fraction(rows: list[dict], field: str) -> float | None:
    values = [float(row[field]) for row in rows if row.get(field) is not None]
    return sum(values) / len(values) if values else None


def load_sample(sample: str, directory: Path) -> tuple[list[dict], dict]:
    connection = connect_readonly(directory / "decisions.sqlite")
    connection.row_factory = sqlite3.Row
    phase3_by_path: dict[tuple[int, int], list[dict]] = defaultdict(list)
    for row in connection.execute(
        """
        SELECT d.*,w.start_date,w.end_date
        FROM decision_event_lookup d JOIN windows w USING(window_id)
        WHERE d.phase=3
        ORDER BY d.window_id,d.stock_key,d.trade_date
        """
    ):
        phase3_by_path[(int(row["window_id"]), int(row["stock_key"]))].append(dict(row))

    cycles_by_path: dict[tuple[int, int], list[dict]] = defaultdict(list)
    for path_key, held_rows in phase3_by_path.items():
        current: list[dict] = []
        cycle_number = 0
        for row in held_rows:
            if float(row["inventory_before"]) <= 0:
                if current:
                    raise ValueError(f"{sample} unexpected empty inventory inside cycle: {path_key}")
                continue
            current.append(row)
            if row["executed_action"] == "SELL":
                cycle_number += 1
                cycles_by_path[path_key].append(
                    {"cycle_number": cycle_number, "rows": current, "final": current[-1]}
                )
                current = []
        if current:
            cycle_number += 1
            cycles_by_path[path_key].append(
                {"cycle_number": cycle_number, "rows": current, "final": current[-1]}
            )

    votes: dict[int, dict[str, float]] = defaultdict(dict)
    for event_id, rule_id, contribution in connection.execute(
        """
        SELECT v.event_id,v.rule_id,v.contribution
        FROM event_vote_lookup v JOIN decision_events e USING(event_id)
        WHERE e.phase=4
        """
    ):
        votes[int(event_id)][str(rule_id)] = float(contribution)
    execution_eligible = {
        int(row[0])
        for row in connection.execute(
            "SELECT event_id FROM event_gate_lookup WHERE rule_id='A-E'"
        )
    }

    add_dates_by_path: dict[tuple[int, int], list[int]] = defaultdict(list)
    for window_id, stock_key, trade_date in connection.execute(
        "SELECT window_id,stock_key,trade_date FROM decision_events "
        "WHERE phase=4 AND executed_action='ADD' ORDER BY window_id,stock_key,trade_date"
    ):
        add_dates_by_path[(int(window_id), int(stock_key))].append(int(trade_date))

    query = """
        SELECT d.*,w.start_date,w.end_date,
               sf.fit_trend_phase,sf.fit_observation_count,
               g.decision_score grade_efficiency_score,
               l.planned_action l_planned_action
        FROM decision_event_lookup d
        JOIN windows w USING(window_id)
        LEFT JOIN event_strategy_fit_observations eso USING(event_id)
        LEFT JOIN strategy_fit_observations sf USING(observation_id)
        LEFT JOIN decision_events g ON g.window_id=d.window_id
          AND g.stock_key=d.stock_key AND g.trade_date=d.trade_date AND g.phase=0
        LEFT JOIN decision_events l ON l.window_id=d.window_id
          AND l.stock_key=d.stock_key AND l.trade_date=d.trade_date AND l.phase=2
        WHERE d.phase=4 AND d.executed_action='ADD'
        ORDER BY d.window_id,d.stock_key,d.trade_date
    """
    rows: list[dict] = []
    for raw in connection.execute(query):
        row = dict(raw)
        if row["fit_trend_phase"] is None or row["fit_observation_count"] is None:
            raise ValueError(f"{sample} add event missing trend observation: {row['event_id']}")
        if row["grade_efficiency_score"] is None:
            raise ValueError(f"{sample} add event missing Grade score: {row['event_id']}")
        path_key = (int(row["window_id"]), int(row["stock_key"]))
        event_date = int(row["trade_date"])
        matching = [
            cycle
            for cycle in cycles_by_path[path_key]
            if int(cycle["rows"][0]["trade_date"]) <= event_date <= int(cycle["final"]["trade_date"])
        ]
        if len(matching) != 1:
            raise ValueError(f"{sample} add-to-cycle mismatch: {row['event_id']} -> {len(matching)}")
        cycle = matching[0]
        final = cycle["final"]
        final_roi = hypothetical_realized_roi(
            float(final["unit_cost_before"]),
            float(final["unit_roi_before"]),
            float(final["inventory_before"]),
        )
        final_days = float(final["holding_days_before"])
        event_votes = votes[int(row["event_id"])]
        score = float(row["decision_score"])
        routes_with = formal_routes(row, score)
        routes_without = formal_routes(row, score - 1.0)
        if row["planned_action"] != "ADD" or not routes_with:
            raise ValueError(f"{sample} executed ADD lacks reconstructed formal route: {row['event_id']}")
        if int(row["event_id"]) not in execution_eligible:
            raise ValueError(f"{sample} executed ADD lacks A-E gate: {row['event_id']}")
        phase_raw = int(row["fit_trend_phase"])
        warmed = int(row["fit_observation_count"]) >= 125
        non_bottom = warmed and phase_raw != 10
        pivotal = bool(routes_with) and not routes_without
        ap02 = event_votes.get("A-P02", 0.0) > 0
        blanket_pivotal = non_bottom and pivotal
        attached_target = blanket_pivotal and not ap02
        protected_ap02 = blanket_pivotal and ap02

        end_date = int(row["end_date"])
        exit_date = int(final["trade_date"])
        cycle_rows = cycle["rows"]
        matching_indexes = [
            index for index, item in enumerate(cycle_rows) if int(item["trade_date"]) == event_date
        ]
        if len(matching_indexes) != 1:
            raise ValueError(f"{sample} add date missing from held path: {row['event_id']}")
        event_index = matching_indexes[0]
        event_held = cycle_rows[event_index]
        event_close = float(event_held["unit_cost_before"]) * (
            1.0 + float(event_held["unit_roi_before"]) / 100.0
        )
        final_close = float(final["unit_cost_before"]) * (
            1.0 + float(final["unit_roi_before"]) / 100.0
        )
        future_rows = cycle_rows[event_index + 1 :]
        future_add_dates = [
            date for date in add_dates_by_path[path_key] if event_date < date <= exit_date
        ]
        next_add_date = future_add_dates[0] if future_add_dates else None
        next_add_index = next(
            (
                index
                for index, item in enumerate(future_rows, 1)
                if next_add_date is not None and int(item["trade_date"]) == next_add_date
            ),
            None,
        )
        next_add_close = None
        if next_add_index is not None:
            next_add_row = future_rows[next_add_index - 1]
            next_add_close = float(next_add_row["unit_cost_before"]) * (
                1.0 + float(next_add_row["unit_roi_before"]) / 100.0
            )
        value = {
            "sample": sample,
            "event_id": int(row["event_id"]),
            "window_id": int(row["window_id"]),
            "window_start": int(row["start_date"]),
            "window_end": end_date,
            "stock_id": str(row["stock_id"]),
            "stock_name": str(row["stock_name"]),
            "group_name": str(row["group_name"]),
            "trade_date": event_date,
            "cycle_number": int(cycle["cycle_number"]),
            "cycle_key": f"{sample}|{row['window_id']}|{row['stock_id']}|{cycle['cycle_number']}",
            "grade": str(row["grade_name"]),
            "grade_raw": int(row["grade"]),
            "grade_efficiency_score": float(row["grade_efficiency_score"]),
            "grade_score_band": grade_score_band(float(row["grade_efficiency_score"])),
            "trend_phase": PHASE_NAMES.get(phase_raw, f"unknown_{phase_raw}"),
            "trend_phase_raw": phase_raw,
            "fit_observation_count": int(row["fit_observation_count"]),
            "warmed": int(warmed),
            "non_bottom": int(non_bottom),
            "a_p02": int(ap02),
            "decision_score": score,
            "score_after_penalty": score - 1.0,
            "routes_with": "+".join(routes_with),
            "routes_after_penalty": "+".join(routes_without),
            "pivotal_penalty": int(pivotal),
            "blanket_pivotal": int(blanket_pivotal),
            "attached_target": int(attached_target),
            "protected_ap02": int(protected_ap02),
            "unit_roi_before": float(row["unit_roi_before"]),
            "holding_days_before": float(row["holding_days_before"]),
            "invest_times_before": float(row["invest_times_before"]),
            "buy_rule_before": str(row["buy_rule_before"]),
            "l_planned_action": str(row["l_planned_action"] or "NONE"),
            "exit_date": exit_date,
            "actual_exit": int(final["executed_action"] == "SELL"),
            "trading_days_to_exit": len(future_rows),
            "price_return_to_exit": 100.0 * (final_close / event_close - 1.0),
            "cycle_roi": final_roi,
            "cycle_holding_days": final_days,
            "cycle_score": round_score(final_roi, final_days),
            "negative_cycle_score": int(round_score(final_roi, final_days) < 0),
            "next_add_date": next_add_date,
            "trading_days_to_next_add": next_add_index,
            "price_return_to_next_add": (
                100.0 * (next_add_close / event_close - 1.0)
                if next_add_close is not None
                else None
            ),
            "all_votes": "|".join(f"{key}:{event_votes[key]:g}" for key in sorted(event_votes)),
        }
        for horizon in HORIZONS:
            if len(future_rows) >= horizon:
                endpoint = future_rows[horizon - 1]
                complete = True
                exited = False
            elif final["executed_action"] == "SELL":
                endpoint = final
                complete = True
                exited = True
            else:
                endpoint = None
                complete = False
                exited = False
            if endpoint is None:
                value[f"return_{horizon}d"] = None
            else:
                endpoint_close = float(endpoint["unit_cost_before"]) * (
                    1.0 + float(endpoint["unit_roi_before"]) / 100.0
                )
                value[f"return_{horizon}d"] = 100.0 * (endpoint_close / event_close - 1.0)
            value[f"complete_{horizon}d"] = int(complete)
            value[f"exit_within_{horizon}d"] = int(exited) if complete else None
        rows.append(value)
    connection.close()
    first_attached: set[int] = set()
    first_blanket: set[int] = set()
    rows_by_cycle: dict[str, list[dict]] = defaultdict(list)
    for row in rows:
        rows_by_cycle[str(row["cycle_key"])].append(row)
    for items in rows_by_cycle.values():
        attached = [row for row in items if row["attached_target"]]
        blanket = [row for row in items if row["blanket_pivotal"]]
        if attached:
            first_attached.add(min(attached, key=lambda row: row["trade_date"])["event_id"])
        if blanket:
            first_blanket.add(min(blanket, key=lambda row: row["trade_date"])["event_id"])
    for row in rows:
        row["first_attached_in_cycle"] = int(row["event_id"] in first_attached)
        row["first_blanket_in_cycle"] = int(row["event_id"] in first_blanket)

    return rows, {
        "addEvents": len(rows),
        "warmedNonBottomAdds": sum(row["non_bottom"] for row in rows),
        "blanketPivotalEvents": sum(row["blanket_pivotal"] for row in rows),
        "attachedTargetEvents": sum(row["attached_target"] for row in rows),
        "protectedAP02Events": sum(row["protected_ap02"] for row in rows),
        "attachedTargetCycles": sum(row["first_attached_in_cycle"] for row in rows),
    }


def summary_row(scope: str, category: str, rows: list[dict]) -> dict:
    return {
        "scope": scope,
        "category": category,
        "events": len(rows),
        "cycles": len({row["cycle_key"] for row in rows}),
        "stocks": len({(row["sample"], row["stock_id"]) for row in rows}),
        "windows": len({(row["sample"], row["window_id"]) for row in rows}),
        "median_cycle_roi": finite_median(rows, "cycle_roi"),
        "median_cycle_days": finite_median(rows, "cycle_holding_days"),
        "median_cycle_score": finite_median(rows, "cycle_score"),
        "negative_cycle_score_rate": fraction(rows, "negative_cycle_score"),
        "median_price_return_to_exit": finite_median(rows, "price_return_to_exit"),
        "mean_price_return_to_exit": finite_mean(rows, "price_return_to_exit"),
        "median_trading_days_to_exit": finite_median(rows, "trading_days_to_exit"),
        "next_add_rate": sum(row["next_add_date"] is not None for row in rows) / len(rows) if rows else None,
        "median_days_to_next_add": finite_median(rows, "trading_days_to_next_add"),
        "median_return_to_next_add": finite_median(rows, "price_return_to_next_add"),
        **{f"median_return_{horizon}d": finite_median(rows, f"return_{horizon}d") for horizon in HORIZONS},
    }


def build_summaries(rows: list[dict]) -> tuple[list[dict], list[dict]]:
    categories = {
        "attached_target_first_cycle": lambda row: row["first_attached_in_cycle"] == 1,
        "protected_ap02_first_blanket_cycle": lambda row: row["first_blanket_in_cycle"] == 1 and row["protected_ap02"] == 1,
        "blanket_pivotal_first_cycle": lambda row: row["first_blanket_in_cycle"] == 1,
    }
    summary = []
    for scope in ["A", "B", "C", "D", "E", "ALL"]:
        scoped = rows if scope == "ALL" else [row for row in rows if row["sample"] == scope]
        for category, predicate in categories.items():
            summary.append(summary_row(scope, category, [row for row in scoped if predicate(row)]))

    target = [row for row in rows if row["first_attached_in_cycle"]]
    breakdown = []
    for dimension, field in (
        ("sample", "sample"),
        ("trend_phase", "trend_phase"),
        ("grade", "grade"),
        ("grade_score_band", "grade_score_band"),
        ("route", "routes_with"),
        ("group", "group_name"),
    ):
        grouped: dict[str, list[dict]] = defaultdict(list)
        for row in target:
            grouped[str(row[field])].append(row)
        for condition, items in sorted(grouped.items()):
            breakdown.append(summary_row(dimension, condition, items))
    return summary, breakdown


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


def fmt(value: object, digits: int = 3) -> str:
    if value is None:
        return "—"
    return f"{float(value):.{digits}f}"


def render_report(summary: list[dict], counts: dict[str, dict], target: list[dict], protected: list[dict]) -> str:
    lookup = {(row["scope"], row["category"]): row for row in summary}
    target_wow = [row for row in target if row["grade"] == "wow"]
    target_non_wow = [row for row in target if row["grade"] != "wow"]
    protected_wow = [row for row in protected if row["grade"] == "wow"]
    target_wow_summary = summary_row("ALL", "target_wow", target_wow)
    target_non_wow_summary = summary_row("ALL", "target_non_wow", target_non_wow)
    protected_wow_summary = summary_row("ALL", "protected_wow", protected_wow)
    lines = [
        f"# {STUDY_ID}",
        "",
        "只讀 Baseline v19 A～E DecisionBase v6。候選診斷條件為：Grade 適配趨勢已暖機、不是惡化確認探底、A-P02 未成立，若此時 aWant 減 1 會使正式 A-T01／A-T02 均不再成立，即列為附加型決策關鍵事件。",
        "",
        "## 完整性與事件數",
        "",
        "| Sample | 正式加碼 | 暖機後非探底 | 全域扣分關鍵 | 附加條件關鍵 | A-P02 保護 | 附加條件獨立輪 |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for sample in "ABCDE":
        row = counts[sample]
        lines.append(
            f"| {sample} | {row['addEvents']} | {row['warmedNonBottomAdds']} | "
            f"{row['blanketPivotalEvents']} | {row['attachedTargetEvents']} | "
            f"{row['protectedAP02Events']} | {row['attachedTargetCycles']} |"
        )
    lines.extend(
        [
            "",
            "## 附加條件的第一個關鍵事件",
            "",
            "| Sample | 輪數 | 股票 | 窗口 | 當輪中位 ROI | 中位期間 | 中位效率分數 | 負分率 | 至出場價格中位 | 20／60／120 日端點價格中位 |",
            "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |",
        ]
    )
    for sample in (*"ABCDE", "ALL"):
        row = lookup[(sample, "attached_target_first_cycle")]
        lines.append(
            f"| {sample} | {row['cycles']} | {row['stocks']} | {row['windows']} | "
            f"{fmt(row['median_cycle_roi'])}% | {fmt(row['median_cycle_days'], 1)} | "
            f"{fmt(row['median_cycle_score'])} | "
            f"{fmt(100 * row['negative_cycle_score_rate'], 1) if row['negative_cycle_score_rate'] is not None else '—'}% | "
            f"{fmt(row['median_price_return_to_exit'])}% | "
            f"{fmt(row['median_return_20d'])}／{fmt(row['median_return_60d'])}／{fmt(row['median_return_120d'])} |"
        )
    protected_all = lookup[("ALL", "protected_ap02_first_blanket_cycle")]
    lines.extend(
        [
            "",
            "## A-P02 例外對照",
            "",
            f"若採全域非探底減 1，A-P02 組另有 {protected_all['cycles']} 個首先受影響的獨立輪；其當輪中位 ROI／效率分數為 {fmt(protected_all['median_cycle_roi'])}%／{fmt(protected_all['median_cycle_score'])}，負分率 {fmt(100 * protected_all['negative_cycle_score_rate'], 1) if protected_all['negative_cycle_score_rate'] is not None else '—'}%，至出場價格變化中位 {fmt(protected_all['median_price_return_to_exit'])}%。這組用來判斷保留 A-P02 是否有實際價值。",
            "",
            "## Grade 分歧",
            "",
            f"附加條件的 exact wow 有 {target_wow_summary['cycles']} 輪，來自 C 世芯-KY與 E 益航；當輪效率分數中位 {fmt(target_wow_summary['median_cycle_score'])}、負分率 {fmt(100 * target_wow_summary['negative_cycle_score_rate'], 1)}%，至出場價格變化中位 {fmt(target_wow_summary['median_price_return_to_exit'])}%。唯一非 wow 是 D 高力 exact weak，當輪效率分數 {fmt(target_non_wow_summary['median_cycle_score'])}、至出場價格變化 {fmt(target_non_wow_summary['median_price_return_to_exit'])}%，方向相反。",
            "",
            f"被 A-P02 例外保護的 exact wow 則有 {protected_wow_summary['cycles']} 輪，跨 A～E；當輪效率分數中位 {fmt(protected_wow_summary['median_cycle_score'])}、至出場價格變化中位 {fmt(protected_wow_summary['median_price_return_to_exit'])}%。因此 A-P02 例外具有可辨識價值，不能改成 exact wow 的全域非探底扣分。",
            "",
            "## 診斷結論",
            "",
            "全 Grade 附加候選會同時移除 D 高力的正向輪，不建議建立。最小可解釋候選是只作用於 exact wow：趨勢已暖機、非惡化確認探底且 A-P02 未成立時，aWant 減 1。兩個負例的 Grade 連續分數都在 100～200，但只有兩件，不另以 100／200 建立事後分界；完整重播仍須確認是否只改日加碼。",
            "",
            "## 限制",
            "",
            "- 這是正式路徑觀察，不是取消加碼後的完整反事實；只可用來決定是否值得建立候選。",
            "- 同一持股輪可能有多個關鍵事件，主表只取附加條件第一次命中，避免把路徑內重複事件當成獨立案例。",
            "- 當輪 ROI／效率分數包含整輪全部投入；事件日至出場與 20／60／120 日端點價格變化較接近該次加碼價格是否有利。若正式路徑在觀察期限前已出場，該期限使用正式出場日端點；仍未包含跳過後的改日加碼與資金再利用。",
            "",
            "## 明細",
            "",
            f"- 附加條件第一事件：{len(target)}",
            f"- A-P02 保護組第一事件：{len(protected)}",
            "- 完整事件、分組摘要與 manifest 見同目錄 CSV／JSON。",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> None:
    args = arguments()
    specs = decision_base_specs(args.decision_base)
    identities = verify_identity(specs)
    all_rows: list[dict] = []
    counts: dict[str, dict] = {}
    for sample, directory in sorted(specs.items()):
        rows, sample_counts = load_sample(sample, directory)
        all_rows.extend(rows)
        counts[sample] = sample_counts
    summary, breakdown = build_summaries(all_rows)
    target = [row for row in all_rows if row["first_attached_in_cycle"]]
    protected = [
        row
        for row in all_rows
        if row["first_blanket_in_cycle"] and row["protected_ap02"]
    ]
    output = args.output
    output.mkdir(parents=True, exist_ok=True)
    write_csv(output / "all-add-events.csv", all_rows)
    write_csv(output / "attached-target-first-cycles.csv", target)
    write_csv(output / "protected-ap02-first-cycles.csv", protected)
    write_csv(output / "summary.csv", summary)
    write_csv(output / "target-breakdown.csv", breakdown)
    manifest = {
        "studyID": STUDY_ID,
        "createdAt": datetime.now(TAIPEI).isoformat(),
        "baseline": "v19",
        **EXPECTED_COMMON,
        "samples": ["A", "B", "C", "D", "E"],
        "candidateDefinition": {
            "penalty": -1,
            "trendWarmupMinimum": 125,
            "excludedPhase": "worsening_seeking_bottom (raw 10)",
            "exception": "A-P02 contribution +1",
            "decisive": "score - 1 closes both formal A-T01 and A-T02 routes",
        },
        "counts": counts,
        "identities": identities,
        "diagnosticConclusion": {
            "blanketPenalty": "reject",
            "allGradeAttachedPenalty": "mixed; exact weak positive case",
            "minimalCandidate": "exact wow AND warmed non-bottom AND no A-P02 => aWant -1",
            "continuousGradeScoreBoundary": "not proposed; only two target wow cycles",
            "nextSample": "E",
        },
        "limitations": [
            "observational formal-path diagnosis, not candidate replay",
            "cycle outcome includes all investments in the holding cycle",
            "full replay is required to observe delayed adds and capital reuse",
        ],
        "files": [
            "manifest.json",
            "report.md",
            "all-add-events.csv",
            "attached-target-first-cycles.csv",
            "protected-ap02-first-cycles.csv",
            "summary.csv",
            "target-breakdown.csv",
        ],
    }
    (output / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    (output / "report.md").write_text(
        render_report(summary, counts, target, protected), encoding="utf-8"
    )
    print(
        json.dumps(
            {
                "output": str(output),
                "addEvents": len(all_rows),
                "attachedTargetCycles": len(target),
                "protectedAP02Cycles": len(protected),
            },
            ensure_ascii=False,
        )
    )


if __name__ == "__main__":
    main()
