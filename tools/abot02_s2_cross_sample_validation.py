#!/usr/bin/env python3

from __future__ import annotations

import csv
import json
from pathlib import Path

import abot02_candidate_segmentation as study


OUTPUT_DIR = (
    study.ROOT
    / "exports/add-bottoming-study/abot02-s2-ab-cross-sample-t2s38-20260901"
)
CONFIGS = [
    {
        "sample": "A",
        "base_id": "a-abcd9-v2-s31-st02h-efficiency-loss-cut-20260831-t2-s38-e4e41e1f1dfe-fixed3y-20260722-v6",
        "run_id": "abot02-s2-a-positive-score-nonbottom-add-m1-t2s38-9y-fixed3y-600w-20260901",
        "expected_events": 7,
    },
    {
        "sample": "B",
        "base_id": "b-abcd9-v2-s31-st02h-efficiency-loss-cut-20260831-t2-s38-e4e41e1f1dfe-fixed3y-20260722-v6",
        "run_id": "abot02-s2-b-positive-score-nonbottom-add-m1-t2s38-9y-fixed3y-600w-20260901",
        "expected_events": 5,
    },
]


def load(config: dict) -> tuple[list[dict], dict]:
    study.BASE_ID = config["base_id"]
    study.RUN_ID = config["run_id"]
    study.CANDIDATE_DIR_ID = "A-BOT02-S2"
    study.CANDIDATE_ID = "aBot02S2"
    study.SAMPLE_ID = config["sample"]
    study.BASE_DIR = study.ROOT / "exports/backtest-decision-bases" / study.BASE_ID
    study.DELTA_DIR = (
        study.ROOT
        / "exports/backtest-decision-deltas"
        / study.BASE_ID
        / study.CANDIDATE_DIR_ID
    )
    study.RUN_DIR = study.ROOT / "exports/backtest-candidate-runs" / study.RUN_ID
    _, delta_summary, _ = study.validate_inputs()
    events = study.load_events(expected_count=config["expected_events"])
    for event in events:
        event["sample"] = config["sample"]
    return events, delta_summary


def range_name(score: float) -> str:
    if score <= 10:
        return "0_to_10"
    if score <= 20:
        return "10_to_20"
    if score <= 200:
        return "20_to_200"
    return "over_200"


def summarize(rows: list[dict]) -> dict:
    deltas = [row["efficiency_score_delta"] for row in rows]
    return {
        "events": len(rows),
        "samples": len({row["sample"] for row in rows}),
        "stocks": len({(row["sample"], row["stock_id"]) for row in rows}),
        "windows": len({row["start_date"] for row in rows}),
        "groups": len({row["group_name"] for row in rows}),
        "positive": sum(value > 1e-9 for value in deltas),
        "negative": sum(value < -1e-9 for value in deltas),
        "sum_efficiency_score_delta": sum(deltas),
    }


