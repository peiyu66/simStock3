#!/usr/bin/env python3
"""E-PROFIT01-D0-ABCDE: diagnose long positive holdings that remain unsold."""

from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path

from ecap03_long_negative_holding_study import (
    HORIZONS,
    connect_readonly,
    fixed_data,
    fmt,
    horizon_summary,
    horizon_values,
    read_json,
    split_cycles,
    write_csv,
)


STUDY_ID = "E-PROFIT01-D0-ABCDE"
EXPECTED_SAMPLES = {"A", "B", "C", "D", "E"}
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
        complete = (directory / ".complete").read_text(encoding="utf-8").strip()
        p4b_complete = (directory / ".p4b-complete").read_text(
            encoding="utf-8"
        ).strip()
        if complete != decision_base_id or p4b_complete != decision_base_id:
            raise ValueError(f"{sample} completion marker mismatch")
        if manifest.get("sampleID") != sample:
            raise ValueError(f"{sample} manifest sample mismatch")
        for key, expected in EXPECTED_COMMON.items():
            if manifest.get(key) != expected:
                raise ValueError(
                    f"{sample} manifest mismatch {key}: {manifest.get(key)!r}"
                )
        database_path = directory / "decisions.sqlite"
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


def grade_score_band(score: float) -> str:
    # Formal S31 Grade boundaries are retained, with the already discussed
    # 100/200 subdivisions added inside the unbounded wow range.
    if score < -23:
        return "score_lt_m23"
    if score < -5:
        return "score_m23_to_m5"
    if score < 0:
        return "score_m5_to_0"
    if score <= 23:
        return "score_0_to_23"
    if score <= 39:
        return "score_23_to_39"
    if score <= 46:
        return "score_39_to_46"
    if score <= 100:
        return "score_46_to_100"
    if score <= 200:
        return "score_100_to_200"
    return "score_gt_200"


def exact_sell_score_label(score: float) -> str:
    return f"sell_score_{score:g}".replace("-", "m").replace(".", "p")


def sell_context(row: dict) -> dict:
    roi = float(row["unit_roi_before"])
    sell_score = float(row["decision_score"])
    grade = int(row["grade"])
    grade_score = float(row["grade_efficiency_score"])

    st01e_roi_passed = roi > 0.45
    st01e_gap = 4.0 - sell_score
    if not st01e_roi_passed:
        sell_band = "roi_at_or_below_045"
    elif sell_score == 3:
        sell_band = "st01e_one_vote_short"
    elif sell_score <= 2:
        sell_band = "st01e_two_or_more_votes_short"
    else:
        # A held event with score >= 4 must have failed a different gate or
        # indicates an inconsistency that should remain visible in the output.
        sell_band = "st01e_score_gate_passed"

    # S-T01a uses a strict threshold: high/wow require >0, all other Grades >1.
    st01a_required_score = 1.0 if grade >= 2 else 2.0
    return {
        "sell_band": sell_band,
        "sell_score": sell_score,
        "exact_sell_score": exact_sell_score_label(sell_score),
        "st01e_roi_gate_passed": int(st01e_roi_passed),
        "st01e_required_score": 4.0,
        "st01e_score_gap": st01e_gap,
        "st01a_roi_gate_passed": int(roi > 22.5),
        "st01a_required_score": st01a_required_score,
        "st01a_score_gap": st01a_required_score - sell_score,
        "grade_efficiency_score": grade_score,
        "grade_score_band": grade_score_band(grade_score),
    }


