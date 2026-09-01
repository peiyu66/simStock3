#!/usr/bin/env python3

from __future__ import annotations

import csv
import json
import math
import sqlite3
from collections import defaultdict
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BASE_ID = "b-abcd9-v2-s31-st02h-efficiency-loss-cut-20260831-t2-s38-e4e41e1f1dfe-fixed3y-20260722-v6"
RUN_ID = "abot02-s1-b-valid-grade-nonbottom-add-m1-t2s38-9y-fixed3y-600w-20260901"
CANDIDATE_DIR_ID = "A-BOT02-S1"
CANDIDATE_ID = "aBot02S1"
RULE_COMMIT = "e4e41e1f1dfecb2fd320d347023a2095366ee0ec"
SAMPLE_ID = "B"
BASE_DIR = ROOT / "exports/backtest-decision-bases" / BASE_ID
DELTA_DIR = ROOT / "exports/backtest-decision-deltas" / BASE_ID / CANDIDATE_DIR_ID
RUN_DIR = ROOT / "exports/backtest-candidate-runs" / RUN_ID
OUTPUT_DIR = ROOT / "exports/add-bottoming-study/abot02-s1-b-segmentation-t2s38-20260901"

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


def json_load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def sqlite_ok(path: Path) -> None:
    with sqlite3.connect(path) as connection:
        result = connection.execute("PRAGMA integrity_check").fetchone()[0]
    require(result == "ok", f"SQLite integrity failed: {path}: {result}")


def efficiency_score(roi: float, days: float) -> float:
    return roi * 100.0 / days if roi >= 0 else roi * days / 100.0


def close_proxy(unit_cost: float, unit_roi: float) -> float:
    return unit_cost * (1.0 + unit_roi / 100.0)


def fmt(value: float | None, digits: int = 3) -> str:
    if value is None:
        return "—"
    return f"{value:.{digits}f}"


def validate_inputs() -> tuple[dict, dict, dict]:
    base_manifest = json_load(BASE_DIR / "manifest.json")
    delta_summary = json_load(DELTA_DIR / "decision-summary.json")
    run_manifest = json_load(RUN_DIR / "manifest.json")
    require((BASE_DIR / ".complete").is_file(), "DecisionBase .complete missing")
    require((BASE_DIR / ".p4b-complete").is_file(), "DecisionBase .p4b-complete missing")
    require((DELTA_DIR / ".complete").is_file(), "DecisionDelta .complete missing")
    require((DELTA_DIR / ".analysis-complete").is_file(), "DecisionDelta analysis marker missing")
    require((RUN_DIR / ".complete").read_text().strip() == RUN_ID, "Run marker mismatch")
    require(base_manifest["sampleID"] == SAMPLE_ID, "DecisionBase sample mismatch")
    require(base_manifest["ruleCommit"] == RULE_COMMIT, "DecisionBase rule commit mismatch")
    require(delta_summary["candidateID"] == CANDIDATE_ID, "Candidate ID mismatch")
    require(delta_summary["candidateRunID"] == RUN_ID, "Candidate run mismatch")
    require(delta_summary["baselineDecisionBaseID"] == BASE_ID, "DecisionBase ID mismatch")
    require(delta_summary["prestateMismatchCount"] == 0, "Pre-state mismatch found")
    require(run_manifest["runID"] == RUN_ID, "Run manifest ID mismatch")
    require(run_manifest["sampleID"] == SAMPLE_ID, "Run manifest sample mismatch")
    require(run_manifest["dataRuleVersion"] == "T2/S38", "Data rule mismatch")
    sqlite_ok(BASE_DIR / "decisions.sqlite")
    sqlite_ok(DELTA_DIR / "decision-delta.sqlite")
    return base_manifest, delta_summary, run_manifest


def same_number(candidate: float | None, baseline: float) -> bool:
    return candidate is None or abs(candidate - baseline) < 1e-6


