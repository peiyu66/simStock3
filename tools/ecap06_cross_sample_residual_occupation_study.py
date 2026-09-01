#!/usr/bin/env python3
"""E-CAP06-D0-ABCD: cross-sample residual holding diagnosis after S-T02h."""

from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path

from ecap03_long_negative_holding_study import (
    HORIZONS,
    connect_readonly,
    fmt,
    horizon_summary,
    read_json,
    write_csv,
)
from ecap05_residual_occupation_study import build_fixed


STUDY_ID = "E-CAP06-D0-ABCD"
EXPECTED_SAMPLES = {"A", "B", "C", "D"}
EXPECTED_COMMON = {
    "dataRuleVersion": "T2/S38",
    "ruleVersion": "s31-st02h-efficiency-loss-cut-20260831",
    "ruleCommit": "e4e41e1f1dfecb2fd320d347023a2095366ee0ec",
    "through": "2026/07/22",
    "moneyBaseWan": 600,
    "automaticInvestments": 2,
}


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--decision-base",
        action="append",
        required=True,
        metavar="SAMPLE=DIR",
        help="Repeat for Sample A, B, C, and D.",
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
        raise ValueError(f"expected A/B/C/D, received {sorted(result)}")
    return result


def verify_identity(specs: dict[str, Path]) -> dict[str, dict]:
    identities: dict[str, dict] = {}
    for sample, directory in sorted(specs.items()):
        manifest_path = directory / "manifest.json"
        database_path = directory / "decisions.sqlite"
        manifest = read_json(manifest_path)
        decision_base_id = manifest["decisionBaseID"]
        complete = (directory / ".complete").read_text(encoding="utf-8").strip()
        p4b_complete = (directory / ".p4b-complete").read_text(encoding="utf-8").strip()
        if complete != decision_base_id or p4b_complete != decision_base_id:
            raise ValueError(f"{sample} completion marker mismatch")
        if manifest.get("sampleID") != sample:
            raise ValueError(f"{sample} manifest sample mismatch")
        for key, expected in EXPECTED_COMMON.items():
            if manifest.get(key) != expected:
                raise ValueError(
                    f"{sample} manifest mismatch {key}: {manifest.get(key)!r}"
                )
        connection = connect_readonly(database_path)
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        window_count = connection.execute("SELECT COUNT(*) FROM windows").fetchone()[0]
        stock_count = connection.execute("SELECT COUNT(*) FROM stocks").fetchone()[0]
        connection.close()
        if integrity != "ok" or window_count != 3 or stock_count != 10:
            raise ValueError(
                f"{sample} DecisionBase integrity/coverage mismatch: "
                f"integrity={integrity}, windows={window_count}, stocks={stock_count}"
            )
        identities[sample] = {
            "decisionBaseID": decision_base_id,
            "database": str(database_path),
            "windows": window_count,
            "stocks": stock_count,
        }
    return identities


def enriched_summary(rows: list[dict], label: str) -> dict:
    result = horizon_summary(rows, label)
    result["samples"] = len({row["sample"] for row in rows})
    result["sampleIDs"] = sorted({row["sample"] for row in rows})
    return result


def flat_summary(item: dict, label_key: str = "blocker") -> dict:
    result = {
        label_key: item["label"],
        "samples": item["samples"],
        "sample_ids": "|".join(item["sampleIDs"]),
        "events": item["events"],
        "stocks": item["stocks"],
        "windows": item["windows"],
        "outcome_score_improved_rate": item["outcomeScoreImprovedRate"],
        "outcome_median_roi_delta": item["outcomeMedianROIDelta"],
        "outcome_median_score_delta": item["outcomeMedianScoreDelta"],
        "outcome_median_trading_days": item["outcomeMedianTradingDays"],
        "outcome_median_capital_trading_day_wan": item[
            "outcomeMedianCapitalTradingDayWan"
        ],
    }
    for horizon in HORIZONS:
        horizon_item = item[f"h{horizon}"]
        result.update(
            {
                f"h{horizon}_complete": horizon_item["complete"],
                f"h{horizon}_score_improved_rate": horizon_item[
                    "scoreImprovedRate"
                ],
                f"h{horizon}_median_roi_delta": horizon_item["medianROIDelta"],
                f"h{horizon}_median_score_delta": horizon_item[
                    "medianScoreDelta"
                ],
                f"h{horizon}_median_capital_trading_day_wan": horizon_item[
                    "medianCapitalTradingDayWan"
                ],
            }
        )
    return result


