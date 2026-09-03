#!/usr/bin/env python3
"""MKT-R02-D2: market phenomenon x one-vote-short profitable sell study."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import random
import sqlite3
import statistics
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

from ecap03_long_negative_holding_study import hypothetical_realized_roi, round_score, split_cycles
from market_entry_rule_interaction import (
    EXPECTED_ATOM_CSV_SHA256,
    EXPECTED_COMMON,
    EXPECTED_MARKET_TECHNICAL_SHA256,
    date_sets,
    percentile,
    read_json,
    sha256,
    shifted_date_sets,
    verify_atoms,
    verify_decision_bases,
    write_csv,
)
from market_vote_phenomenon_inventory import build_atoms, load_market


STUDY_ID = "MKT-R02-D2"
EXPECTED_EVENT_COUNT = 1201
MIN_DATES_PER_SIDE = 30
MIN_STOCKS_PER_SIDE = 10
MIN_CONFIRM_STOCKS = 5
MIN_CONFIRM_SAMPLES = 2
ELIGIBLE_GATES = {"S-T01a", "S-T01c", "S-T01e", "S-T01f", "S-T01g", "S-T01h"}
INTERACTION_FIELDS = [
    "window_id", "atom_id", "source_field", "kind", "condition",
    "on_dates", "off_dates", "on_stocks", "off_stocks", "on_samples", "off_samples",
    "raw_effect", "standardized_effect", "event_rows", "max_date_share", "max_stock_share",
    "global_null_p", "global_null_p95", "exceeds_global_null_p95",
    "w1_standardized_effect", "same_positive_direction_as_w1", "confirmed",
    "bootstrap_ci_low", "bootstrap_ci_high", "same_positive_direction_as_w1_w2",
    "ci_above_zero", "passed",
]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def close_enough(value: float, target: float) -> bool:
    return math.isclose(value, target, abs_tol=1e-9)


def roi_threshold_for_st01c(grade: int) -> float:
    if grade <= -1:
        return 1.5
    if grade >= 3:
        return 2.25
    return 2.0


def one_vote_short_profitable_gates(row: dict[str, Any]) -> list[str]:
    """Mirror D2's one-vote boundary; S-T01d is nested within S-T01c."""
    if str(row["planned_action"]).upper() != "HOLD" or str(row["executed_action"]).upper() != "NONE":
        return []
    score = float(row["decision_score"])
    roi = float(row["unit_roi_before"])
    days = float(row["holding_days_before"])
    grade = int(row["grade"])
    upper = grade >= 2
    gates: list[str] = []

    st01a_boundary = 0.0 if upper else 1.0
    if roi > 22.5 and close_enough(score, st01a_boundary):
        gates.append("S-T01a")
    if roi > roi_threshold_for_st01c(grade) and close_enough(score, 3.0):
        gates.append("S-T01c")
    # S-T01d also requires score 3 before the added vote and ROI > 3.5%.
    # Those conditions always satisfy the current S-T01c ROI boundary (at
    # most 2.25%), so d contributes no distinct eligible event. Keeping it
    # out of the matching signature avoids depending on sparse technical
    # observations while preserving the exact eligible event set.
    if roi > 0.45 and days > 68 and close_enough(score, 3.0):
        gates.append("S-T01e")
    if roi > 15.5 and days < (60 if upper else 40) and close_enough(score, 2.0):
        gates.append("S-T01f")
    if roi > 9.5 and days < (30 if upper else 20) and close_enough(score, 2.0):
        gates.append("S-T01g")
    if roi > 6.5 and days < (45 if grade <= -1 else 10) and close_enough(score, 2.0):
        gates.append("S-T01h")
    require(set(gates) <= ELIGIBLE_GATES, f"unexpected eligible gate: {gates}")
    return gates