def build_fixed(path: Path) -> list[dict]:
    rows, _, adds = fixed_data(path)
    records: list[dict] = []
    for path_key, cycle_number, cycle in split_cycles(rows, "inventory", "sold"):
        checkpoint_index = next(
            (
                index
                for index, row in enumerate(cycle)
                if float(row["holding_days_before"]) > 120
                and float(row["unit_roi_before"]) > 0
                and not row["sold"]
            ),
            None,
        )
        if checkpoint_index is None:
            continue
        row = cycle[checkpoint_index]
        for item in cycle:
            item["added"] = int(item["trade_date"]) in adds.get(path_key, [])
        context = sell_context(row)
        if context["sell_band"] == "st01e_score_gate_passed":
            raise ValueError(f"S-T01e-qualified event unexpectedly held: {row}")
        records.append(
            {
                "source": "fixed",
                "window_start": int(row["start_date"]),
                "window_end": int(row["end_date"]),
                "stock_id": row["stock_id"],
                "stock_name": row["stock_name"],
                "group": row["group_name"],
                "cycle_number": cycle_number,
                "trade_date": int(row["trade_date"]),
                "holding_days": float(row["holding_days_before"]),
                "market_roi": float(row["unit_roi_before"]),
                "decision_grade": row["grade_name"],
                "decision_grade_raw": int(row["grade"]),
                "passed_gates": "|".join(
                    sorted(
                        value
                        for value in str(row.get("passed_gates") or "").split(",")
                        if value
                    )
                ),
            }
            | context
            | horizon_values(cycle, checkpoint_index, "fixed")
        )
    return records


def enriched_summary(rows: list[dict], label: str) -> dict:
    result = horizon_summary(rows, label)
    result["samples"] = len({row["sample"] for row in rows})
    result["sampleIDs"] = sorted({row["sample"] for row in rows})
    return result


def flat_summary(item: dict, label_key: str) -> dict:
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
                f"h{horizon}_median_score_delta": horizon_item["medianScoreDelta"],
            }
        )
    return result


def summaries(groups: dict[str, list[dict]]) -> list[dict]:
    return [enriched_summary(rows, label) for label, rows in sorted(groups.items())]


def by_sample_summaries(groups: dict[tuple[str, str], list[dict]]) -> list[dict]:
    result: list[dict] = []
    for (label, sample), rows in sorted(groups.items()):
        item = enriched_summary(rows, label)
        flat = flat_summary(item, "label")
        flat["sample"] = sample
        result.append(flat)
    return result


def consistently_worsens(item: dict) -> bool:
    return (
        item["events"] >= 1
        and all(
            item[f"h{horizon}"]["complete"] >= 1
            and (item[f"h{horizon}"]["medianScoreDelta"] or 0) < 0
            for horizon in HORIZONS
        )
        and (item["outcomeMedianScoreDelta"] or 0) < 0
    )


def candidate_signal(
    pooled: dict, per_sample: dict[str, dict]
) -> tuple[bool, list[str]]:
    worsening_samples = sorted(
        sample for sample, item in per_sample.items() if consistently_worsens(item)
    )
    pooled_worsens = (
        pooled["samples"] >= 2
        and pooled["stocks"] >= 2
        and pooled["windows"] >= 2
        and all(
            pooled[f"h{horizon}"]["complete"] >= 2
            and (pooled[f"h{horizon}"]["medianScoreDelta"] or 0) < 0
            for horizon in HORIZONS
        )
        and (pooled["outcomeMedianScoreDelta"] or 0) < 0
    )
    return pooled_worsens and len(worsening_samples) >= 2, worsening_samples