def sample_summary_rows(groups: dict[tuple[str, str], list[dict]]) -> list[dict]:
    output: list[dict] = []
    for (label, sample), rows in sorted(groups.items()):
        item = enriched_summary(rows, label)
        row = flat_summary(item)
        row["sample"] = sample
        output.append(row)
    return output


def consistently_worsens(item: dict) -> bool:
    return (
        item["events"] >= 1
        and item["h60"]["complete"] >= 1
        and item["h120"]["complete"] >= 1
        and (item["h60"]["medianScoreDelta"] or 0) < 0
        and (item["h120"]["medianScoreDelta"] or 0) < 0
        and (item["outcomeMedianScoreDelta"] or 0) < 0
    )


def candidate_signal(
    pooled: dict,
    per_sample: dict[str, dict],
) -> tuple[bool, list[str]]:
    worsening_samples = sorted(
        sample for sample, item in per_sample.items() if consistently_worsens(item)
    )
    pooled_worsens = (
        pooled["samples"] >= 2
        and pooled["stocks"] >= 2
        and pooled["windows"] >= 2
        and pooled["h60"]["complete"] >= 2
        and pooled["h120"]["complete"] >= 2
        and (pooled["h60"]["medianScoreDelta"] or 0) < 0
        and (pooled["h120"]["medianScoreDelta"] or 0) < 0
        and (pooled["outcomeMedianScoreDelta"] or 0) < 0
    )
    return pooled_worsens and len(worsening_samples) >= 2, worsening_samples