def load_sell_rows(path: Path) -> list[dict[str, Any]]:
    connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    try:
        require(connection.execute("PRAGMA integrity_check").fetchone()[0] == "ok", f"SQLite integrity failed: {path}")
        rows = []
        for row in connection.execute(
            """
            SELECT d.*,w.start_date,w.end_date
            FROM decision_event_lookup d
            JOIN windows w USING(window_id)
            WHERE d.phase=3 AND d.inventory_before>0
            ORDER BY d.window_id,d.stock_key,d.trade_date,d.event_id
            """
        ):
            value = dict(row)
            value["path_key"] = (int(row["window_id"]), int(row["stock_key"]))
            value["sold"] = str(row["executed_action"]).upper() == "SELL"
            value["inventory"] = float(row["inventory_before"])
            rows.append(value)
        return rows
    finally:
        connection.close()


def implied_close(row: dict[str, Any]) -> float:
    return float(row["unit_cost_before"]) * (1.0 + float(row["unit_roi_before"]) / 100.0)


def liquidation(row: dict[str, Any]) -> tuple[float, float]:
    roi = hypothetical_realized_roi(
        float(row["unit_cost_before"]),
        float(row["unit_roi_before"]),
        float(row["inventory_before"]),
    )
    return roi, round_score(roi, float(row["holding_days_before"]))