def main() -> None:
    args = arguments()
    specs = decision_base_specs(args.decision_base)
    identities = verify_identity(specs)

    events: list[dict] = []
    for sample, directory in sorted(specs.items()):
        events.extend(
            {"sample": sample} | row
            for row in build_fixed(directory / "decisions.sqlite")
        )

    sell_groups: dict[str, list[dict]] = defaultdict(list)
    sell_sample_groups: dict[tuple[str, str], list[dict]] = defaultdict(list)
    exact_sell_groups: dict[str, list[dict]] = defaultdict(list)
    exact_sell_sample_groups: dict[tuple[str, str], list[dict]] = defaultdict(list)
    monotonic_sell_groups: dict[str, list[dict]] = defaultdict(list)
    monotonic_sell_sample_groups: dict[tuple[str, str], list[dict]] = defaultdict(list)
    grade_groups: dict[str, list[dict]] = defaultdict(list)
    grade_sample_groups: dict[tuple[str, str], list[dict]] = defaultdict(list)
    grade_score_groups: dict[str, list[dict]] = defaultdict(list)
    grade_score_sample_groups: dict[tuple[str, str], list[dict]] = defaultdict(list)
    score_one_grade_groups: dict[str, list[dict]] = defaultdict(list)
    score_one_grade_sample_groups: dict[tuple[str, str], list[dict]] = defaultdict(
        list
    )
    for row in events:
        sample = str(row["sample"])
        sell_label = str(row["sell_band"])
        exact_sell_label = str(row["exact_sell_score"])
        grade_label = str(row["decision_grade"])
        grade_score_label = str(row["grade_score_band"])
        sell_groups[sell_label].append(row)
        sell_sample_groups[(sell_label, sample)].append(row)
        exact_sell_groups[exact_sell_label].append(row)
        exact_sell_sample_groups[(exact_sell_label, sample)].append(row)
        if float(row["market_roi"]) > 0.45:
            for threshold in (1, 2, 3):
                if float(row["sell_score"]) <= threshold:
                    label = f"sell_score_le_{threshold}"
                    monotonic_sell_groups[label].append(row)
                    monotonic_sell_sample_groups[(label, sample)].append(row)
        grade_groups[grade_label].append(row)
        grade_sample_groups[(grade_label, sample)].append(row)
        grade_score_groups[grade_score_label].append(row)
        grade_score_sample_groups[(grade_score_label, sample)].append(row)
        if exact_sell_label == "sell_score_1":
            label = f"sell_score_1__{grade_score_label}"
            score_one_grade_groups[label].append(row)
            score_one_grade_sample_groups[(label, sample)].append(row)

    overall = enriched_summary(events, "A-E fixed")
    by_sell = summaries(sell_groups)
    by_exact_sell = summaries(exact_sell_groups)
    by_monotonic_sell = summaries(monotonic_sell_groups)
    by_grade = summaries(grade_groups)
    by_grade_score = summaries(grade_score_groups)
    by_score_one_grade = summaries(score_one_grade_groups)
    sell_by_sample = {
        label: {
            sample: enriched_summary(rows, label)
            for (group_label, sample), rows in sorted(sell_sample_groups.items())
            if group_label == label
        }
        for label in sell_groups
    }
    exact_sell_by_sample = {
        label: {
            sample: enriched_summary(rows, label)
            for (group_label, sample), rows in sorted(
                exact_sell_sample_groups.items()
            )
            if group_label == label
        }
        for label in exact_sell_groups
    }
    monotonic_sell_by_sample = {
        label: {
            sample: enriched_summary(rows, label)
            for (group_label, sample), rows in sorted(
                monotonic_sell_sample_groups.items()
            )
            if group_label == label
        }
        for label in monotonic_sell_groups
    }
    grade_score_by_sample = {
        label: {
            sample: enriched_summary(rows, label)
            for (group_label, sample), rows in sorted(
                grade_score_sample_groups.items()
            )
            if group_label == label
        }
        for label in grade_score_groups
    }
    score_one_grade_by_sample = {
        label: {
            sample: enriched_summary(rows, label)
            for (group_label, sample), rows in sorted(
                score_one_grade_sample_groups.items()
            )
            if group_label == label
        }
        for label in score_one_grade_groups
    }

    candidate_signals: list[dict] = []
    for kind, pooled_items, sample_items in (
        ("sell_band", by_sell, sell_by_sample),
        ("monotonic_sell_score", by_monotonic_sell, monotonic_sell_by_sample),
        ("grade_score_band", by_grade_score, grade_score_by_sample),
        (
            "sell_score_1_grade_score_band",
            by_score_one_grade,
            score_one_grade_by_sample,
        ),
    ):
        for item in pooled_items:
            qualifies, worsening_samples = candidate_signal(
                item, sample_items[item["label"]]
            )
            if qualifies:
                candidate_signals.append(
                    {
                        "kind": kind,
                        "condition": item["label"],
                        "worseningSamples": worsening_samples,
                    }
                )
    screening_signals: list[dict] = []
    for item in by_exact_sell:
        qualifies, worsening_samples = candidate_signal(
            item, exact_sell_by_sample[item["label"]]
        )
        if qualifies:
            screening_signals.append(
                {
                    "kind": "exact_sell_score",
                    "condition": item["label"],
                    "worseningSamples": worsening_samples,
                    "candidateRejectedReason": (
                        "an exact-score hole is non-monotonic; the encompassing "
                        "sell-score thresholds and Grade-score subdivisions do not "
                        "consistently worsen"
                    ),
                }
            )

    summary = {
        "studyID": STUDY_ID,
        "identity": identities,
        "commonIdentity": EXPECTED_COMMON,
        "definition": (
            "first held sell decision after 120 days with positive current ROI "
            "in each holding cycle"
        ),
        "overall": overall,
        "bySellBand": by_sell,
        "bySellBandSample": sell_by_sample,
        "byExactSellScore": by_exact_sell,
        "byExactSellScoreSample": exact_sell_by_sample,
        "byMonotonicSellScore": by_monotonic_sell,
        "byMonotonicSellScoreSample": monotonic_sell_by_sample,
        "byGrade": by_grade,
        "byGradeScoreBand": by_grade_score,
        "byGradeScoreBandSample": grade_score_by_sample,
        "bySellScoreOneGradeScoreBand": by_score_one_grade,
        "bySellScoreOneGradeScoreBandSample": score_one_grade_by_sample,
        "screeningSignals": screening_signals,
        "candidateSignals": candidate_signals,
        "recommendedNext": None,
    }

    args.output.mkdir(parents=True, exist_ok=False)
    write_csv(args.output / "fixed-events.csv", events)
    write_csv(
        args.output / "sell-band-summary.csv",
        [flat_summary(item, "sell_band") for item in by_sell],
    )
    write_csv(
        args.output / "sell-band-by-sample.csv",
        by_sample_summaries(sell_sample_groups),
    )
    write_csv(
        args.output / "exact-sell-score-summary.csv",
        [flat_summary(item, "exact_sell_score") for item in by_exact_sell],
    )
    write_csv(
        args.output / "exact-sell-score-by-sample.csv",
        by_sample_summaries(exact_sell_sample_groups),
    )
    write_csv(
        args.output / "monotonic-sell-score-summary.csv",
        [flat_summary(item, "sell_score_threshold") for item in by_monotonic_sell],
    )
    write_csv(
        args.output / "monotonic-sell-score-by-sample.csv",
        by_sample_summaries(monotonic_sell_sample_groups),
    )
    write_csv(
        args.output / "grade-summary.csv",
        [flat_summary(item, "grade") for item in by_grade],
    )
    write_csv(
        args.output / "grade-by-sample.csv",
        by_sample_summaries(grade_sample_groups),
    )
    write_csv(
        args.output / "grade-score-band-summary.csv",
        [flat_summary(item, "grade_score_band") for item in by_grade_score],
    )
    write_csv(
        args.output / "grade-score-band-by-sample.csv",
        by_sample_summaries(grade_score_sample_groups),
    )
    write_csv(
        args.output / "sell-score-1-grade-score-band-summary.csv",
        [
            flat_summary(item, "sell_score_1_grade_score_band")
            for item in by_score_one_grade
        ],
    )
    write_csv(
        args.output / "sell-score-1-grade-score-band-by-sample.csv",
        by_sample_summaries(score_one_grade_sample_groups),
    )
    (args.output / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    lines = [
        "# E-PROFIT01-D0-ABCDE Baseline v19 長期正 ROI 續抱診斷",
        "",
        "- 樣本：A／B／C／D／E，各 10 檔、3 個固定三年窗口。",
        f"- 資料／策略／截止日：`{EXPECTED_COMMON['dataRuleVersion']}`／"
        f"`{EXPECTED_COMMON['ruleVersion']}`／`{EXPECTED_COMMON['through']}`。",
        "- 案例定義：每個持股輪第一次持股超過 120 日、當日 ROI 為正且正式路徑續抱；"
        f"共 {len(events)} 件。",
        "- 分數變化均以當日假設賣出為基準；正值表示續抱較好，負值表示當日賣出較好。",
        "",
        "## 整體",
        "",
        f"- 20／60／120 日分數變化中位：{fmt(overall['h20']['medianScoreDelta'])}／"
        f"{fmt(overall['h60']['medianScoreDelta'])}／{fmt(overall['h120']['medianScoreDelta'])}；"
        f"實際結案或期末 {fmt(overall['outcomeMedianScoreDelta'])}。",
        "",
        "## 正式賣出門檻距離",
        "",
    ]
    for item in by_sell:
        lines.append(
            f"- `{item['label']}`：{item['events']} 件、{item['samples']} 樣本、"
            f"{item['stocks']} 檔、{item['windows']} 窗口；20／60／120 日分數變化中位 "
            f"{fmt(item['h20']['medianScoreDelta'])}／"
            f"{fmt(item['h60']['medianScoreDelta'])}／"
            f"{fmt(item['h120']['medianScoreDelta'])}；期末 "
            f"{fmt(item['outcomeMedianScoreDelta'])}。"
        )
    lines.extend(["", "## 確切賣出分數", ""])
    for item in by_exact_sell:
        lines.append(
            f"- `{item['label']}`：{item['events']} 件、{item['samples']} 樣本、"
            f"{item['stocks']} 檔、{item['windows']} 窗口；20／60／120 日分數變化中位 "
            f"{fmt(item['h20']['medianScoreDelta'])}／"
            f"{fmt(item['h60']['medianScoreDelta'])}／"
            f"{fmt(item['h120']['medianScoreDelta'])}；期末 "
            f"{fmt(item['outcomeMedianScoreDelta'])}。"
        )
    lines.extend(["", "## 單調賣出分數界線", ""])
    for item in by_monotonic_sell:
        lines.append(
            f"- `{item['label']}`：{item['events']} 件、{item['samples']} 樣本、"
            f"{item['stocks']} 檔、{item['windows']} 窗口；20／60／120 日分數變化中位 "
            f"{fmt(item['h20']['medianScoreDelta'])}／"
            f"{fmt(item['h60']['medianScoreDelta'])}／"
            f"{fmt(item['h120']['medianScoreDelta'])}；期末 "
            f"{fmt(item['outcomeMedianScoreDelta'])}。"
        )
    lines.extend(["", "## Grade 連續分數區間", ""])
    for item in by_grade_score:
        lines.append(
            f"- `{item['label']}`：{item['events']} 件、{item['samples']} 樣本、"
            f"{item['stocks']} 檔、{item['windows']} 窗口；20／60／120 日分數變化中位 "
            f"{fmt(item['h20']['medianScoreDelta'])}／"
            f"{fmt(item['h60']['medianScoreDelta'])}／"
            f"{fmt(item['h120']['medianScoreDelta'])}；期末 "
            f"{fmt(item['outcomeMedianScoreDelta'])}。"
        )
    lines.extend(["", "## `sell score = 1` 的 Grade 連續分數拆解", ""])
    for item in by_score_one_grade:
        lines.append(
            f"- `{item['label']}`：{item['events']} 件、{item['samples']} 樣本、"
            f"{item['stocks']} 檔、{item['windows']} 窗口；20／60／120 日分數變化中位 "
            f"{fmt(item['h20']['medianScoreDelta'])}／"
            f"{fmt(item['h60']['medianScoreDelta'])}／"
            f"{fmt(item['h120']['medianScoreDelta'])}；期末 "
            f"{fmt(item['outcomeMedianScoreDelta'])}。"
        )
    lines.extend(
        [
            "",
            "## 候選訊號與停止條件",
            "",
            "- 同一賣出距離或連續 Grade 分數區間，需 pooled 與至少 2 個樣本的 20／60／120 日及期末分數中位全部惡化，且合計跨至少 2 檔、2 窗口，才列為候選訊號。",
            "- `.none` 可列入診斷，但不得作正式候選條件。",
            f"- 初篩異常：{', '.join(item['condition'] for item in screening_signals) or '無'}。確切分數的孤立凹洞不具單調解釋，須再通過相鄰累積界線及 Grade 連續分數拆解。",
            f"- 可形成候選者：{', '.join(item['condition'] for item in candidate_signals) or '無'}。",
            "- 本診斷只生成候選；未經完整反事實重播，不等同候選績效。",
        ]
    )
    (args.output / "report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
