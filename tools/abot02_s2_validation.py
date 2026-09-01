#!/usr/bin/env python3

from __future__ import annotations

import csv
import json
from pathlib import Path

import abot02_candidate_segmentation as study


RUN_ID = "abot02-s2-b-positive-score-nonbottom-add-m1-t2s38-9y-fixed3y-600w-20260901"
CANDIDATE_DIR_ID = "A-BOT02-S2"
CANDIDATE_ID = "aBot02S2"
OUTPUT_DIR = (
    study.ROOT / "exports/add-bottoming-study/abot02-s2-b-validation-t2s38-20260901"
)
EXPECTED_EVENTS = {
    (20170722, "2642", 20190927),
    (20170722, "2912", 20180802),
    (20200722, "1477", 20220629),
    (20200722, "2642", 20210713),
    (20230722, "3653", 20260507),
}


def configure_study() -> None:
    study.RUN_ID = RUN_ID
    study.CANDIDATE_DIR_ID = CANDIDATE_DIR_ID
    study.CANDIDATE_ID = CANDIDATE_ID
    study.DELTA_DIR = (
        study.ROOT
        / "exports/backtest-decision-deltas"
        / study.BASE_ID
        / CANDIDATE_DIR_ID
    )
    study.RUN_DIR = study.ROOT / "exports/backtest-candidate-runs" / RUN_ID


def write_csv(path: Path, rows: list[dict]) -> None:
    fields = [
        "start_date",
        "end_date",
        "stock_id",
        "name",
        "group_name",
        "trade_date",
        "grade_name",
        "fit_level",
        "trend_phase",
        "fit_observation_count",
        "next_candidate_add_date",
        "trading_days_to_next_add",
        "price_return_to_next_add",
        "candidate_sell_date",
        "baseline_roi",
        "candidate_roi",
        "baseline_average_days",
        "candidate_average_days",
        "baseline_rounds",
        "candidate_rounds",
        "baseline_efficiency_score",
        "candidate_efficiency_score",
        "efficiency_score_delta",
        "baseline_money_lacked",
        "candidate_money_lacked",
    ]
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)


def fmt(value: float | None) -> str:
    return "—" if value is None else f"{value:.3f}"


def report(events: list[dict], summary: dict, delta_summary: dict) -> str:
    lines = [
        "# A-BOT02-S2-B 完整重播機制驗證",
        "",
        "Sample B 固定三年主分 114.081 → 114.699 "
        f"（{delta_summary['combinedMainScoreDelta']:+.3f}）。DecisionDelta 前態不一致為 0；"
        "本報告只列 Baseline 實際 ADD、候選在相同前態未 ADD 的直接案例。",
        "",
        "## 五個直接案例",
        "",
        "| 窗口 | 股票 | Grade／連續分數 | 階段 | 原加碼日 | 候選下次加碼 | 價格變化 | 個股效率分數 Delta | 輪次 Delta |",
        "|---|---|---|---|---|---|---:|---:|---:|",
    ]
    for row in events:
        next_add = str(row["next_candidate_add_date"]) if row["next_candidate_add_date"] else "未再加碼"
        lines.append(
            f"| {row['start_date']} | {row['stock_id']} {row['name']} | "
            f"{row['grade_name']}／{row['fit_level']:.3f} | {row['trend_phase']} | "
            f"{row['trade_date']} | {next_add} | {fmt(row['price_return_to_next_add'])}% | "
            f"{row['efficiency_score_delta']:+.3f} | "
            f"{row['candidate_rounds'] - row['baseline_rounds']:+.0f} |"
        )
    lines.extend(
        [
            "",
            "## 核對結論",
            "",
            f"S2 只阻擋上述 {summary['events']} 件，恰好等於 S1 診斷所辨識的五個正分案例；"
            f"跨 {summary['stocks']} 檔、三窗口與兩股群。五件個股效率分數全部改善，"
            f"診斷合計 {summary['sum_efficiency_score_delta']:+.3f}。",
            "",
            f"其中 {summary['shifted_adds']} 件延至更低價加碼，"
            f"{summary['cancelled_adds']} 件該輪不再加碼；沒有新增本金不足。"
            "這符合『正效率路徑仍有等待空間，非探底時先抑制一次加碼』的原假說。",
            "",
            "2017 窗口較弱股群仍由 15.098 降至 14.785（-0.313）。原因是統一超雖把 ROI "
            "由 2.984 提高至 4.311，個股效率分數也微增 +0.238，但平均週期 40 天增至 56 天、"
            "輪次 24 降至 17；股群窗口分數以合併 ROI／合併週期計算，因而形成局部代價。"
            "另外兩個變動窗口分別 +0.843、+1.324，最後 B 合計仍改善 +0.618。",
            "",
            "S2 的 `fit score > 0` 分界來自 Sample B 的 S1 事後診斷，因此 B 只能確認路徑有被收回，"
            "不能視為獨立泛化證據；下一步應原條件送未參與分界形成的 Sample A。",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> None:
    configure_study()
    base_manifest, delta_summary, run_manifest = study.validate_inputs()
    events = study.load_events(expected_count=5)
    actual_events = {
        (row["start_date"], row["stock_id"], row["trade_date"]) for row in events
    }
    study.require(actual_events == EXPECTED_EVENTS, "S2 direct-event set differs from S1 target set")
    study.require(all(row["fit_level"] > 0 for row in events), "Nonpositive fit score reached S2")
    summary = study.summarize("all", events)
    study.require(summary["positive"] == 5, "Not every S2 direct case improved")
    study.require(summary["negative"] == 0, "S2 direct case regressed")
    study.require(summary["lower_shifted_adds"] == 3, "Shifted ADD was not always lower")
    study.require(summary["cancelled_adds"] == 2, "Unexpected cancelled-ADD count")
    study.require(summary["money_lacked_increase"] == 0, "Money lack increased")

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    write_csv(OUTPUT_DIR / "events.csv", events)
    (OUTPUT_DIR / "report.md").write_text(
        report(events, summary, delta_summary), encoding="utf-8"
    )
    manifest = {
        "studyID": "A-BOT02-S2-B-VALIDATION",
        "sampleID": "B",
        "baseline": "v19",
        "dataRuleVersion": run_manifest["dataRuleVersion"],
        "ruleCommit": base_manifest["ruleCommit"],
        "decisionBaseID": study.BASE_ID,
        "candidateID": CANDIDATE_ID,
        "candidateRunID": RUN_ID,
        "directBlockedAddEvents": len(events),
        "files": ["manifest.json", "report.md", "events.csv"],
    }
    (OUTPUT_DIR / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(OUTPUT_DIR)


if __name__ == "__main__":
    main()
