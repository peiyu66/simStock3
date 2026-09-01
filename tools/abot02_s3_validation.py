#!/usr/bin/env python3

from __future__ import annotations

import csv
import json

import abot02_candidate_segmentation as study


BASE_ID = "a-abcd9-v2-s31-st02h-efficiency-loss-cut-20260831-t2-s38-e4e41e1f1dfe-fixed3y-20260722-v6"
RUN_ID = "abot02-s3-a-score-gt200-nonbottom-add-m1-t2s38-9y-fixed3y-600w-20260901"
OUTPUT_DIR = (
    study.ROOT / "exports/add-bottoming-study/abot02-s3-a-validation-t2s38-20260901"
)


def configure() -> None:
    study.BASE_ID = BASE_ID
    study.RUN_ID = RUN_ID
    study.CANDIDATE_DIR_ID = "A-BOT02-S3"
    study.CANDIDATE_ID = "aBot02S3"
    study.SAMPLE_ID = "A"
    study.BASE_DIR = study.ROOT / "exports/backtest-decision-bases" / BASE_ID
    study.DELTA_DIR = (
        study.ROOT
        / "exports/backtest-decision-deltas"
        / BASE_ID
        / study.CANDIDATE_DIR_ID
    )
    study.RUN_DIR = study.ROOT / "exports/backtest-candidate-runs" / RUN_ID


def main() -> None:
    configure()
    base_manifest, delta_summary, run_manifest = study.validate_inputs()
    events = study.load_events(expected_count=1)
    event = events[0]
    study.require(event["stock_id"] == "8454", "S3 target is not 富邦媒")
    study.require(event["start_date"] == 20200722, "S3 target window mismatch")
    study.require(event["trade_date"] == 20211004, "S3 target date mismatch")
    study.require(event["fit_level"] > 200, "S3 target score is not >200")
    study.require(event["next_candidate_add_date"] == 20211006, "S3 delayed ADD mismatch")
    study.require(event["price_return_to_next_add"] < 0, "S3 delayed ADD was not lower")
    study.require(event["efficiency_score_delta"] > 0, "S3 target efficiency regressed")
    study.require(event["candidate_money_lacked"] == 0, "S3 target lacked money")

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    fields = [
        "start_date",
        "stock_id",
        "name",
        "group_name",
        "trade_date",
        "grade_name",
        "fit_level",
        "trend_phase",
        "next_candidate_add_date",
        "trading_days_to_next_add",
        "price_return_to_next_add",
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
        writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerow(event)

    report = f"""# A-BOT02-S3-A 完整重播機制驗證

Sample A 固定三年主分 115.619 → 116.908（{delta_summary['combinedMainScoreDelta']:+.3f}）。只有 2020 較弱股群改變，17.885 → 21.753（+3.868）；其餘五個窗口／股群精確零差異。DecisionDelta 為 0 pre-state mismatch、0 無效值及 0 無交易排除。

唯一直接且形成期末結果差異的案例是富邦媒 2020 窗口：2021/10/04 交易 Grade 為 exact wow、連續效率分數 {event['fit_level']:.3f}、階段為改善拉回，正式路徑以 aWant 3 加碼，候選因 S3 扣 1 降為 2 而略過。候選於 2021/10/06 重新加碼，價格低 {abs(event['price_return_to_next_add']):.3f}%；兩條路徑都在 2021/10/21 出場。

富邦媒窗口 ROI {event['baseline_roi']:.3f}% → {event['candidate_roi']:.3f}%（+{event['candidate_roi'] - event['baseline_roi']:.3f} 個百分點），平均週期 {event['baseline_average_days']:.3f} → {event['candidate_average_days']:.3f} 日，完成輪次 {event['baseline_rounds']:.0f} → {event['candidate_rounds']:.0f}，個股效率分數 Delta {event['efficiency_score_delta']:+.3f}，沒有本金不足。也就是更低成本的延後加碼同時提高 ROI、縮短週期並增加一輪，符合事前目標機制。

200 分界由 A／B 的 S2 案例形成，因此 A 的完整重播只能確認負向中低分路徑已被移除；下一步仍須原條件回播 B，之後才可能送未參與分界形成的 Sample C。
"""
    (OUTPUT_DIR / "report.md").write_text(report, encoding="utf-8")
    manifest = {
        "studyID": "A-BOT02-S3-A-VALIDATION",
        "sampleID": "A",
        "baseline": "v19",
        "dataRuleVersion": run_manifest["dataRuleVersion"],
        "ruleCommit": base_manifest["ruleCommit"],
        "decisionBaseID": BASE_ID,
        "candidateID": "aBot02S3",
        "candidateRunID": RUN_ID,
        "directBlockedAddEvents": 1,
        "files": ["manifest.json", "report.md", "event.csv"],
    }
    (OUTPUT_DIR / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(OUTPUT_DIR)


if __name__ == "__main__":
    main()