def load_events(expected_count: int = 13) -> list[dict]:
    delta_connection = sqlite3.connect(DELTA_DIR / "decision-delta.sqlite")
    delta_connection.row_factory = sqlite3.Row
    delta_connection.execute("ATTACH DATABASE ? AS base", (str(BASE_DIR / "decisions.sqlite"),))
    query = """
        SELECT delta.delta_id,
               window.start_date, window.end_date,
               event.window_id, event.stock_key, stock.stock_id, stock.name, stock.group_name,
               event.event_id, event.trade_date,
               observation.grade_name, observation.fit_level,
               observation.fit_trend_phase, observation.fit_observation_count,
               event.decision_score AS baseline_decision_score,
               COALESCE(delta.candidate_score, event.decision_score) AS candidate_decision_score,
               event.inventory_before, event.unit_cost_before, event.unit_roi_before,
               event.holding_days_before, event.invest_times_before, event.balance_before,
               delta.candidate_inventory_before, delta.candidate_unit_cost_before,
               delta.candidate_unit_roi_before, delta.candidate_holding_days_before,
               delta.candidate_invest_times_before, delta.candidate_balance_before,
               outcome.baseline_roi, outcome.candidate_roi,
               outcome.baseline_average_days, outcome.candidate_average_days,
               outcome.baseline_rounds, outcome.candidate_rounds,
               outcome.baseline_money_lacked, outcome.candidate_money_lacked
        FROM event_deltas AS delta
        JOIN base.decision_events AS event ON event.event_id = delta.baseline_event_id
        JOIN base.windows AS window ON window.window_id = event.window_id
        JOIN base.stocks AS stock ON stock.stock_key = event.stock_key
        JOIN base.event_strategy_fit_observations AS link ON link.event_id = event.event_id
        JOIN base.strategy_fit_observations AS observation
          ON observation.observation_id = link.observation_id
        JOIN period_outcome_deltas AS outcome
          ON outcome.window_start = window.start_date
         AND outcome.window_end = window.end_date
         AND outcome.stock_id = stock.stock_id
        WHERE event.phase = 4
          AND event.executed_action = 'ADD'
          AND COALESCE(delta.candidate_executed_action, event.executed_action) = 'NONE'
        ORDER BY window.start_date, stock.stock_id, event.trade_date
    """
    candidates = []
    for raw in delta_connection.execute(query):
        row = dict(raw)
        if not all(
            [
                same_number(row["candidate_inventory_before"], row["inventory_before"]),
                same_number(row["candidate_unit_cost_before"], row["unit_cost_before"]),
                same_number(row["candidate_unit_roi_before"], row["unit_roi_before"]),
                same_number(row["candidate_holding_days_before"], row["holding_days_before"]),
                same_number(row["candidate_invest_times_before"], row["invest_times_before"]),
                same_number(row["candidate_balance_before"], row["balance_before"]),
            ]
        ):
            continue
        votes = list(
            delta_connection.execute(
                """
                SELECT rule_id, contribution
                FROM base.event_vote_lookup
                WHERE event_id = ? AND contribution != 0
                ORDER BY rule_id
                """,
                (row["event_id"],),
            )
        )
        row["votes"] = "|".join(f"{vote['rule_id']}:{vote['contribution']:g}" for vote in votes)
        row["a_p02"] = int(any(vote["rule_id"] == "A-P02" for vote in votes))
        row["trend_phase"] = PHASE_NAMES[row["fit_trend_phase"]]
        row["baseline_efficiency_score"] = efficiency_score(
            row["baseline_roi"], row["baseline_average_days"]
        )
        row["candidate_efficiency_score"] = efficiency_score(
            row["candidate_roi"], row["candidate_average_days"]
        )
        row["efficiency_score_delta"] = (
            row["candidate_efficiency_score"] - row["baseline_efficiency_score"]
        )
        candidates.append(row)

    require(
        len(candidates) == expected_count,
        f"Expected {expected_count} direct blocked ADD events, found {len(candidates)}",
    )
    delta_by_baseline_event = {
        row["baseline_event_id"]: dict(row)
        for row in delta_connection.execute(
            "SELECT * FROM event_deltas WHERE baseline_event_id IS NOT NULL"
        )
    }
    base_connection = sqlite3.connect(BASE_DIR / "decisions.sqlite")
    base_connection.row_factory = sqlite3.Row
    for row in candidates:
        future = base_connection.execute(
            """
            SELECT * FROM decision_events
            WHERE window_id = ? AND stock_key = ? AND trade_date > ? AND phase IN (3, 4)
            ORDER BY trade_date, phase
            """,
            (row["window_id"], row["stock_key"], row["trade_date"]),
        )
        next_add = None
        sell_date = None
        add_phase_dates = set()
        for baseline_event in future:
            delta = delta_by_baseline_event.get(baseline_event["event_id"], {})
            candidate_action = delta.get("candidate_executed_action") or baseline_event["executed_action"]
            if baseline_event["phase"] == 4:
                add_phase_dates.add(baseline_event["trade_date"])
                if candidate_action == "ADD" and next_add is None:
                    candidate_cost = delta.get("candidate_unit_cost_before")
                    if candidate_cost is None:
                        candidate_cost = baseline_event["unit_cost_before"]
                    candidate_roi = delta.get("candidate_unit_roi_before")
                    if candidate_roi is None:
                        candidate_roi = baseline_event["unit_roi_before"]
                    next_add = {
                        "date": baseline_event["trade_date"],
                        "price": close_proxy(candidate_cost, candidate_roi),
                        "trading_days": len(add_phase_dates),
                    }
            if baseline_event["phase"] == 3 and candidate_action == "SELL":
                sell_date = baseline_event["trade_date"]
                break
        source_price = close_proxy(row["unit_cost_before"], row["unit_roi_before"])
        row["next_candidate_add_date"] = next_add["date"] if next_add else None
        row["trading_days_to_next_add"] = next_add["trading_days"] if next_add else None
        row["price_return_to_next_add"] = (
            100.0 * (next_add["price"] / source_price - 1.0) if next_add else None
        )
        row["candidate_sell_date"] = sell_date
    base_connection.close()
    delta_connection.close()
    return candidates


