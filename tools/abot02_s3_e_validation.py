#!/usr/bin/env python3

from __future__ import annotations

import csv
import json
import sqlite3

import abot02_candidate_segmentation as study


BASE_ID = "e-abcde9-v2-s31-st02h-efficiency-loss-cut-20260831-t2-s38-e4e41e1f1dfe-fixed3y-20260722-v6"
RUN_ID = "abot02-s3-e-score-gt200-nonbottom-add-m1-t2s38-9y-fixed3y-600w-20260901"
OUTPUT_DIR = (
    study.ROOT / "exports/add-bottoming-study/abot02-s3-e-validation-t2s38-20260901"
)


def configure() -> None:
    study.BASE_ID = BASE_ID
    study.RUN_ID = RUN_ID
    study.CANDIDATE_DIR_ID = "A-BOT02-S3"
    study.CANDIDATE_ID = "aBot02S3"
    study.SAMPLE_ID = "E"
    study.BASE_DIR = study.ROOT / "exports/backtest-decision-bases" / BASE_ID
    study.DELTA_DIR = (
        study.ROOT
        / "exports/backtest-decision-deltas"
        / BASE_ID
        / study.CANDIDATE_DIR_ID
    )
    study.RUN_DIR = study.ROOT / "exports/backtest-candidate-runs" / RUN_ID


def load_timeline() -> list[dict]:
    database = study.DELTA_DIR / "decision-delta.sqlite"
    connection = sqlite3.connect(database)
    connection.row_factory = sqlite3.Row
    connection.execute("ATTACH DATABASE ? AS base", (str(study.BASE_DIR / "decisions.sqlite"),))
    rows = []
    query = """
        SELECT event.trade_date, event.phase,
               event.decision_score AS baseline_score,
               event.executed_action AS baseline_action,
               delta.candidate_score,
               COALESCE(delta.candidate_executed_action, event.executed_action) AS candidate_action,
               event.inventory_before AS baseline_inventory,
               delta.candidate_inventory_before AS candidate_inventory,
               event.unit_cost_before AS baseline_unit_cost,
               delta.candidate_unit_cost_before AS candidate_unit_cost,
               event.unit_roi_before AS baseline_unit_roi,
               delta.candidate_unit_roi_before AS candidate_unit_roi,
               event.roll_rounds_before AS baseline_roll_rounds,
               delta.candidate_roll_rounds_before AS candidate_roll_rounds
        FROM event_deltas AS delta
        JOIN base.decision_events AS event ON event.event_id = delta.baseline_event_id
        JOIN base.windows AS window ON window.window_id = event.window_id
        JOIN base.stocks AS stock ON stock.stock_key = event.stock_key
        WHERE window.start_date = 20230722
          AND stock.stock_id = '4562'
          AND event.trade_date IN (20240729, 20240730, 20240809, 20240813, 20240819)
          AND event.phase IN (0, 1, 3, 4)
        ORDER BY event.trade_date, event.phase
    """
    for raw in connection.execute(query):
        rows.append(dict(raw))
    connection.close()
    return rows


def write_csv(path, rows: list[dict]) -> None:
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)