def main() -> None:
    args = arguments()
    specs = decision_base_specs(args.decision_base)
    identities = verify_identity(specs)

    events: list[dict] = []
    for sample, directory in sorted(specs.items()):
        for row in build_fixed(directory / "decisions.sqlite"):
            events.append({"sample": sample} | row)

    blocker_groups: dict[str, list[dict]] = defaultdict(list)
    blocker_sample_groups: dict[tuple[str, str], list[dict]] = defaultdict(list)
    combination_groups: dict[str, list[dict]] = defaultdict(list)
    sole_groups: dict[str, list[dict]] = defaultdict(list)
    sole_sample_groups: dict[tuple[str, str], list[dict]] = defaultdict(list)
    for row in events:
        sample = str(row["sample"])
        combination = str(row["blocker_combination"])
        combination_groups[combination].append(row)
        blockers = str(row["blockers"]).split("|")
        for blocker in blockers:
            blocker_groups[blocker].append(row)
            blocker_sample_groups[(blocker, sample)].append(row)
        if len(blockers) == 1:
            sole_groups[blockers[0]].append(row)
            sole_sample_groups[(blockers[0], sample)].append(row)

    by_blocker = [
        enriched_summary(rows, label) for label, rows in sorted(blocker_groups.items())
    ]
    by_combination = [
        enriched_summary(rows, label)
        for label, rows in sorted(combination_groups.items())
    ]
    sole = [enriched_summary(rows, label) for label, rows in sorted(sole_groups.items())]
    by_blocker_sample = {
        label: {
            sample: enriched_summary(rows, label)
            for (group_label, sample), rows in sorted(blocker_sample_groups.items())
            if group_label == label
        }
        for label in blocker_groups
    }
    sole_by_sample = {
        label: {
            sample: enriched_summary(rows, label)
            for (group_label, sample), rows in sorted(sole_sample_groups.items())
            if group_label == label
        }
        for label in sole_groups
    }

    signals: list[dict] = []
    for item in sole:
        qualifies, worsening_samples = candidate_signal(
            item, sole_by_sample[item["label"]]
        )
        if qualifies:
            signals.append(
                {"blocker": item["label"], "worseningSamples": worsening_samples}
            )

    overall = enriched_summary(events, "A-D fixed")
    summary = {
        "studyID": STUDY_ID,
        "identity": identities,
        "commonIdentity": EXPECTED_COMMON,
        "definition": (
            "first held sell decision after 120 days with negative current ROI "
            "in each holding cycle"
        ),
        "overall": overall,
        "byBlocker": by_blocker,
        "byBlockerSample": by_blocker_sample,
        "byCombination": by_combination,
        "soleBlockers": sole,
        "soleBlockersBySample": sole_by_sample,
        "candidateSignals": signals,
        "recommendedNext": None,
    }

    args.output.mkdir(parents=True, exist_ok=False)
    write_csv(args.output / "fixed-events.csv", events)
    write_csv(
        args.output / "blocker-summary.csv",
        [flat_summary(item) for item in by_blocker],
    )
    write_csv(
        args.output / "blocker-by-sample.csv",
        sample_summary_rows(blocker_sample_groups),
    )
    write_csv(
        args.output / "combination-summary.csv",
        [flat_summary(item, "combination") for item in by_combination],
    )
    write_csv(
        args.output / "sole-blocker-summary.csv",
        [flat_summary(item) for item in sole],
    )
    write_csv(
        args.output / "sole-blocker-by-sample.csv",
        sample_summary_rows(sole_sample_groups),
    )
    (args.output / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    lines = [
        "# E-CAP06-D0-ABCD Baseline v19 剩餘長期資金占用跨樣本診斷",
        "",
        "- 樣本：A／B／C／D，各 10 檔、3 個固定三年窗口。",
        f"- 資料／策略／截止日：`{EXPECTED_COMMON['dataRuleVersion']}`／"
        f"`{EXPECTED_COMMON['ruleVersion']}`／`{EXPECTED_COMMON['through']}`。",
        f"- 案例定義：每個持股輪第一次持股超過 120 日、當日 ROI 為負且正式路徑續抱；共 {len(events)} 件。",
        "",
        "## 各項 S-T02h 阻擋原因（可重疊）",
        "",
    ]
    for item in by_blocker:
        lines.append(
            f"- `{item['label']}`：{item['events']} 件、{item['samples']} 樣本、"
            f"{item['stocks']} 檔、{item['windows']} 窗口；20／60／120 日分數變化中位 "
            f"{fmt(item['h20']['medianScoreDelta'])}／"
            f"{fmt(item['h60']['medianScoreDelta'])}／"
            f"{fmt(item['h120']['medianScoreDelta'])}；"
            f"期末分數變化中位 {fmt(item['outcomeMedianScoreDelta'])}。"
        )
    lines.extend(["", "## 單一阻擋原因與逐樣本方向", ""])
    for item in sole:
        label = item["label"]
        sample_parts = []
        for sample, sample_item in sorted(sole_by_sample[label].items()):
            sample_parts.append(
                f"{sample} {sample_item['events']} 件／60d "
                f"{fmt(sample_item['h60']['medianScoreDelta'])}／120d "
                f"{fmt(sample_item['h120']['medianScoreDelta'])}／期末 "
                f"{fmt(sample_item['outcomeMedianScoreDelta'])}"
            )
        lines.append(
            f"- `{label}`：{item['events']} 件、{item['samples']} 樣本；"
            + "；".join(sample_parts)
            + "。"
        )
    lines.extend(
        [
            "",
            "## 候選訊號與停止條件",
            "",
            "- 單一阻擋群需同時跨至少 2 個樣本、2 檔股票與 2 個窗口，pooled 60／120 日及期末分數中位皆惡化，且至少 2 個樣本各自三段皆惡化，才列為候選訊號。",
            f"- 符合者：{', '.join(item['blocker'] for item in signals) or '無'}。",
            "- 本診斷只用來生成候選；任何新規則仍須獨立完整重播，不能把等待分數相加當成候選績效。",
        ]
    )
    (args.output / "report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
