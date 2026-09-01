#!/usr/bin/env python3

from __future__ import annotations

import csv
import json

import abot02_candidate_segmentation as study


BASE_ID = "b-abcd9-v2-s31-st02h-efficiency-loss-cut-20260831-t2-s38-e4e41e1f1dfe-fixed3y-20260722-v6"
RUN_ID = "abot02-s3-b-score-gt200-nonbottom-add-m1-t2s38-9y-fixed3y-600w-20260901"
OUTPUT_DIR = (
    study.ROOT / "exports/add-bottoming-study/abot02-s3-b-validation-t2s38-20260901"
)
EXPECTED_EVENTS = {
    (20200722, "2642", 20210713),
    (20230722, "3653", 20260507),
}


def configure() -> None:
    study.BASE_ID = BASE_ID
    study.RUN_ID = RUN_ID
    study.CANDIDATE_DIR_ID = "A-BOT02-S3"
    study.CANDIDATE_ID = "aBot02S3"
    study.SAMPLE_ID = "B"
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
    events = study.load_events(expected_count=2)
    actual_events = {
        (row["start_date"], row["stock_id"], row["trade_date"]) for row in events
    }
    study.require(actual_events == EXPECTED_EVENTS, "S3-B target event set mismatch")
    study.require(all(row["fit_level"] > 200 for row in events), "S3-B included score <=200")
    study.require(
        all(row["price_return_to_next_add"] < 0 for row in events),
        "S3-B delayed ADD was not lower",
    )
    study.require(
        all(row["efficiency_score_delta"] > 0 for row in events),
        "S3-B direct case regressed",
    )
    study.require(
        all(row["candidate_money_lacked"] == 0 for row in events),
        "S3-B direct case lacked money",
    )

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
    with (OUTPUT_DIR / "events.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(events)

    lines = [
        "# A-BOT02-S3-B 完整重播機制驗證",
        "",
        "Sample B 固定三年主分 114.081 → 114.750 "
        f"（{delta_summary['combinedMainScoreDelta']:+.3f}）。較弱／較強股群分別 +0.228／+0.441；"
        "只有 2020 較弱與 2023 較強窗口改變。DecisionDelta 為 0 pre-state mismatch、"
        "0 無效值及 0 無交易排除。",
        "",
        "| 窗口 | 股票 | Grade／連續分數 | 原加碼日 | 候選下次加碼 | 價格變化 | ROI | 週期 | 輪次 | 個股效率分數 Delta |",
        "|---|---|---|---|---|---:|---:|---:|---:|---:|",
    ]
    for row in events:
        lines.append(
            f"| {row['start_date']} | {row['stock_id']} {row['name']} | "
            f"{row['grade_name']}／{row['fit_level']:.3f} | {row['trade_date']} | "
            f"{row['next_candidate_add_date']} | {row['price_return_to_next_add']:.3f}% | "
            f"{row['baseline_roi']:.3f}% → {row['candidate_roi']:.3f}% | "
            f"{row['baseline_average_days']:.3f} → {row['candidate_average_days']:.3f} | "
            f"{row['baseline_rounds']:.0f} → {row['candidate_rounds']:.0f} | "
            f"{row['efficiency_score_delta']:+.3f} |"
        )
    lines.extend(
        [
            "",
            "兩件直接結果差異恰好是事前目標：宅配通延後 18 個加碼評估日、價格低 16.000%；"
            "健策延後 4 個加碼評估日、價格低 8.903%。兩件 ROI 與個股效率分數都改善，"
            "輪次沒有下降，也沒有本金不足。",
            "",
            "A／B 都已由完整重播確認 200 分界會保留形成案例的正向路徑，但兩者都參與分界形成；"
            "下一步仍須原條件送未參與分界形成的 Sample C，才能取得獨立證據。",
            "",
        ]
    )
    (OUTPUT_DIR / "report.md").write_text("\n".join(lines), encoding="utf-8")
    manifest = {
        "studyID": "A-BOT02-S3-B-VALIDATION",
        "sampleID": "B",
        "baseline": "v19",
        "dataRuleVersion": run_manifest["dataRuleVersion"],
        "ruleCommit": base_manifest["ruleCommit"],
        "decisionBaseID": BASE_ID,
        "candidateID": "aBot02S3",
        "candidateRunID": RUN_ID,
        "directBlockedAddEvents": 2,
        "files": ["manifest.json", "report.md", "events.csv"],
    }
    (OUTPUT_DIR / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(OUTPUT_DIR)


if __name__ == "__main__":
    main()