def main() -> None:
    configure()
    base_manifest, delta_summary, run_manifest = study.validate_inputs()
    events = study.load_events(expected_count=1)
    event = events[0]
    study.require(event["stock_id"] == "4562", "S3-E target is not 穎漢")
    study.require(event["start_date"] == 20230722, "S3-E target window mismatch")
    study.require(event["trade_date"] == 20240729, "S3-E target date mismatch")
    study.require(event["fit_level"] > 200, "S3-E target score is not >200")
    study.require(event["next_candidate_add_date"] is None, "S3-E unexpectedly re-added")
    study.require(event["efficiency_score_delta"] < 0, "S3-E target did not regress")
    study.require(event["candidate_money_lacked"] == 0, "S3-E target lacked money")
    timeline = load_timeline()
    lookup = {(row["trade_date"], row["phase"]): row for row in timeline}
    study.require(lookup[(20240729, 4)]["baseline_action"] == "ADD", "Baseline ADD missing")
    study.require(lookup[(20240729, 4)]["candidate_action"] == "NONE", "Candidate did not block ADD")
    study.require(lookup[(20240730, 0)]["baseline_inventory"] == 193, "Baseline post-ADD inventory mismatch")
    study.require(lookup[(20240730, 0)]["candidate_inventory"] == 82, "Candidate post-block inventory mismatch")
    study.require(lookup[(20240809, 3)]["baseline_action"] == "SELL", "Baseline early SELL missing")
    study.require(lookup[(20240809, 3)]["candidate_action"] == "NONE", "Candidate unexpectedly sold early")
    study.require(lookup[(20240813, 1)]["baseline_action"] == "BUY", "Baseline re-entry missing")
    study.require(lookup[(20240813, 1)]["candidate_action"] == "NONE", "Candidate unexpectedly re-entered")
    study.require(lookup[(20240819, 3)]["candidate_action"] == "SELL", "Candidate late SELL missing")

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    event_fields = [
        "start_date",
        "stock_id",
        "name",
        "group_name",
        "trade_date",
        "grade_name",
        "fit_level",
        "trend_phase",
        "next_candidate_add_date",
        "baseline_roi",
        "candidate_roi",
        "baseline_average_days",
        "candidate_average_days",
        "baseline_rounds",
        "candidate_rounds",
        "efficiency_score_delta",
        "baseline_money_lacked",
        "candidate_money_lacked",
        "votes",
    ]
    with (OUTPUT_DIR / "event.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=event_fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerow(event)
    write_csv(OUTPUT_DIR / "timeline.csv", timeline)

    add_row = lookup[(20240729, 4)]
    post_add = lookup[(20240730, 0)]
    baseline_sell = lookup[(20240809, 3)]
    candidate_sell = lookup[(20240819, 3)]
    report = f"""# A-BOT02-S3-E 完整重播機制驗證

Sample E 固定三年主分 0.442 → -0.399（{delta_summary['combinedMainScoreDelta']:+.3f}）。弱勢壓力乙組零差異；甲組 1.618 → 0.778（-0.841），只有 2023 甲組 3.185 → 0.663（-2.522）。DecisionDelta 為 0 pre-state mismatch、0 無效值、0 無交易排除及 0 本金不足。

唯一結果差異正是穎漢 2023 窗口。2024/07/29 交易 Grade 為 exact wow、連續效率分數 {event['fit_level']:.3f}、改善拉回，正式路徑 aWant 3 加碼，候選扣至 2 而取消；候選在出場前都沒有重新加碼。正式路徑加碼後持股量由 {add_row['baseline_inventory']:.0f} 增至 {post_add['baseline_inventory']:.0f}、單位成本降至 {post_add['baseline_unit_cost']:.3f}；候選仍持有 {post_add['candidate_inventory']:.0f} 單位、成本 {post_add['candidate_unit_cost']:.3f}。

股價反彈後，正式路徑於 2024/08/09 單位 ROI {baseline_sell['baseline_unit_roi']:.3f}% 時賣出，並在 08/13 重新進場；候選同日單位 ROI 只有 {baseline_sell['candidate_unit_roi']:.3f}%，未達賣出條件，直到 08/19 單位 ROI {candidate_sell['candidate_unit_roi']:.3f}% 才賣出。取消加碼因此不是單純少投入資金，而是失去降低成本後的較早獲利出口與下一輪進場。

穎漢窗口 ROI {event['baseline_roi']:.3f}% → {event['candidate_roi']:.3f}%（{event['candidate_roi'] - event['baseline_roi']:+.3f} 個百分點），平均週期 {event['baseline_average_days']:.3f} → {event['candidate_average_days']:.3f} 日，輪次 {event['baseline_rounds']:.0f} → {event['candidate_rounds']:.0f}，個股效率分數 Delta {event['efficiency_score_delta']:+.3f}。ROI、週期與周轉三項都退步。

這個獨立反例表示「連續效率分數極高」不必然代表有餘裕等待真正探底；在強勁反彈路徑中，非探底加碼仍可能透過降低成本，讓既有賣出門檻更早實現。A／B 的三個形成案例有效，但不能外推成 >200 的一般規則。A-BOT02-S3 應停止，不移動 200 分界，也不再切割 E 或新增 Grade 分數網格。
"""
    (OUTPUT_DIR / "report.md").write_text(report, encoding="utf-8")
    manifest = {
        "studyID": "A-BOT02-S3-E-VALIDATION",
        "sampleID": "E",
        "baseline": "v19",
        "dataRuleVersion": run_manifest["dataRuleVersion"],
        "ruleCommit": base_manifest["ruleCommit"],
        "decisionBaseID": BASE_ID,
        "candidateID": "aBot02S3",
        "candidateRunID": RUN_ID,
        "directBlockedAddEvents": 1,
        "files": ["manifest.json", "report.md", "event.csv", "timeline.csv"],
    }
    (OUTPUT_DIR / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(OUTPUT_DIR)


if __name__ == "__main__":
    main()