def build_events(identities: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
    output: list[dict[str, Any]] = []
    for sample in sorted(identities):
        rows = load_sell_rows(Path(identities[sample]["database"]))
        for path_key, cycle_number, cycle in split_cycles(rows, "inventory", "sold"):
            final = cycle[-1]
            outcome_roi, outcome_score = liquidation(final)
            outcome_close = implied_close(final)
            for index, row in enumerate(cycle):
                gates = one_vote_short_profitable_gates(row)
                if not gates:
                    continue
                early_roi, early_score = liquidation(row)
                event_close = implied_close(row)
                future = cycle[index + 1 :]
                output.append({
                    "sample": sample,
                    "window_id": int(row["window_id"]),
                    "window_start": int(row["start_date"]),
                    "window_end": int(row["end_date"]),
                    "stock_id": str(row["stock_id"]),
                    "stock_name": str(row["stock_name"]),
                    "group_name": str(row["group_name"]),
                    "event_id": int(row["event_id"]),
                    "event_date": int(row["trade_date"]),
                    "round_id": cycle_number,
                    "candidate_gates": "|".join(gates),
                    "grade": str(row["grade_name"]),
                    "grade_value": int(row["grade"]),
                    "decision_score": float(row["decision_score"]),
                    "unit_roi_before": float(row["unit_roi_before"]),
                    "holding_days_before": float(row["holding_days_before"]),
                    "invest_times_before": float(row["invest_times_before"]),
                    "event_close": event_close,
                    "early_exit_roi": early_roi,
                    "early_exit_score": early_score,
                    "outcome_date": int(final["trade_date"]),
                    "actual_exit": int(bool(final["sold"])),
                    "outcome_roi": outcome_roi,
                    "outcome_score": outcome_score,
                    "trading_days_to_outcome": len(future),
                    "holding_days_saved": float(final["holding_days_before"]) - float(row["holding_days_before"]),
                    "future_add": int(any(float(item["invest_times_before"]) > float(row["invest_times_before"]) for item in future)),
                    "sale_price_advantage_pct": 100.0 * (event_close / outcome_close - 1.0),
                    "early_exit_score_advantage": early_score - outcome_score,
                })
    return output


def holding_bucket(days: float) -> str:
    if days < 10:
        return "lt10"
    if days < 30:
        return "10_29"
    if days < 68:
        return "30_67"
    if days < 120:
        return "68_119"
    return "ge120"


def roi_bucket(roi: float) -> str:
    if roi < 2.25:
        return "lt2_25"
    if roi < 6.5:
        return "2_25_6_5"
    if roi < 15.5:
        return "6_5_15_5"
    if roi < 22.5:
        return "15_5_22_5"
    return "ge22_5"


def residualized_rows(events: list[dict[str, Any]], window_id: int) -> list[dict[str, Any]]:
    strata: dict[tuple[Any, ...], list[dict[str, Any]]] = defaultdict(list)
    for row in events:
        if row["window_id"] != window_id:
            continue
        strata[(
            row["sample"], row["candidate_gates"], row["grade"], row["decision_score"],
            holding_bucket(float(row["holding_days_before"])),
            roi_bucket(float(row["unit_roi_before"])), int(float(row["invest_times_before"])),
        )].append(row)
    output = []
    for items in strata.values():
        if len(items) < 2:
            continue
        center = statistics.fmean(float(item["early_exit_score_advantage"]) for item in items)
        for item in items:
            output.append({**item, "residual_score": float(item["early_exit_score_advantage"]) - center})
    return output


def collapse_dates(rows: list[dict[str, Any]]) -> dict[int, dict[str, Any]]:
    grouped: dict[int, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        grouped[int(row["event_date"])].append(row)
    return {
        date: {
            "score": statistics.fmean(float(row["residual_score"]) for row in items),
            "stocks": {(row["sample"], row["stock_id"]) for row in items},
            "samples": {row["sample"] for row in items},
            "rows": items,
        }
        for date, items in grouped.items()
    }


def candidate_stat(atom_id: str, date_rows: dict[int, dict[str, Any]], true_dates: set[int],
                   enforce_capacity: bool = True) -> dict[str, Any] | None:
    on_dates = sorted(set(date_rows) & true_dates)
    off_dates = sorted(set(date_rows) - true_dates)
    on_stocks = set().union(*(date_rows[date]["stocks"] for date in on_dates)) if on_dates else set()
    off_stocks = set().union(*(date_rows[date]["stocks"] for date in off_dates)) if off_dates else set()
    if enforce_capacity and (
        len(on_dates) < MIN_DATES_PER_SIDE or len(off_dates) < MIN_DATES_PER_SIDE
        or len(on_stocks) < MIN_STOCKS_PER_SIDE or len(off_stocks) < MIN_STOCKS_PER_SIDE
    ):
        return None
    if not on_dates or not off_dates:
        return None
    on_values = [float(date_rows[date]["score"]) for date in on_dates]
    off_values = [float(date_rows[date]["score"]) for date in off_dates]
    all_values = on_values + off_values
    spread = statistics.pstdev(all_values)
    raw_effect = statistics.fmean(on_values) - statistics.fmean(off_values)
    standardized = raw_effect / spread if spread > 1e-12 else 0.0
    on_samples = set().union(*(date_rows[date]["samples"] for date in on_dates))
    off_samples = set().union(*(date_rows[date]["samples"] for date in off_dates))
    event_rows = [row for date in date_rows for row in date_rows[date]["rows"]]
    date_counts = Counter(int(row["event_date"]) for row in event_rows)
    stock_counts = Counter((row["sample"], row["stock_id"]) for row in event_rows)
    return {
        "atom_id": atom_id,
        "on_dates": len(on_dates), "off_dates": len(off_dates),
        "on_stocks": len(on_stocks), "off_stocks": len(off_stocks),
        "on_samples": len(on_samples), "off_samples": len(off_samples),
        "raw_effect": raw_effect, "standardized_effect": standardized,
        "event_rows": len(event_rows),
        "max_date_share": max(date_counts.values()) / len(event_rows),
        "max_stock_share": max(stock_counts.values()) / len(event_rows),
    }


def screen(window_id: int, rows: list[dict[str, Any]], atoms: list[dict[str, Any]],
           atom_sets: dict[str, set[int]]) -> list[dict[str, Any]]:
    collapsed = collapse_dates(rows)
    atom_by_id = {row["atom_id"]: row for row in atoms}
    output = []
    for atom_id, dates in atom_sets.items():
        result = candidate_stat(atom_id, collapsed, dates)
        if result is not None:
            atom = atom_by_id[atom_id]
            output.append({
                "window_id": window_id, **result,
                "source_field": atom["source_field"], "kind": atom["kind"], "condition": atom["condition"],
            })
    return output


def null_maxima(rows: list[dict[str, Any]], candidates: list[dict[str, Any]],
                atom_sets: dict[str, set[int]], window_dates: list[int], permutations: int,
                seed: int) -> list[dict[str, Any]]:
    if not candidates:
        return []
    rng = random.Random(seed)
    collapsed = collapse_dates(rows)
    atom_ids = {row["atom_id"] for row in candidates}
    used_sets = {atom_id: atom_sets[atom_id] for atom_id in atom_ids}
    spread = statistics.pstdev(float(row["score"]) for row in collapsed.values())
    output = []
    print(f"null start: {len(atom_ids)} phenomena x {permutations} shifts", flush=True)
    for permutation in range(1, permutations + 1):
        offset = rng.randrange(1, len(window_dates))
        shifted = shifted_date_sets(used_sets, window_dates, offset)
        maximum = 0.0
        evaluated = 0
        for atom_id in atom_ids:
            on_dates = set(collapsed) & shifted[atom_id]
            off_dates = set(collapsed) - shifted[atom_id]
            if len(on_dates) < MIN_DATES_PER_SIDE or len(off_dates) < MIN_DATES_PER_SIDE:
                continue
            on_stocks = set().union(*(collapsed[date]["stocks"] for date in on_dates))
            off_stocks = set().union(*(collapsed[date]["stocks"] for date in off_dates))
            if len(on_stocks) < MIN_STOCKS_PER_SIDE or len(off_stocks) < MIN_STOCKS_PER_SIDE:
                continue
            effect = statistics.fmean(float(collapsed[date]["score"]) for date in on_dates)
            effect -= statistics.fmean(float(collapsed[date]["score"]) for date in off_dates)
            standardized = effect / spread if spread > 1e-12 else 0.0
            maximum = max(maximum, standardized)
            evaluated += 1
        output.append({
            "permutation": permutation, "offset": offset,
            "global_max_effect": maximum, "evaluated_phenomena": evaluated,
        })
        if permutation % 50 == 0 or permutation == permutations:
            print(f"null progress: {permutation}/{permutations}", flush=True)
    return output


def attach_null(rows: list[dict[str, Any]], null_rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    if not rows or not null_rows:
        return []
    maxima = [float(row["global_max_effect"]) for row in null_rows]
    threshold = percentile(maxima, 0.95)
    output = []
    for row in rows:
        observed = float(row["standardized_effect"])
        p = (1 + sum(value >= observed for value in maxima)) / (len(maxima) + 1)
        output.append({
            **row, "global_null_p": p, "global_null_p95": threshold,
            "exceeds_global_null_p95": int(observed > threshold),
        })
    return output


def bootstrap_ci(date_rows: dict[int, dict[str, Any]], true_dates: set[int], draws: int,
                 seed: int) -> tuple[float, float]:
    rng = random.Random(seed)
    on = [float(date_rows[date]["score"]) for date in sorted(set(date_rows) & true_dates)]
    off = [float(date_rows[date]["score"]) for date in sorted(set(date_rows) - true_dates)]
    require(on and off, "bootstrap groups are empty")
    values = []
    for _ in range(draws):
        on_mean = statistics.fmean(on[rng.randrange(len(on))] for _ in range(len(on)))
        off_mean = statistics.fmean(off[rng.randrange(len(off))] for _ in range(len(off)))
        values.append(on_mean - off_mean)
    return percentile(values, 0.025), percentile(values, 0.975)


def synthetic_control() -> dict[str, Any]:
    true_dates = set(range(1, 121, 2))
    decoy_dates = set(range(1, 121, 3))
    rows = []
    for date in range(1, 121):
        planted = 8.0 if date in true_dates else 0.0
        noise = ((date * 17) % 11 - 5) / 10
        rows.append({
            "event_date": date, "sample": "S1" if date <= 60 else "S2",
            "stock_id": str(date % 12), "residual_score": planted + noise,
        })
    collapsed = collapse_dates(rows)
    planted = candidate_stat("SYN-ATOM", collapsed, true_dates, False)
    decoy = candidate_stat("DECOY", collapsed, decoy_dates, False)
    removed = collapse_dates([
        {**row, "residual_score": row["residual_score"] - (8.0 if row["event_date"] in true_dates else 0.0)}
        for row in rows
    ])
    removed_stat = candidate_stat("SYN-ATOM", removed, true_dates, False)
    passed = (
        planted is not None and decoy is not None and removed_stat is not None
        and planted["standardized_effect"] > 0
        and planted["standardized_effect"] > decoy["standardized_effect"]
        and abs(removed_stat["standardized_effect"]) < 0.25
    )
    return {
        "passed": passed,
        "expectedPhenomenon": "SYN-ATOM", "expectedDirection": "sell_plus_one",
        "plantedStandardizedEffect": planted["standardized_effect"] if planted else None,
        "decoyStandardizedEffect": decoy["standardized_effect"] if decoy else None,
        "removedStandardizedEffect": removed_stat["standardized_effect"] if removed_stat else None,
    }


def coverage_rows(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    output = []
    for sample in sorted({row["sample"] for row in events}):
        for window in (1, 2, 3):
            rows = [row for row in events if row["sample"] == sample and row["window_id"] == window]
            output.append({
                "sample": sample, "window_id": window, "events": len(rows),
                "market_dates": len({row["event_date"] for row in rows}),
                "stocks": len({row["stock_id"] for row in rows}),
                "holding_rounds": len({(row["stock_id"], row["round_id"]) for row in rows}),
            })
    return output


def report(summary: dict[str, Any], final_row: dict[str, Any] | None) -> str:
    lines = [
        f"# {STUDY_ID} 大盤×獲利賣出一票交互實驗",
        "",
        f"結論：{summary['conclusion']}。",
        "",
        "## 固定範圍",
        "",
        "- Baseline v20、T2/S39、S32，Sample A～D 三個固定三年窗口；未執行 simUpdate。",
        "- 只分析正式 HOLD 且市場 +1 會開啟 S-T01a/c/e/f/g/h 的事件；現行 S-T01d 完全包含於 S-T01c，S-T01b、S-T02、加碼與進場不在本次範圍。",
        "- 結果是當日假設退出相對正式後續結案／窗口末估值的輪效率分數差；正值表示提早退出較好。",
        "- 市場條件只用 I01 的 467 個單一價格現象；W1 形成、W2 凍結確認、W3 單一保留檢查。",
        "- 同一市場日先合併股票事件，虛無分布共同循環位移整段市場日期，不把同日不同股票當獨立市場證據。",
        "",
        "## 結果",
        "",
        f"- 一票可翻轉事件：{summary['eligibleEvents']:,}；實際後續賣出 {summary['actualExitEvents']:,}，窗口末估值 {summary['markedToMarketEvents']:,}。",
        f"- W1 容量合格現象：{summary['w1CapacityEligible']:,}；超過全家族正向虛無門檻：{summary['w1FrozenCandidates']:,}。",
        f"- W2 同為正向且再超過凍結家族虛無門檻：{summary['w2ConfirmedCandidates']:,}。",
        f"- W3 通過同日 bootstrap 與集中度門檻：{summary['w3PassedCandidates']:,}。",
        f"- 人工植入／移除控制：{'通過' if summary['syntheticControlPassed'] else '失敗'}。",
    ]
    if final_row:
        lines.extend([
            "", "## 唯一候選", "",
            f"- `{final_row['atom_id']}`：`{final_row['condition']}`。",
            "- 規則語意：該大盤現象成立，且個股當日正好只差一票即開啟 S-T01a/c/e/f/g/h 時，`wantS +1`；S-T01d 已由 S-T01c 涵蓋。",
            f"- W3 標準化效果 {final_row['standardized_effect']:.4f}，原始效果 95% CI [{final_row['bootstrap_ci_low']:.4f}, {final_row['bootstrap_ci_high']:.4f}]。",
            "- 這只是可送 Sample A 完整重播的候選，不是改善證據或正式規則。",
        ])
    else:
        lines.extend([
            "", "沒有市場現象同時通過 W1、W2、W3，因此本次不提出賣出 +1 候選；不以二現象、成交量確認或放寬門檻補救。",
        ])
    lines.extend([
        "", "## 界線", "",
        "- 當日假設退出沒有模擬其後可能重新買進的完整路徑；只有後續完整 simUpdate 能確認策略總分、ROI 與週期是否改善。",
        "- Sample E 不參與候選形成；只有候選先通過 Sample A，才另行決定是否使用 E 作弱勢壓力證據。",
        "",
    ])
    return "\n".join(lines)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--decision-base", action="append", required=True)
    parser.add_argument("--market-snapshot", type=Path, required=True)
    parser.add_argument("--atom-inventory", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--permutations", type=int, default=500)
    parser.add_argument("--bootstrap", type=int, default=2000)
    parser.add_argument("--seed", type=int, default=20260903)
    return parser.parse_args()


def main() -> int:
    args = arguments()
    require(args.permutations >= 500, "D2 requires at least 500 null permutations")
    require(args.bootstrap >= 1000, "D2 requires at least 1000 bootstrap draws")
    specs = {}
    for value in args.decision_base:
        require("=" in value, f"invalid --decision-base {value!r}")
        sample, raw = value.split("=", 1)
        sample = sample.upper()
        require(sample in {"A", "B", "C", "D"} and sample not in specs, f"invalid sample {sample}")
        specs[sample] = Path(raw)
    require(set(specs) == {"A", "B", "C", "D"}, f"expected A-D, got {sorted(specs)}")
    identities = verify_decision_bases(specs)

    market_technical = args.market_snapshot / "market-technical.csv"
    require(sha256(market_technical) == EXPECTED_MARKET_TECHNICAL_SHA256, "MT1 technical hash mismatch")
    market_rows, catalog, market_manifest = load_market(args.market_snapshot)
    generated_atoms, _ = build_atoms(market_rows, catalog)
    atoms = verify_atoms(args.atom_inventory, generated_atoms)
    all_atom_sets = date_sets(atoms, market_rows)
    window_dates = {
        window: [int(row["date"]) for row in market_rows if int(row["window_id"]) == window]
        for window in (1, 2, 3)
    }
    atom_sets = {
        window: {atom_id: dates & set(window_dates[window]) for atom_id, dates in all_atom_sets.items()}
        for window in (1, 2, 3)
    }

    events = build_events(identities)
    require(len(events) == EXPECTED_EVENT_COUNT, f"unexpected v20 eligible event count {len(events)}")
    coverage = coverage_rows(events)
    require(min(row["market_dates"] for row in coverage) == 66, "unexpected minimum market-date coverage")
    require(max(row["market_dates"] for row in coverage) == 109, "unexpected maximum market-date coverage")
    require(min(row["stocks"] for row in coverage) == 8 and max(row["stocks"] for row in coverage) == 10,
            "unexpected stock coverage")
    residuals = {window: residualized_rows(events, window) for window in (1, 2, 3)}
    for window in (1, 2, 3):
        require(residuals[window], f"W{window} has no residualized events")

    w1_capacity = screen(1, residuals[1], atoms, atom_sets[1])
    print(f"W1 capacity eligible: {len(w1_capacity)}", flush=True)
    w1_null = null_maxima(residuals[1], w1_capacity, atom_sets[1], window_dates[1],
                          args.permutations, args.seed + 11)
    w1_scored = attach_null(w1_capacity, w1_null)
    frozen = [row for row in w1_scored if row["exceeds_global_null_p95"]]
    print(f"W1 frozen candidates: {len(frozen)}", flush=True)

    w2_all = screen(2, residuals[2], atoms, atom_sets[2])
    frozen_by_id = {row["atom_id"]: row for row in frozen}
    w2_family = [row for row in w2_all if row["atom_id"] in frozen_by_id]
    print(f"W2 capacity-eligible frozen family: {len(w2_family)}", flush=True)
    w2_null = null_maxima(residuals[2], w2_family, atom_sets[2], window_dates[2],
                          args.permutations, args.seed + 12)
    w2_scored = attach_null(w2_family, w2_null)
    w2_evaluated = []
    w2_confirmed = []
    for row in w2_scored:
        prior = frozen_by_id[row["atom_id"]]
        same_positive = float(prior["standardized_effect"]) > 0 and float(row["standardized_effect"]) > 0
        confirmed = (
            same_positive and bool(row["exceeds_global_null_p95"])
            and min(row["on_stocks"], row["off_stocks"]) >= MIN_CONFIRM_STOCKS
            and min(row["on_samples"], row["off_samples"]) >= MIN_CONFIRM_SAMPLES
        )
        value = {
            **row, "w1_standardized_effect": prior["standardized_effect"],
            "same_positive_direction_as_w1": int(same_positive), "confirmed": int(confirmed),
        }
        w2_evaluated.append(value)
        if confirmed:
            w2_confirmed.append(value)

    selected = None
    if w2_confirmed:
        selected = max(
            w2_confirmed,
            key=lambda row: (min(float(row["w1_standardized_effect"]), float(row["standardized_effect"])), row["atom_id"]),
        )

    w3_rows = []
    final_row = None
    if selected:
        actual = next((row for row in screen(3, residuals[3], atoms, atom_sets[3])
                       if row["atom_id"] == selected["atom_id"]), None)
        if actual:
            low, high = bootstrap_ci(collapse_dates(residuals[3]), atom_sets[3][selected["atom_id"]],
                                     args.bootstrap, args.seed + 13)
            same_positive = float(actual["standardized_effect"]) > 0
            passed = (
                same_positive and low > 0
                and min(actual["on_stocks"], actual["off_stocks"]) >= MIN_CONFIRM_STOCKS
                and min(actual["on_samples"], actual["off_samples"]) >= MIN_CONFIRM_SAMPLES
                and actual["max_date_share"] <= 0.5 and actual["max_stock_share"] <= 0.5
            )
            value = {
                **actual, "w1_standardized_effect": selected["w1_standardized_effect"],
                "bootstrap_ci_low": low, "bootstrap_ci_high": high,
                "same_positive_direction_as_w1_w2": int(same_positive),
                "ci_above_zero": int(low > 0), "passed": int(passed),
            }
            w3_rows.append(value)
            if passed:
                final_row = value

    synthetic = synthetic_control()
    require(synthetic["passed"], "synthetic planted sell interaction control failed")
    run_material = json.dumps({
        "study": STUDY_ID,
        "decisionBases": {key: value["databaseSha256"] for key, value in identities.items()},
        "market": EXPECTED_MARKET_TECHNICAL_SHA256,
        "atoms": EXPECTED_ATOM_CSV_SHA256,
        "methodVersion": 2,
        "permutations": args.permutations, "bootstrap": args.bootstrap, "seed": args.seed,
    }, sort_keys=True).encode()
    run_id = f"mkt-r02-d2-sell-interaction-{hashlib.sha256(run_material).hexdigest()[:12]}"
    output = args.output_root / run_id
    require(not output.exists(), f"output already exists: {output}")
    output.mkdir(parents=True)

    summary = {
        "studyID": STUDY_ID, "runID": run_id,
        "conclusion": "發現一個可送 Sample A 完整回測的市場賣出候選" if final_row else "未發現可送完整回測的穩定市場賣出交互",
        "eligibleEvents": len(events),
        "actualExitEvents": sum(int(row["actual_exit"]) for row in events),
        "markedToMarketEvents": sum(not int(row["actual_exit"]) for row in events),
        "residualizedEventsByWindow": {f"W{window}": len(residuals[window]) for window in (1, 2, 3)},
        "canonicalPriceAtoms": len(atoms),
        "w1CapacityEligible": len(w1_capacity), "w1FrozenCandidates": len(frozen),
        "w2ConfirmedCandidates": len(w2_confirmed), "w3PassedCandidates": int(final_row is not None),
        "syntheticControlPassed": synthetic["passed"],
        "selectedCandidate": ({
            "atomID": final_row["atom_id"], "condition": final_row["condition"], "vote": "sell +1",
            "stockContext": "one vote short of S-T01a/c/e/f/g/h; S-T01d nested in S-T01c",
        } if final_row else None),
    }
    manifest = {
        "studyID": STUDY_ID, "runID": run_id, **EXPECTED_COMMON,
        "samples": ["A", "B", "C", "D"], "decisionBases": identities,
        "marketSnapshotID": market_manifest.get("snapshotID"),
        "marketTechnicalSha256": EXPECTED_MARKET_TECHNICAL_SHA256,
        "atomInventory": str(args.atom_inventory), "atomCsvSha256": EXPECTED_ATOM_CSV_SHA256,
        "method": {
            "eligibleContext": "HOLD where sell +1 opens S-T01a/c/e/f/g/h; S-T01d nested in S-T01c; S-T01b and S-T02 excluded",
            "outcome": "hypothetical same-day liquidation round score minus formal later exit/window-end round score",
            "matching": "Sample, eligible gate signature, Grade, score, ROI bucket, holding-days bucket, investment count",
            "marketUnit": "same market date collapsed before inference",
            "null": "common circular shift of the full market-date series within each window; positive family maximum",
            "capacity": {"datesPerSide": MIN_DATES_PER_SIDE, "stocksPerSide": MIN_STOCKS_PER_SIDE},
            "windows": "W1 formation, W2 frozen-family confirmation, W3 one-candidate bootstrap confirmation",
            "permutations": args.permutations, "bootstrapDraws": args.bootstrap, "seed": args.seed,
        },
        "artifacts": [
            "eligible-events.csv", "coverage.csv", "w1-capacity.csv", "w1-null-max.csv", "w1-frozen.csv",
            "w2-family.csv", "w2-null-max.csv", "w2-confirmed.csv", "w3-final.csv",
            "synthetic-control.json", "quality-report.json", "summary.json", "report.md",
        ],
    }
    write_csv(output / "eligible-events.csv", events)
    write_csv(output / "coverage.csv", coverage)
    write_csv(output / "w1-capacity.csv", w1_scored)
    write_csv(output / "w1-null-max.csv", w1_null)
    write_csv(output / "w1-frozen.csv", frozen, INTERACTION_FIELDS)
    write_csv(output / "w2-family.csv", w2_evaluated, INTERACTION_FIELDS)
    write_csv(output / "w2-null-max.csv", w2_null)
    write_csv(output / "w2-confirmed.csv", w2_confirmed, INTERACTION_FIELDS)
    write_csv(output / "w3-final.csv", w3_rows, INTERACTION_FIELDS)
    (output / "synthetic-control.json").write_text(json.dumps(synthetic, indent=2) + "\n")
    quality = {
        "decisionBaseIdentityPassed": True, "marketSnapshotHashPassed": True,
        "atomInventoryHashPassed": True, "eligibleEventCountPassed": len(events) == EXPECTED_EVENT_COUNT,
        "sameMarketDateCollapsed": True, "actualAndNullCapacitySymmetric": True,
        "st01dNestedWithinSt01cVerified": True,
        "syntheticControlPassed": synthetic["passed"], "completionEligible": synthetic["passed"],
    }
    (output / "quality-report.json").write_text(json.dumps(quality, indent=2) + "\n")
    (output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    (output / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    (output / "report.md").write_text(report(summary, final_row), encoding="utf-8")
    (output / ".complete").write_text(run_id + "\n")
    print(output)
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