def summarize(key: str, rows: list[dict]) -> dict:
    deltas = [row["efficiency_score_delta"] for row in rows]
    shifted = [row for row in rows if row["next_candidate_add_date"] is not None]
    lower = [row for row in shifted if row["price_return_to_next_add"] < 0]
    return {
        "segment": key,
        "events": len(rows),
        "stocks": len({row["stock_id"] for row in rows}),
        "windows": len({row["start_date"] for row in rows}),
        "groups": len({row["group_name"] for row in rows}),
        "positive": sum(delta > 1e-9 for delta in deltas),
        "negative": sum(delta < -1e-9 for delta in deltas),
        "zero": sum(abs(delta) <= 1e-9 for delta in deltas),
        "sum_efficiency_score_delta": sum(deltas),
        "mean_efficiency_score_delta": sum(deltas) / len(deltas),
        "shifted_adds": len(shifted),
        "lower_shifted_adds": len(lower),
        "cancelled_adds": len(rows) - len(shifted),
        "rounds_delta": sum(row["candidate_rounds"] - row["baseline_rounds"] for row in rows),
        "money_lacked_increase": sum(
            row["candidate_money_lacked"] > row["baseline_money_lacked"] for row in rows
        ),
    }


def segment_rows(events: list[dict]) -> list[dict]:
    segments: list[tuple[str, list[dict]]] = [
        ("all", events),
        ("fit_score_positive", [row for row in events if row["fit_level"] > 0]),
        ("fit_score_nonpositive", [row for row in events if row["fit_level"] <= 0]),
        (
            "grade_fine_or_better",
            [row for row in events if row["grade_name"] in {"fine", "high", "wow"}],
        ),
        (
            "grade_weak_or_below",
            [row for row in events if row["grade_name"] in {"damn", "low", "weak"}],
        ),
    ]
    for field in ("grade_name", "trend_phase", "a_p02"):
        grouped: dict[str, list[dict]] = defaultdict(list)
        for row in events:
            grouped[str(row[field])].append(row)
        segments.extend((f"{field}:{key}", rows) for key, rows in sorted(grouped.items()))
    return [summarize(key, rows) for key, rows in segments if rows]