def write_events(rows: list[dict]) -> None:
    fields = [
        "sample",
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
        writer.writerows(rows)


def write_ranges(rows: list[dict]) -> list[dict]:
    ranges = []
    for name in ("0_to_10", "10_to_20", "20_to_200", "over_200"):
        selected = [row for row in rows if range_name(row["fit_level"]) == name]
        result = {"range": name, **summarize(selected)}
        ranges.append(result)
    with (OUTPUT_DIR / "score-ranges.csv").open(
        "w", newline="", encoding="utf-8"
    ) as handle:
        writer = csv.DictWriter(handle, fieldnames=list(ranges[0].keys()))
        writer.writeheader()
        writer.writerows(ranges)
    return ranges


def report(rows: list[dict], summaries: dict, ranges: list[dict]) -> str:
    a_rows = [row for row in rows if row["sample"] == "A"]
    over_200 = next(row for row in ranges if row["range"] == "over_200")
    lines = [
        "# A-BOT02-S2 A／B 交叉案例診斷",
        "",
        "完整重播結果方向反轉：Sample B 114.081 → 114.699（+0.618），"
        "Sample A 115.619 → 113.191（-2.428）。兩份 DecisionDelta 均為 0 pre-state mismatch、"
        "0 無效值、0 無交易排除及 0 本金不足。",
        "",
        "## Sample A 七個直接案例",
        "",
        "| 窗口 | 股票 | 股群 | Grade／連續分數 | 階段 | 原加碼日 | 候選下次加碼 | 價格變化 | 個股效率分數 Delta |",
        "|---|---|---|---|---|---|---|---:|---:|",
    ]
    for row in a_rows:
        next_add = str(row["next_candidate_add_date"]) if row["next_candidate_add_date"] else "未再加碼"
        price = "—" if row["price_return_to_next_add"] is None else f"{row['price_return_to_next_add']:.3f}%"
        lines.append(
            f"| {row['start_date']} | {row['stock_id']} {row['name']} | {row['group_name']} | "
            f"{row['grade_name']}／{row['fit_level']:.3f} | {row['trend_phase']} | "
            f"{row['trade_date']} | {next_add} | {price} | "
            f"{row['efficiency_score_delta']:+.3f} |"
        )
    lines.extend(
        [
            "",
            "Sample A 七件為 2 正／5 負；五件 exact weak 中只有分數 9.820 的豐泰改善，"
            "另外四件分數 12.053～21.165 全部退步。兩件 exact wow 則分成分數 89.903 的南電退步、"
            "329.425 的富邦媒改善。categorical Grade、改善拉回／惡化反彈及 A-P02 都不能單獨區隔。",
            "",
            "## A／B 的連續分數分段",
            "",
            "| 連續分數 | 案例 | 正／負 | 個股效率分數 Delta 合計 |",
            "|---|---:|---:|---:|",
        ]
    )
    labels = {
        "0_to_10": "0～10",
        "10_to_20": ">10～20",
        "20_to_200": ">20～200",
        "over_200": ">200",
    }
    for row in ranges:
        lines.append(
            f"| {labels[row['range']]} | {row['events']} | "
            f"{row['positive']}／{row['negative']} | "
            f"{row['sum_efficiency_score_delta']:+.3f} |"
        )
    lines.extend(
        [
            "",
            f"最簡單的乾淨分支是 `Grade 連續效率分數 > 200`：{over_200['events']} 件全部改善，"
            f"跨 {over_200['samples']} 樣本、{over_200['stocks']} 檔、{over_200['windows']} 窗口與"
            f"兩股群，個股效率分數 Delta 合計 {over_200['sum_efficiency_score_delta']:+.3f}。"
            "三件為 B 宅配通 255.599、B 健策 298.382、A 富邦媒 329.425。",
            "",
            "`0～10` 雖也是 2／2 改善，但把它與 `> 200` 拼成不連續雙尾規則，"
            "需要兩套不同機制解釋且明顯增加事後切割；fine 的單一正例也不足以另開一段。"
            "因此下一個最小重組只保留 `> 200` 上界，不做多段 Grade 分數網格。",
            "",
            "這個 200 分界由 A／B 案例形成，仍不是獨立證據。下一候選應先在退步的 Sample A "
            "完整重播，確認移除中低分負向路徑後是否轉正；A 不改善即停止。A 若改善，再回播 B "
            "確認沒有失去原有正向效果；A／B 都成立後仍須送未參與分界形成的 Sample C。",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> None:
    all_events = []
    summaries = {}
    for config in CONFIGS:
        events, delta_summary = load(config)
        all_events.extend(events)
        summaries[config["sample"]] = delta_summary
    all_events.sort(key=lambda row: (row["sample"], row["start_date"], row["stock_id"]))
    ranges = []
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    write_events(all_events)
    ranges = write_ranges(all_events)
    over_200 = next(row for row in ranges if row["range"] == "over_200")
    study.require(over_200["events"] == 3, "Unexpected >200 event count")
    study.require(over_200["positive"] == 3, ">200 contains nonpositive case")
    study.require(over_200["negative"] == 0, ">200 contains negative case")
    study.require(over_200["samples"] == 2, ">200 does not cross samples")
    (OUTPUT_DIR / "report.md").write_text(
        report(all_events, summaries, ranges), encoding="utf-8"
    )
    manifest = {
        "studyID": "A-BOT02-S2-AB-CROSS-SAMPLE",
        "samples": [config["sample"] for config in CONFIGS],
        "baseline": "v19",
        "dataRuleVersion": "T2/S38",
        "ruleCommit": study.RULE_COMMIT,
        "candidateID": "aBot02S2",
        "candidateRunIDs": [config["run_id"] for config in CONFIGS],
        "directBlockedAddEvents": len(all_events),
        "files": ["manifest.json", "report.md", "events.csv", "score-ranges.csv"],
    }
    (OUTPUT_DIR / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(OUTPUT_DIR)


if __name__ == "__main__":
    main()