def write_csv(path: Path, rows: list[dict], fields: list[str]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def report(events: list[dict], segments: list[dict], delta_summary: dict) -> str:
    lookup = {row["segment"]: row for row in segments}
    positive = lookup["fit_score_positive"]
    nonpositive = lookup["fit_score_nonpositive"]
    lines = [
        "# A-BOT02-S1-B 差異區隔診斷",
        "",
        f"Sample B 固定三年主分 {114.081:.3f} → {112.748:.3f}（{delta_summary['combinedMainScoreDelta']:+.3f}）。本診斷只保留前態一致、Baseline 實際 ADD 而候選未 ADD，且形成期末差異的 13 個股票窗口；不把 {delta_summary['changedEventCount']:,} 個連鎖事件當成獨立案例。",
        "",
        "## 13 個直接案例",
        "",
        "| 窗口 | 股票 | Grade／連續分數 | 階段 | 原加碼日 | 候選下次加碼 | 價格變化 | 個股效率分數 Delta | 輪次 Delta |",
        "|---|---|---|---|---|---|---:|---:|---:|",
    ]
    for row in events:
        next_add = str(row["next_candidate_add_date"]) if row["next_candidate_add_date"] else "未再加碼"
        lines.append(
            f"| {row['start_date']} | {row['stock_id']} {row['name']} | {row['grade_name']}／{row['fit_level']:.3f} | "
            f"{row['trend_phase']} | {row['trade_date']} | {next_add} | "
            f"{fmt(row['price_return_to_next_add'])}% | {row['efficiency_score_delta']:+.3f} | "
            f"{row['candidate_rounds'] - row['baseline_rounds']:+.0f} |"
        )
    lines.extend(
        [
            "",
            "## 可解釋分界",
            "",
            f"交易當下 Grade 連續效率分數 `> 0` 有 {positive['events']} 件，跨 {positive['stocks']} 檔、三窗口與兩股群，{positive['positive']} 件全部改善；個股效率分數 Delta 診斷合計 {positive['sum_efficiency_score_delta']:+.3f}。其中 {positive['shifted_adds']} 件延至更低價加碼、{positive['cancelled_adds']} 件整輪未再加碼。",
            "",
            f"連續效率分數 `<= 0` 有 {nonpositive['events']} 件，只有 {nonpositive['positive']} 件改善、{nonpositive['negative']} 件退步；診斷合計 {nonpositive['sum_efficiency_score_delta']:+.3f}。負向不是單一 Grade 或單一窗口造成。",
            "",
            f"categorical Grade 的 fine 以上雖為 {lookup['grade_fine_or_better']['positive']}/{lookup['grade_fine_or_better']['events']} 改善，但只涵蓋 {lookup['grade_fine_or_better']['events']} 件；`fit score > 0` 另保留兩件 exact weak 的改善案例，因此連續分數正負比 exact wow 或 fine 分界更符合已觀察機制。",
            "",
            "13 件全部都有 A-P02；這是 Sample B 先前無 A-P02 窄版沒有關鍵事件所形成的樣本特性，不表示下一規則以 A-P02 為條件。改善與退步都同時存在於 A-P02 路徑，故 A-P02 本身不能區隔。",
            "",
            "個股效率分數 Delta 只用來形成條件，不能相加取代完整候選分數。`fit score > 0` 是同一形成樣本內的自然符號界線，仍須以完整重播確認路徑，之後再送未參與分界形成的樣本。",
            "",
            "## 下一候選",
            "",
            "`A-BOT02-S2-B`：有效 Grade、適配趨勢已暖機、Grade 連續效率分數 `> 0`，且不是惡化確認探底時，對整體 aWant 獨立扣 1。其他票、門檻、A-E、策略 S31、T2/S38、600 萬元及兩次自動加碼全部固定。若 B 未改善即停止；若 B 改善且 5 個目標案例的延後／取消機制吻合，再送未參與分界形成的 Sample A。",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> None:
    base_manifest, delta_summary, run_manifest = validate_inputs()
    events = load_events()
    segments = segment_rows(events)
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    event_fields = [
        "start_date", "end_date", "stock_id", "name", "group_name", "trade_date",
        "grade_name", "fit_level", "trend_phase", "fit_observation_count", "a_p02",
        "baseline_decision_score", "candidate_decision_score", "unit_roi_before",
        "holding_days_before", "invest_times_before", "votes", "next_candidate_add_date",
        "trading_days_to_next_add", "price_return_to_next_add", "candidate_sell_date",
        "baseline_roi", "candidate_roi", "baseline_average_days", "candidate_average_days",
        "baseline_rounds", "candidate_rounds", "baseline_efficiency_score",
        "candidate_efficiency_score", "efficiency_score_delta", "baseline_money_lacked",
        "candidate_money_lacked",
    ]
    segment_fields = list(segments[0].keys())
    write_csv(OUTPUT_DIR / "events.csv", events, event_fields)
    write_csv(OUTPUT_DIR / "segments.csv", segments, segment_fields)
    (OUTPUT_DIR / "report.md").write_text(report(events, segments, delta_summary), encoding="utf-8")
    manifest = {
        "studyID": "A-BOT02-S1-B-SEGMENTATION",
        "sampleID": "B",
        "baseline": "v19",
        "dataRuleVersion": run_manifest["dataRuleVersion"],
        "ruleCommit": base_manifest["ruleCommit"],
        "decisionBaseID": BASE_ID,
        "candidateID": CANDIDATE_ID,
        "candidateRunID": RUN_ID,
        "directBlockedAddEvents": len(events),
        "files": ["manifest.json", "report.md", "events.csv", "segments.csv"],
    }
    (OUTPUT_DIR / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(OUTPUT_DIR)


if __name__ == "__main__":
    main()
